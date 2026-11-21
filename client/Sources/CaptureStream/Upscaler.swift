import CoreVideo
import Metal
import MetalFX
import VideoToolbox

/// Upscales decoded frames on the GPU, with the MetalFX spatial scaler or with plain
/// nearest-neighbour sampling ("sharp pixels"; AVSampleBufferDisplayLayer ignores the layer's
/// scaling filter, so it has to happen here). Decoded frames (usually YCbCr) are converted to
/// BGRA; MetalFX output goes to a private texture, then is sharpened (or just copied) into an
/// IOSurface-backed pixel buffer the display layer can show.
/// Safe to call from any thread; work is serialised internally and runs in GPU queue order,
/// so frames come out in the order they went in.
final class Upscaler {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    /// Contrast-adaptive sharpening after MetalFX, which has no sharpness setting of its own.
    /// nil if the shader didn't compile; frames are then copied unsharpened.
    private let sharpen: MTLComputePipelineState?
    private let nearest: MTLComputePipelineState?
    private let lock = NSLock()

    enum Method: Equatable {
        case metalFX(sharpness: Float)
        case nearest
    }

    private struct Config: Equatable { var inW, inH, outW, outH: Int; var metalFX: Bool }
    private var config: Config?
    private var failedConfig: Config?
    private var scaler: MTLFXSpatialScaler?
    private var scratch: MTLTexture?
    private var inputPool: CVPixelBufferPool?
    private var outputPool: CVPixelBufferPool?
    private var transfer: VTPixelTransferSession?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              MTLFXSpatialScalerDescriptor.supportsDevice(device),
              let queue = device.makeCommandQueue() else { return nil }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let cache else { return nil }
        self.device = device
        self.queue = queue
        self.textureCache = cache
        queue.label = "MetalFX upscale"
        let library = try? device.makeLibrary(source: Self.shaderSource, options: nil)
        func pipeline(_ name: String) -> MTLComputePipelineState? {
            library?.makeFunction(name: name).flatMap { try? device.makeComputePipelineState(function: $0) }
        }
        sharpen = pipeline("sharpen")
        nearest = pipeline("nearest")
    }

    /// Encodes the upscale and returns true; `completion` gets the upscaled frame once the GPU
    /// finishes. Returns false (and never calls `completion`) if this size can't be upscaled.
    func upscale(_ image: CVPixelBuffer, width outW: Int, height outH: Int, method: Method,
                 completion: @escaping (CVPixelBuffer) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if method == .nearest, nearest == nil { return false }
        let wanted = Config(inW: CVPixelBufferGetWidth(image), inH: CVPixelBufferGetHeight(image),
                            outW: outW, outH: outH, metalFX: method != .nearest)
        if wanted != config {
            guard wanted != failedConfig, configure(wanted) else {
                failedConfig = wanted
                return false
            }
        }
        guard let inputPool, let outputPool,
              let input = bgraInput(image, pool: inputPool),
              let output = Self.buffer(from: outputPool),
              let inTex = texture(input, usage: .shaderRead),
              let outTex = texture(output, usage: [.shaderRead, .shaderWrite]),
              let inMTL = CVMetalTextureGetTexture(inTex), let outMTL = CVMetalTextureGetTexture(outTex),
              let commands = queue.makeCommandBuffer() else { return false }

        let grid = MTLSize(width: wanted.outW, height: wanted.outH, depth: 1)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        switch method {
        case .nearest:
            guard let nearest, let compute = commands.makeComputeCommandEncoder() else { return false }
            compute.setComputePipelineState(nearest)
            compute.setTexture(inMTL, index: 0)
            compute.setTexture(outMTL, index: 1)
            compute.dispatchThreads(grid, threadsPerThreadgroup: group)
            compute.endEncoding()
        case .metalFX(let sharpness):
            guard let scaler, let scratch else { return false }
            scaler.colorTexture = inMTL
            scaler.inputContentWidth = wanted.inW
            scaler.inputContentHeight = wanted.inH
            scaler.outputTexture = scratch
            scaler.encode(commandBuffer: commands)
            if sharpness > 0, let sharpen, let compute = commands.makeComputeCommandEncoder() {
                var amount = min(sharpness, 1)
                compute.setComputePipelineState(sharpen)
                compute.setTexture(scratch, index: 0)
                compute.setTexture(outMTL, index: 1)
                compute.setBytes(&amount, length: MemoryLayout<Float>.size, index: 0)
                compute.dispatchThreads(grid, threadsPerThreadgroup: group)
                compute.endEncoding()
            } else {
                guard let blit = commands.makeBlitCommandEncoder() else { return false }
                blit.copy(from: scratch, to: outMTL)
                blit.endEncoding()
            }
        }

        CVBufferPropagateAttachments(input, output)
        commands.addCompletedHandler { buffer in
            // Holding the CVMetalTextures until here keeps their IOSurfaces alive for the GPU.
            withExtendedLifetime((inTex, outTex)) {
                if buffer.status == .completed { completion(output) }
            }
        }
        commands.commit()
        return true
    }

    private func configure(_ c: Config) -> Bool {
        config = nil
        guard let inPool = Self.pool(width: c.inW, height: c.inH),
              let outPool = Self.pool(width: c.outW, height: c.outH) else { return false }
        if c.metalFX {
            guard configureMetalFX(c) else { return false }
        } else {
            scaler = nil
            scratch = nil
        }
        inputPool = inPool
        outputPool = outPool
        config = c
        return true
    }

    private func configureMetalFX(_ c: Config) -> Bool {
        let desc = MTLFXSpatialScalerDescriptor()
        desc.colorTextureFormat = .bgra8Unorm
        desc.outputTextureFormat = .bgra8Unorm
        desc.inputWidth = c.inW
        desc.inputHeight = c.inH
        desc.outputWidth = c.outW
        desc.outputHeight = c.outH
        desc.colorProcessingMode = .perceptual
        guard let newScaler = desc.makeSpatialScaler(device: device) else { return false }

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: c.outW,
                                                               height: c.outH, mipmapped: false)
        texDesc.storageMode = .private
        texDesc.usage = newScaler.outputTextureUsage.union(.shaderRead)
        guard let newScratch = device.makeTexture(descriptor: texDesc) else { return false }
        scaler = newScaler
        scratch = newScratch
        return true
    }

    /// The frame as BGRA: as is if it already is, otherwise converted in hardware.
    private func bgraInput(_ image: CVPixelBuffer, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        if CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA,
           CVPixelBufferGetIOSurface(image) != nil { return image }
        if transfer == nil {
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
            if let transfer {
                VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue)
            }
        }
        guard let transfer, let dest = Self.buffer(from: pool),
              VTPixelTransferSessionTransferImage(transfer, from: image, to: dest) == noErr else { return nil }
        return dest
    }

    private func texture(_ buffer: CVPixelBuffer, usage: MTLTextureUsage) -> CVMetalTexture? {
        var tex: CVMetalTexture?
        let attrs = [kCVMetalTextureUsage: usage.rawValue] as CFDictionary
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, attrs, .bgra8Unorm,
                                                  CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer),
                                                  0, &tex)
        return tex
    }

    private static func pool(width: Int, height: Int) -> CVPixelBufferPool? {
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                      kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                      kCVPixelBufferMetalCompatibilityKey: true]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        return pool
    }

    private static func buffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    /// `sharpen`: contrast-adaptive sharpening (the CAS approach), a 5-tap cross filter whose
    /// negative lobe shrinks where local contrast is already high, so edges sharpen without
    /// ringing or clipping. `nearest`: nearest-neighbour scaling.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void nearest(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        uint2 p [[thread_position_in_grid]]) {
        uint w = dst.get_width(), h = dst.get_height();
        if (p.x >= w || p.y >= h) return;
        uint2 size = uint2(src.get_width(), src.get_height());
        uint2 s = uint2((float2(p) + 0.5) * float2(size) / float2(w, h));
        dst.write(src.read(min(s, size - 1)), p);
    }

    kernel void sharpen(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant float &amount [[buffer(0)]],
                        uint2 p [[thread_position_in_grid]]) {
        uint w = dst.get_width(), h = dst.get_height();
        if (p.x >= w || p.y >= h) return;
        float4 centre = src.read(p);
        float3 e = centre.rgb;
        float3 b = src.read(uint2(p.x, p.y > 0 ? p.y - 1 : 0)).rgb;
        float3 d = src.read(uint2(p.x > 0 ? p.x - 1 : 0, p.y)).rgb;
        float3 f = src.read(uint2(min(p.x + 1, w - 1), p.y)).rgb;
        float3 g = src.read(uint2(p.x, min(p.y + 1, h - 1))).rgb;
        float3 mn = min(min(min(b, d), min(f, g)), e);
        float3 mx = max(max(max(b, d), max(f, g)), e);
        // Headroom before clipping, relative to the local peak: low contrast sharpens more.
        float3 amp = sqrt(saturate(min(mn, 1.0 - mx) / max(mx, float3(1e-4))));
        float3 weight = amp * (-1.0 / mix(8.0, 5.0, amount));
        float3 result = ((b + d + f + g) * weight + e) / (1.0 + 4.0 * weight);
        dst.write(float4(saturate(result), centre.a), p);
    }
    """
}
