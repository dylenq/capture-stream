import AppKit
import AVFoundation
import CoreMedia
import ImageIO
import VideoToolbox
import os

/// Reassembles JPEG frames from UDP packets, decodes them in hardware and shows each one
/// the moment it's ready. There's no playback clock and no queue: a frame that arrives
/// incomplete or after a newer one is simply dropped, so delay can't build up.
final class VideoPipeline {
    let displayLayer = AVSampleBufferDisplayLayer()
    private let stats: StreamStats

    private struct Partial {
        var slices: [Data?]
        var received = 0
        let captureMicros: UInt64
    }
    private var partials: [UInt32: Partial] = [:]
    private var lastShown: UInt32 = 0

    private var session: VTDecompressionSession?
    private var jpegFormat: CMVideoFormatDescription?
    private var size = (width: 0, height: 0)
    private var hardwareFailures = 0
    private var useSoftwareDecoder = false

    /// Picture settings and the view size come from the main thread, frames from the decoder's
    /// thread, so they're shared under a lock.
    private struct PictureState {
        var settings = VideoSettings()
        var viewPixels = (width: 0, height: 0)
        var status: String?
        var nextDue = 0.0
    }
    private let state = OSAllocatedUnfairLock(initialState: PictureState())
    private let upscaler = Upscaler()
    private var defaultsObserver: NSObjectProtocol?

    /// "1280×720 → 2560×1440" while upscaling, a reason when it's on but not upscaling, nil when off.
    var upscaleStatus: String? { state.withLock { $0.status } }

    /// The video view's size in device pixels; the "Window size" upscale target fits the frame in it.
    func setViewPixelSize(width: Int, height: Int) {
        state.withLock { $0.viewPixels = (width, height) }
    }

    init(stats: StreamStats) {
        self.stats = stats
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        loadSettings()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.loadSettings()
            }
    }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    private func loadSettings() {
        let settings = VideoSettings.load()
        state.withLock { s in
            guard s.settings != settings else { return }
            if settings.upscale != s.settings.upscale {
                s.status = settings.upscale ? (upscaler == nil ? "not supported on this Mac" : "waiting for a frame") : nil
            }
            s.settings = settings
        }
    }

    func reset(width: Int, height: Int) {
        partials.removeAll()
        lastShown = 0
        hardwareFailures = 0
        useSoftwareDecoder = false
        if (width, height) != size {
            if let session { VTDecompressionSessionInvalidate(session) }
            session = nil
            size = (width, height)
        }
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    /// Called on the video receive queue for every packet.
    func handle(_ packet: Wire.VideoPacket) {
        stats.addVideoBytes(packet.payload.count + Wire.videoHeaderSize)
        guard packet.frameID > lastShown, packet.index < packet.count else { return }
        var frame = partials[packet.frameID]
            ?? Partial(slices: Array(repeating: nil, count: packet.count), captureMicros: packet.captureMicros)
        guard frame.slices[packet.index] == nil else { return }
        frame.slices[packet.index] = Data(packet.payload)
        frame.received += 1
        guard frame.received == frame.slices.count else {
            partials[packet.frameID] = frame
            return
        }

        // Complete. Every frame between the last one shown and this one is lost, including
        // any still partial, which will never be shown now.
        partials.removeValue(forKey: packet.frameID)
        stats.addDroppedFrames(Int(packet.frameID &- lastShown &- 1))
        partials.keys.filter { $0 < packet.frameID }.forEach { partials.removeValue(forKey: $0) }
        lastShown = packet.frameID

        var jpeg = Data(capacity: frame.slices.reduce(0) { $0 + ($1?.count ?? 0) })
        frame.slices.forEach { jpeg.append($0!) }
        decodeAndShow(jpeg, captureMicros: frame.captureMicros)
    }

    private func makeSession() -> Bool {
        guard size.width > 0 else { return false }
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_JPEG,
                                       width: Int32(size.width), height: Int32(size.height),
                                       extensions: nil, formatDescriptionOut: &format)
        guard let format else { return false }
        let output: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
                                                  decoderSpecification: nil,
                                                  imageBufferAttributes: output as CFDictionary,
                                                  outputCallback: nil, decompressionSessionOut: &newSession)
        guard status == noErr, let newSession else { return false }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        jpegFormat = format
        session = newSession
        return true
    }

    /// Whether the fps cap lets this frame through. Frames over the cap are skipped before
    /// decoding; a small allowance for arrival jitter keeps e.g. a 50 cap at 50 on a 60 fps stream.
    private func passesFpsCap() -> Bool {
        state.withLock { s in
            guard s.settings.fpsCap > 0 else { return true }
            let now = CACurrentMediaTime(), interval = 1 / Double(s.settings.fpsCap)
            if now + 0.004 < s.nextDue { return false }
            s.nextDue = max(s.nextDue + interval, now - interval)
            return true
        }
    }

    private func decodeAndShow(_ jpeg: Data, captureMicros: UInt64) {
        guard passesFpsCap() else { return }
        if useSoftwareDecoder {
            decodeInSoftware(jpeg, captureMicros: captureMicros)
            return
        }
        if session == nil, !makeSession() { return }
        guard let session, let jpegFormat, let sample = Self.sampleBuffer(jpeg, format: jpegFormat) else { return }
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [],
                                          infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            guard let self else { return }
            guard status == noErr, let image else {
                // The hardware decoder rejects some cards' JPEGs (e.g. some 4:2:2 encoders).
                // After a few failures in a row, switch to ImageIO for the rest of the session.
                hardwareFailures += 1
                if hardwareFailures >= 3 { useSoftwareDecoder = true }
                decodeInSoftware(jpeg, captureMicros: captureMicros)
                return
            }
            hardwareFailures = 0
            self.present(image, captureMicros: captureMicros)
        }
    }

    private func decodeInSoftware(_ jpeg: Data, captureMicros: UInt64) {
        guard let image = Self.softwareDecode(jpeg) else {
            stats.addDroppedFrames(1)
            return
        }
        present(image, captureMicros: captureMicros)
    }

    /// Shows the frame, through the MetalFX upscaler when it's on and the view is bigger than the frame.
    private func present(_ image: CVPixelBuffer, captureMicros: UInt64) {
        let current = state.withLock { $0 }
        let settings = current.settings
        if settings.upscale, let upscaler {
            let inW = CVPixelBufferGetWidth(image), inH = CVPixelBufferGetHeight(image)
            let (outW, outH) = Self.upscaleSize(settings.target, width: inW, height: inH, view: current.viewPixels)
            var status = "\(settings.target == .window ? "window" : settings.target.label) not larger than \(inW)×\(inH)"
            if outW > inW, outH > inH {
                let started = upscaler.upscale(image, width: outW, height: outH,
                                               method: .metalFX(sharpness: Float(settings.sharpness))) { [weak self] output in
                    self?.show(output)
                    self?.stats.frameShown(captureMicros: captureMicros)
                }
                if started {
                    let sharpen = settings.sharpness > 0 ? String(format: ", sharpen %.0f%%", settings.sharpness * 100) : ""
                    state.withLock { $0.status = "\(inW)×\(inH) → \(outW)×\(outH)\(sharpen)" }
                    return
                }
                status = "can't upscale \(inW)×\(inH) to \(outW)×\(outH)"
            }
            state.withLock { [status] in $0.status = status }
        } else if settings.filter == .sharp, let upscaler {
            // Sharp pixels: scale to the window with nearest-neighbour so the display layer shows it 1:1.
            let inW = CVPixelBufferGetWidth(image), inH = CVPixelBufferGetHeight(image)
            let (outW, outH) = Self.upscaleSize(.window, width: inW, height: inH, view: current.viewPixels)
            if outW > inW, outH > inH,
               upscaler.upscale(image, width: outW, height: outH, method: .nearest, completion: { [weak self] output in
                   self?.show(output)
                   self?.stats.frameShown(captureMicros: captureMicros)
               }) {
                return
            }
        }
        show(image)
        stats.frameShown(captureMicros: captureMicros)
    }

    /// The upscale output size for a target, keeping the frame's aspect ratio, in whole even
    /// pixels and at most 8192 on a side. "Window size" is the largest size that fits the view.
    private static func upscaleSize(_ target: VideoSettings.UpscaleTarget, width: Int, height: Int,
                                    view: (width: Int, height: Int)) -> (Int, Int) {
        guard width > 0, height > 0 else { return (0, 0) }
        let w = Double(width), h = Double(height)
        var scale: Double
        switch target {
        case .window:
            guard view.width > 0, view.height > 0 else { return (0, 0) }
            scale = min(Double(view.width) / w, Double(view.height) / h)
        case .x1_5: scale = 1.5
        case .x2: scale = 2
        case .p1440: scale = 1440 / h
        case .p2160: scale = 2160 / h
        }
        scale = min(scale, 8192 / max(w, h))
        return (Int((w * scale).rounded()) & ~1, Int((h * scale).rounded()) & ~1)
    }

    private static func softwareDecode(_ jpeg: Data) -> CVPixelBuffer? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                      kCVPixelBufferCGImageCompatibilityKey: true,
                                      kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width,
                                      height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    private func show(_ image: CVImageBuffer) {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        Self.markDisplayImmediately(sample)
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush(removingDisplayedImage: false, completionHandler: nil)
        }
        renderer.enqueue(sample)
    }

    private static func sampleBuffer(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        data.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                 offsetIntoDestination: 0, dataLength: data.count) }
        var sample: CMSampleBuffer?
        var size = data.count
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                  sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                  sampleSizeArray: &size, sampleBufferOut: &sample)
        return sample
    }

    private static func markDisplayImmediately(_ sample: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
}
