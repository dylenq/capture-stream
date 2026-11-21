import CoreVideo
import Metal
import MetalFX
import VideoToolbox

/// Upscales decoded frames to the window's pixel size with the MetalFX spatial scaler.
/// Decoded frames (usually YCbCr) are converted to BGRA, run through the scaler into a private
/// texture, then blitted into an IOSurface-backed pixel buffer the display layer can show.
/// Safe to call from any thread; work is serialised internally and runs in GPU queue order,
/// so frames come out in the order they went in.
final class Upscaler {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let lock = NSLock()

    private struct Config: Equatable { var inW, inH, outW, outH: Int }
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
    }

    /// Encodes the upscale and returns true; `completion` gets the upscaled frame once the GPU
    /// finishes. Returns false (and never calls `completion`) if this size can't be upscaled.
    func upscale(_ image: CVPixelBuffer, width outW: Int, height outH: Int,
                 completion: @escaping (CVPixelBuffer) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wanted = Config(inW: CVPixelBufferGetWidth(image), inH: CVPixelBufferGetHeight(image),
                            outW: outW, outH: outH)
        if wanted != config {
            guard wanted != failedConfig, configure(wanted) else {
                failedConfig = wanted
                return false
            }
        }
        guard let scaler, let scratch, let inputPool, let outputPool,
              let input = bgraInput(image, pool: inputPool),
              let output = Self.buffer(from: outputPool),
              let inTex = texture(input), let outTex = texture(output),
              let inMTL = CVMetalTextureGetTexture(inTex), let outMTL = CVMetalTextureGetTexture(outTex),
              let commands = queue.makeCommandBuffer() else { return false }

        scaler.colorTexture = inMTL
        scaler.inputContentWidth = wanted.inW
        scaler.inputContentHeight = wanted.inH
        scaler.outputTexture = scratch
        scaler.encode(commandBuffer: commands)
        guard let blit = commands.makeBlitCommandEncoder() else { return false }
        blit.copy(from: scratch, to: outMTL)
        blit.endEncoding()

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
        texDesc.usage = newScaler.outputTextureUsage
        guard let newScratch = device.makeTexture(descriptor: texDesc),
              let inPool = Self.pool(width: c.inW, height: c.inH),
              let outPool = Self.pool(width: c.outW, height: c.outH) else { return false }

        scaler = newScaler
        scratch = newScratch
        inputPool = inPool
        outputPool = outPool
        config = c
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

    private func texture(_ buffer: CVPixelBuffer) -> CVMetalTexture? {
        var tex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, .bgra8Unorm,
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
}
