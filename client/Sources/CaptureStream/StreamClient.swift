import Foundation
import Network

/// Owns one streaming session: the TCP control connection to capture-streamd, the two UDP
/// receivers, and the video/audio pipelines.
@MainActor
final class StreamClient: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case streaming
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var warning: String?
    @Published private(set) var snapshot = StreamStats.Snapshot()
    @Published private(set) var modes = ["720p60", "1080p30", "1080p60"]
    @Published var showStats = false
    var logStats = false

    let stats = StreamStats()
    lazy var video = VideoPipeline(stats: stats)
    private lazy var audio = AudioPlayer(stats: stats)

    private var control: NWConnection?
    private var videoReceiver: UDPReceiver?
    private var audioReceiver: UDPReceiver?
    private var pingTimer: Timer?
    private var lineBuffer = Data()
    private var bestRTT = Double.infinity

    func connect(host: String, mode: String) {
        disconnect()
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        state = .connecting
        warning = nil
        stats.reset()
        bestRTT = .infinity

        do {
            let video = self.video, audio = self.audio
            videoReceiver = try UDPReceiver(port: Wire.videoPort, receiveBufferBytes: 1 << 20, label: "video") {
                if let p = Wire.parseVideo($0) { video.handle(p) }
            }
            audioReceiver = try UDPReceiver(port: Wire.audioPort, receiveBufferBytes: 1 << 16, label: "audio") {
                if let p = Wire.parseAudio($0) { audio.handle(p) }
            }
            try audio.start()
        } catch {
            fail("Couldn't open the receive ports \(Wire.videoPort)/\(Wire.audioPort): \(error.localizedDescription)")
            return
        }

        let (hostPart, port) = Self.split(host)
        let connection = NWConnection(host: NWEndpoint.Host(hostPart), port: port, using: .tcp)
        control = connection
        connection.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in self?.controlStateChanged(newState, mode: mode) }
        }
        connection.start(queue: .main)
    }

    func disconnect() {
        if let control {
            send(["type": "bye"])
            control.cancel()
        }
        control = nil
        pingTimer?.invalidate()
        pingTimer = nil
        videoReceiver?.stop()
        audioReceiver?.stop()
        videoReceiver = nil
        audioReceiver = nil
        audio.stop()
        lineBuffer.removeAll()
        // Keep a failure message on screen; fail() sets it right after calling this.
        if case .failed = state {} else { state = .idle }
    }

    private func fail(_ message: String) {
        disconnect()
        state = .failed(message)
    }

    private func controlStateChanged(_ newState: NWConnection.State, mode: String) {
        switch newState {
        case .ready:
            send(["type": "hello", "mode": mode,
                  "video_port": Int(Wire.videoPort), "audio_port": Int(Wire.audioPort)])
            receive()
            pingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            tick()
        case .failed(let error):
            fail(state == .streaming ? "Lost the connection to the server."
                                     : "Connection failed: \(error.localizedDescription)")
        case .waiting(let error):
            fail("Can't reach the server: \(error.localizedDescription)")
        default:
            break
        }
    }

    private func tick() {
        send(["type": "ping", "t": Date().timeIntervalSince1970])
        guard state == .streaming else { return }
        snapshot = stats.snapshot()
        // Audio is heard after it also waits in the jitter buffer and the output device.
        snapshot.audioDelayMs = snapshot.audioDelayMs.map { $0 + audio.queuedMs + audio.outputLatencyMs }
        if logStats {
            let s = snapshot
            print(String(format: "fps %.1f  mbps %.1f  dropped %d (%d total)  video %@  audio %@  gaps %d  skips %d",
                         s.fps, s.mbps, s.droppedLastSecond, s.droppedTotal,
                         s.videoDelayMs.map { String(format: "%.0fms", $0) } ?? "-",
                         s.audioDelayMs.map { String(format: "%.0fms", $0) } ?? "-",
                         s.audioGaps, s.audioSkips))
            fflush(stdout)
        }
    }

    private func receive() {
        control?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data { self.lineBuffer.append(data); self.processLines() }
                if isComplete || error != nil {
                    if self.control != nil { self.fail("Lost the connection to the server.") }
                    return
                }
                self.receive()
            }
        }
    }

    private func processLines() {
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer[..<newline]
            lineBuffer.removeSubrange(...newline)
            guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = msg["type"] as? String else { continue }
            handle(type, msg)
        }
    }

    private func handle(_ type: String, _ msg: [String: Any]) {
        switch type {
        case "ok":
            if let m = msg["modes"] as? [String] { modes = m }
            video.reset(width: msg["width"] as? Int ?? 1280, height: msg["height"] as? Int ?? 720)
            state = .streaming
        case "pong":
            // Keep the offset from the fastest round trip: it has the least queueing error.
            guard let sent = msg["t"] as? Double, let server = msg["server_t"] as? Double else { return }
            let now = Date().timeIntervalSince1970
            let rtt = now - sent
            if rtt <= bestRTT {
                bestRTT = rtt
                stats.setClockOffset(micros: (server - (sent + now) / 2) * 1_000_000)
            }
        case "error":
            warning = msg["message"] as? String
        case "stopped":
            fail("Streaming stopped: \(msg["reason"] as? String ?? "server stopped")")
        default:
            break
        }
    }

    private func send(_ obj: [String: Any]) {
        guard let control, var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        control.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Accepts "host" or "host:port".
    private static func split(_ host: String) -> (String, NWEndpoint.Port) {
        if let colon = host.lastIndex(of: ":"), let port = UInt16(host[host.index(after: colon)...]),
           !host.contains("]") || host.hasSuffix("]:\(port)") {
            return (String(host[..<colon]), NWEndpoint.Port(rawValue: port)!)
        }
        return (host, NWEndpoint.Port(rawValue: Wire.defaultControlPort)!)
    }
}
