import Foundation
import os

/// Thread-safe counters fed by the receive queues; `snapshot()` is read once a second.
final class StreamStats {
    struct Snapshot {
        var fps = 0.0
        var mbps = 0.0
        var droppedLastSecond = 0
        var droppedTotal = 0
        var videoDelayMs: Double?
        var audioDelayMs: Double?
        var audioGaps = 0
        var audioSkips = 0
    }

    private var lock = os_unfair_lock()
    private var clockOffsetMicros = 0.0 // server clock minus ours
    private var videoBytes = 0
    private var framesShown = 0
    private var dropped = 0
    private var droppedTotal = 0
    private var videoDelays: [Double] = []
    private var audioDelays: [Double] = []
    private var audioGaps = 0
    private var audioSkips = 0
    private var lastSnapshot = Date()

    func setClockOffset(micros: Double) { locked { clockOffsetMicros = micros } }
    func addVideoBytes(_ n: Int) { locked { videoBytes += n } }
    func addDroppedFrames(_ n: Int) { guard n > 0 else { return }; locked { dropped += n; droppedTotal += n } }
    func addAudioGap() { locked { audioGaps += 1 } }
    func addAudioSkip() { locked { audioSkips += 1 } }

    func frameShown(captureMicros: UInt64) {
        locked {
            framesShown += 1
            videoDelays.append(delayMs(captureMicros))
        }
    }

    func audioReceived(captureMicros: UInt64) {
        locked { audioDelays.append(delayMs(captureMicros)) }
    }

    func reset() {
        locked {
            videoBytes = 0; framesShown = 0; dropped = 0; droppedTotal = 0
            videoDelays.removeAll(); audioDelays.removeAll(); audioGaps = 0; audioSkips = 0
            lastSnapshot = Date()
        }
    }

    func snapshot() -> Snapshot {
        locked {
            let now = Date()
            let seconds = max(now.timeIntervalSince(lastSnapshot), 0.001)
            let s = Snapshot(fps: Double(framesShown) / seconds,
                             mbps: Double(videoBytes) * 8 / seconds / 1_000_000,
                             droppedLastSecond: dropped, droppedTotal: droppedTotal,
                             videoDelayMs: median(videoDelays), audioDelayMs: median(audioDelays),
                             audioGaps: audioGaps, audioSkips: audioSkips)
            lastSnapshot = now
            videoBytes = 0; framesShown = 0; dropped = 0
            videoDelays.removeAll(keepingCapacity: true); audioDelays.removeAll(keepingCapacity: true)
            return s
        }
    }

    /// Caller holds the lock.
    private func delayMs(_ captureMicros: UInt64) -> Double {
        (nowMicros() + clockOffsetMicros - Double(captureMicros)) / 1000
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }

    private func locked<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return body()
    }
}
