import AVFoundation
import os

/// Plays the server's raw PCM through CoreAudio with a small, actively bounded buffer.
/// If more than `maxBuffered` piles up (a network burst, a stall), the oldest audio is
/// skipped so sound never drifts behind the picture.
final class AudioPlayer {
    static let sampleRate = 48_000.0
    private static let channels = 2
    private static let targetFrames = Int(sampleRate * 0.020)   // 20 ms
    private static let maxBufferedFrames = Int(sampleRate * 0.060) // 60 ms

    private let engine = AVAudioEngine()
    private let stats: StreamStats
    private var lock = os_unfair_lock()
    // Interleaved Int16 ring buffer, 1 s capacity
    private var ring = [Int16](repeating: 0, count: Int(sampleRate) * channels)
    private var readIndex = 0
    private var writeIndex = 0
    private var buffered = 0 // frames
    private var priming = true
    private var lastSequence: UInt32?

    init(stats: StreamStats) {
        self.stats = stats
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: AVAudioChannelCount(Self.channels))!
        let source = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, audioBufferList in
            self.render(frames: Int(frameCount), into: UnsafeMutableAudioBufferListPointer(audioBufferList))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
    }

    /// Audio waiting in the ring buffer, in milliseconds.
    var queuedMs: Double {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return Double(buffered) / Self.sampleRate * 1000
    }

    /// Delay added by the output device and CoreAudio after a sample leaves our buffer.
    var outputLatencyMs: Double {
        (engine.outputNode.presentationLatency + engine.outputNode.outputPresentationLatency) * 1000
    }

    func start() throws {
        clear()
        try engine.start()
    }

    func stop() {
        engine.stop()
        clear()
    }

    private func clear() {
        os_unfair_lock_lock(&lock)
        readIndex = 0; writeIndex = 0; buffered = 0; priming = true; lastSequence = nil
        os_unfair_lock_unlock(&lock)
    }

    /// Called on the audio receive queue for every packet.
    func handle(_ packet: Wire.AudioPacket) {
        stats.audioReceived(captureMicros: packet.captureMicros)
        let frames = packet.samples.count / (2 * Self.channels)
        let capacity = ring.count / Self.channels
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if let last = lastSequence, packet.sequence &- last > 1 {
            stats.addAudioGap()
        }
        lastSequence = packet.sequence
        ring.withUnsafeMutableBufferPointer { ringPtr in
            for i in 0..<frames {
                for c in 0..<Self.channels {
                    let sample = packet.samples.loadUnaligned(fromByteOffset: (i * Self.channels + c) * 2, as: Int16.self)
                    ringPtr[(writeIndex * Self.channels) + c] = Int16(littleEndian: sample)
                }
                writeIndex = (writeIndex + 1) % capacity
            }
        }
        buffered += frames
        if buffered > Self.maxBufferedFrames {
            let skip = buffered - Self.targetFrames
            readIndex = (readIndex + skip) % capacity
            buffered -= skip
            stats.addAudioSkip()
        }
    }

    private func render(frames: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
        let capacity = ring.count / Self.channels
        let left = buffers[0].mData!.assumingMemoryBound(to: Float.self)
        let right = buffers[1].mData!.assumingMemoryBound(to: Float.self)
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if priming && buffered >= Self.targetFrames { priming = false }
        let available = priming ? 0 : min(frames, buffered)
        ring.withUnsafeBufferPointer { ringPtr in
            for i in 0..<available {
                left[i] = Float(ringPtr[readIndex * 2]) / 32768
                right[i] = Float(ringPtr[readIndex * 2 + 1]) / 32768
                readIndex = (readIndex + 1) % capacity
            }
        }
        buffered -= available
        if available < frames {
            for i in available..<frames { left[i] = 0; right[i] = 0 }
            if !priming { priming = true } // ran dry: refill to the target before playing again
        }
    }
}
