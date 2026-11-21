import Foundation
import QuartzCore

/// Sends the Mac's game controller to a PS4 running Control4Free, which turns it into a
/// virtual DualShock 4 that works everywhere on the console (home screen, sign-in, games).
/// Protocol: https://github.com/MoHadiShibli/Control4Free/blob/main/docs/protocol.md
@MainActor
final class ControllerLink: ObservableObject {
    enum Status: Equatable {
        case off
        case connecting
        case choosingUser
        case ready(user: String)
        case paused
        case failed(String)
    }

    static let port: UInt16 = 4264

    @Published private(set) var status: Status = .off {
        didSet { if logStatus && status != oldValue { log("status: \(status)") } }
    }
    @Published private(set) var rttMs: Double?
    /// Prints status changes and round-trip times to stdout (`--log-stats`).
    var logStatus = false
    @Published private(set) var padNumber: Int?
    let input = ControllerInput()
    let bridge = WebRTCBridge()

    private var host = ""
    private var enabled = false
    private var connected = false
    private var pad: Int?
    private var nextRequestID = 1
    private var replies: [Int: ([String: Any]) -> Void] = [:]
    private var inputSequence = 0
    private var buttonHistory: [(sequence: Int, buttons: UInt32)] = []
    private var lastSentButtons: UInt32 = 0
    private var lastSend = CACurrentMediaTime()
    private var probeSequence = 0
    private var keepalive: Timer?
    private var probe: Timer?
    private var reconnect: DispatchWorkItem?

    init() {
        bridge.onEvent = { [weak self] event in self?.handle(event) }
        input.onChange = { [weak self] state in self?.sendInput(state) }
    }

    func start(host: String) {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        if enabled && host == self.host { return }
        stop()
        self.host = host
        enabled = true
        connect()
    }

    func stop() {
        enabled = false
        reconnect?.cancel()
        if connected, let pad {
            sendControl("leave", [pad])
        }
        tearDown()
        pad = nil
        padNumber = nil
        status = .off
    }

    // MARK: - Connection

    private func connect() {
        tearDown()
        status = .connecting
        bridge.start()
    }

    private func tearDown() {
        keepalive?.invalidate()
        probe?.invalidate()
        keepalive = nil
        probe = nil
        connected = false
        replies.removeAll()
        rttMs = nil
        input.rumble(large: 0, small: 0)
        bridge.stop()
    }

    private func scheduleReconnect(_ reason: String) {
        guard enabled else { return }
        tearDown()
        status = .failed(reason)
        reconnect?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.enabled else { return }
            self.connect()
        }
        reconnect = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }

    private func handle(_ event: WebRTCBridge.Event) {
        guard enabled else { return }
        switch event {
        case .offer(let sdp):
            let host = self.host
            Task {
                do {
                    let answer = try await postOffer(sdp, host: host, port: Self.port)
                    guard self.enabled, host == self.host else { return }
                    self.bridge.answer(answer)
                } catch {
                    self.scheduleReconnect("Can't reach Control4Free on \(host): \(error.localizedDescription)")
                }
            }
        case .open:
            connected = true
            inputSequence = 0
            buttonHistory.removeAll()
            keepalive = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sendKeepalive() }
            }
            probe = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sendProbe() }
            }
            claimPad()
        case .closed:
            scheduleReconnect("Lost the connection to Control4Free.")
        case .failed(let message):
            scheduleReconnect("WebRTC failed: \(message)")
        case .message(let channel, let text):
            guard let data = text.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            channel == "input" ? handleInputMessage(msg) : handleControlMessage(msg)
        }
    }

    // MARK: - Control channel

    /// Reclaims the controller this app had (it survives a short disconnect), otherwise takes
    /// the first free one.
    private func claimPad() {
        request("status", []) { [weak self] reply in
            guard let self, let result = reply["result"] as? [String: Any],
                  let pads = result["pads"] as? [[String: Any]] else {
                self?.scheduleReconnect("Control4Free didn't send its controller list.")
                return
            }
            let free = pads.first { ($0["clients"] as? Int ?? 1) == 0 && ($0["enabled"] as? Bool ?? true) }
            let wanted = self.pad ?? (free?["pad"] as? Int)
            guard let wanted else {
                self.scheduleReconnect("All four Control4Free controllers are in use.")
                return
            }
            self.request("claim", [wanted]) { [weak self] reply in
                guard let self else { return }
                if let error = reply["error"] as? [String: Any] {
                    let code = error["code"] as? Int ?? 0
                    // Our old slot was taken by someone else: forget it and pick a free one.
                    if code == 409, self.pad != nil { self.pad = nil }
                    self.scheduleReconnect(error["message"] as? String ?? "Couldn't claim a controller.")
                    return
                }
                self.pad = wanted
                self.padNumber = wanted + 1
                self.sendInput(self.input.state)
                if let result = reply["result"] as? [String: Any] { self.apply(status: result) }
            }
        }
    }

    private func handleControlMessage(_ msg: [String: Any]) {
        if let id = msg["id"] as? Int, let reply = replies.removeValue(forKey: id) {
            reply(msg)
            return
        }
        switch msg["method"] as? String {
        case "s":
            if let status = msg["params"] as? [String: Any] { apply(status: status) }
        case "error":
            let message = (msg["params"] as? [String: Any])?["message"] as? String ?? "Control4Free error"
            status = .failed(message)
        default:
            break
        }
    }

    private func apply(status: [String: Any]) {
        guard let pad, let pads = status["pads"] as? [[String: Any]],
              let mine = pads.first(where: { $0["pad"] as? Int == pad }) else { return }
        if mine["mine"] as? Bool == false && mine["open"] as? Bool == false {
            // Removed by the PS4 (user signed out, or idle too long): claim again.
            self.pad = nil
            claimPad()
            return
        }
        switch mine["state"] as? String {
        case "ready": self.status = .ready(user: mine["user"] as? String ?? "")
        case "select": self.status = .choosingUser
        case "paused": self.status = .paused
        case "connecting": self.status = .connecting
        case "error": self.status = .failed("The PS4 refused input (error \(mine["error"] as? Int ?? 0)).")
        default: break
        }
        if let color = mine["color"] as? [Int], color.count == 3 {
            input.setLight(red: color[0], green: color[1], blue: color[2])
        }
    }

    private func request(_ method: String, _ params: [Int], reply: @escaping ([String: Any]) -> Void) {
        let id = nextRequestID
        nextRequestID += 1
        replies[id] = reply
        send(channel: "control", ["id": id, "method": method, "params": params])
    }

    private func sendControl(_ method: String, _ params: [Int]) {
        send(channel: "control", ["method": method, "params": params])
    }

    // MARK: - Input channel

    private func handleInputMessage(_ msg: [String: Any]) {
        guard let params = msg["params"] as? [Any] else { return }
        switch msg["method"] as? String {
        case "v":
            if params.count == 3, params[0] as? Int == pad {
                input.rumble(large: params[1] as? Int ?? 0, small: params[2] as? Int ?? 0)
            }
        case "e":
            guard params.count == 2, let sequence = params[0] as? Int,
                  let sent = (params[1] as? NSNumber)?.doubleValue else { return }
            let rtt = CACurrentMediaTime() * 1000 - sent
            rttMs = rtt
            if logStatus { log(String(format: "rtt %.1f ms, %d inputs sent", rtt, inputSequence)) }
            // Shown in Control4Free's tester on the PS4; purely informational.
            send(channel: "input", ["method": "latency", "params": [sequence, Int(rtt.rounded())]])
        default:
            break
        }
    }

    /// Sends the complete controller state. Up to four recent button changes ride along, so
    /// Control4Free can replay a press whose own message was lost (input isn't retransmitted).
    private func sendInput(_ state: PadState) {
        guard connected, let pad else { return }
        inputSequence += 1
        var params: [Int] = [pad, inputSequence, Int(state.buttons), state.lx, state.ly, state.rx, state.ry,
                             state.l2, state.r2, state.touches.count]
        for touch in state.touches.prefix(2) { params += [touch.id, touch.x, touch.y] }
        params.append(buttonHistory.count)
        for change in buttonHistory { params += [change.sequence, Int(change.buttons)] }
        send(channel: "input", ["method": "i", "params": params])
        lastSend = CACurrentMediaTime()

        if state.buttons != lastSentButtons {
            lastSentButtons = state.buttons
            buttonHistory.append((inputSequence, state.buttons))
            if buttonHistory.count > 4 { buttonHistory.removeFirst() }
        }
    }

    /// Control4Free pauses a controller after 3 s without input; resending the state every
    /// 250 ms also lets a lost final release get through quickly.
    private func sendKeepalive() {
        if CACurrentMediaTime() - lastSend >= 0.25 { sendInput(input.state) }
    }

    private func sendProbe() {
        probeSequence += 1
        // Request params must be integers: whole milliseconds on the Mac's monotonic clock.
        send(channel: "input", ["method": "e", "params": [probeSequence, Int(CACurrentMediaTime() * 1000)]])
    }

    private func log(_ message: String) {
        print("controller: \(message)")
        fflush(stdout)
    }

    private func send(channel: String, _ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        bridge.send(channel: channel, text: text)
    }
}
