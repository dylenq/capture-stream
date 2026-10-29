import AppKit
import AVFoundation
import CoreMedia
import ImageIO
import VideoToolbox

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

    init(stats: StreamStats) {
        self.stats = stats
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
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

    private func decodeAndShow(_ jpeg: Data, captureMicros: UInt64) {
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
            self.show(image)
            self.stats.frameShown(captureMicros: captureMicros)
        }
    }

    private func decodeInSoftware(_ jpeg: Data, captureMicros: UInt64) {
        guard let image = Self.softwareDecode(jpeg) else {
            stats.addDroppedFrames(1)
            return
        }
        show(image)
        stats.frameShown(captureMicros: captureMicros)
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
