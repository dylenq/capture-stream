import Foundation
import Network
import WebKit

/// WebRTC data channels through a hidden WKWebView. macOS has no native WebRTC API, and
/// WebKit's is built in, so this needs no third-party library. Swift posts the SDP offer to
/// the console itself (see `postOffer`); the page only runs the peer connection.
@MainActor
final class WebRTCBridge: NSObject {
    enum Event {
        case offer(String)
        case open
        case closed
        case message(channel: String, text: String)
        case failed(String)
    }

    /// Must be in a window's view hierarchy, or WebKit may suspend the page.
    let webView: WKWebView
    var onEvent: ((Event) -> Void)?
    private var loaded = false
    private var startWhenLoaded = false

    override init() {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        super.init()
        config.userContentController.add(WeakMessageHandler(self), name: "bridge")
        // An https base URL makes the page a secure context, where WebKit exposes WebRTC.
        // Nothing is fetched from it.
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://capture-stream.invalid/"))
    }

    func start() {
        guard loaded else { startWhenLoaded = true; return }
        call("start()")
    }

    func answer(_ sdp: String) {
        call("answer(sdp)", ["sdp": sdp])
    }

    func send(channel: String, text: String) {
        call("send(channel, text)", ["channel": channel, "text": text])
    }

    func stop() {
        startWhenLoaded = false
        if loaded { call("stop()") }
    }

    private func call(_ body: String, _ arguments: [String: Any] = [:]) {
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page, completionHandler: nil)
    }

    fileprivate func received(_ body: Any) {
        guard let msg = body as? [String: Any], let type = msg["type"] as? String else { return }
        switch type {
        case "loaded":
            loaded = true
            if startWhenLoaded { startWhenLoaded = false; call("start()") }
        case "offer": onEvent?(.offer(msg["sdp"] as? String ?? ""))
        case "open": onEvent?(.open)
        case "closed": onEvent?(.closed)
        case "message": onEvent?(.message(channel: msg["channel"] as? String ?? "", text: msg["data"] as? String ?? ""))
        case "failed": onEvent?(.failed(msg["message"] as? String ?? "WebRTC error"))
        default: break
        }
    }

    /// Two negotiated channels, as Control4Free expects: `control` (reliable, ordered) and
    /// `input` (unordered, no retransmits). Each handler checks it still belongs to the current
    /// connection, so closing an old one during a restart doesn't report the new one closed.
    private static let page = """
    <!doctype html><meta charset="utf-8"><script>
    const post = m => window.webkit.messageHandlers.bridge.postMessage(m);
    let pc = null, channels = {};
    async function start() {
      stop();
      try {
        const mine = pc = new RTCPeerConnection({iceServers: []});
        channels = {
          control: pc.createDataChannel('control', {negotiated: true, id: 0, ordered: true}),
          input: pc.createDataChannel('input', {negotiated: true, id: 1, ordered: false, maxRetransmits: 0}),
        };
        let open = 0;
        for (const [name, ch] of Object.entries(channels)) {
          ch.onopen = () => { if (pc === mine && ++open === 2) post({type: 'open'}); };
          ch.onclose = () => { if (pc === mine) post({type: 'closed'}); };
          ch.onmessage = e => { if (pc === mine) post({type: 'message', channel: name, data: String(e.data)}); };
        }
        pc.onconnectionstatechange = () => {
          if (pc === mine && ['failed', 'closed'].includes(mine.connectionState)) post({type: 'closed'});
        };
        await pc.setLocalDescription(await pc.createOffer());
        post({type: 'offer', sdp: pc.localDescription.sdp});
      } catch (e) { post({type: 'failed', message: String(e)}); }
    }
    async function answer(sdp) {
      try { await pc.setRemoteDescription({type: 'answer', sdp}); }
      catch (e) { post({type: 'failed', message: String(e)}); }
    }
    function send(channel, text) {
      const ch = channels[channel];
      if (ch && ch.readyState === 'open') ch.send(text);
    }
    function stop() {
      if (!pc) return;
      const old = pc;
      pc = null;
      channels = {};
      old.close();
    }
    post({type: 'loaded'});
    </script>
    """
}

/// WKUserContentController keeps a strong reference to its handlers.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var bridge: WebRTCBridge?
    init(_ bridge: WebRTCBridge) { self.bridge = bridge }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { bridge?.received(body) }
    }
}

enum OfferError: LocalizedError {
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .http(503, _): return "The PS4 has no free controller slot right now."
        case .http(let code, let text): return "The PS4 refused the connection (\(code) \(text))."
        case .badResponse: return "The PS4 sent an answer that isn't WebRTC."
        }
    }
}

/// POSTs a WebRTC offer to Control4Free's `/rtc` and returns the SDP answer. Plain HTTP/1.1 over
/// Network.framework: the service wants a literal IPv4 Host header and Content-Length, and a raw
/// request keeps App Transport Security out of the way of a plain-http IP address.
func postOffer(_ sdp: String, host: String, port: UInt16) async throws -> String {
    let body = Data(sdp.utf8)
    var request = Data("""
    POST /rtc HTTP/1.1\r
    Host: \(host):\(port)\r
    Content-Type: text/plain\r
    Content-Length: \(body.count)\r
    Connection: close\r
    \r

    """.utf8)
    request.append(body)
    let payload = request

    let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    defer { connection.cancel() }
    let response: Data = try await withCheckedThrowingContinuation { continuation in
        let finished = Atomic(false)
        func finish(_ result: Result<Data, Error>) {
            if finished.exchange(true) { return }
            continuation.resume(with: result)
        }
        var received = Data()
        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data { received.append(data) }
                if let error { finish(.failure(error)) } else if isComplete { finish(.success(received)) } else { readMore() }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: payload, completion: .contentProcessed { error in
                    if let error { finish(.failure(error)) }
                })
                readMore()
            case .failed(let error), .waiting(let error):
                finish(.failure(error))
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            finish(.failure(POSIXError(.ETIMEDOUT)))
        }
    }

    guard let text = String(data: response, encoding: .utf8),
          let split = text.range(of: "\r\n\r\n") else { throw OfferError.badResponse }
    let statusLine = text[..<split.lowerBound].split(separator: "\r\n").first ?? ""
    let parts = statusLine.split(separator: " ", maxSplits: 2)
    let code = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    guard code == 200 else { throw OfferError.http(code, parts.count > 2 ? String(parts[2]) : "") }
    let answer = String(text[split.upperBound...])
    guard answer.hasPrefix("v=0") else { throw OfferError.badResponse }
    return answer
}

/// A tiny lock-protected flag, so a continuation resumes exactly once across queues.
private final class Atomic: @unchecked Sendable {
    private var value: Bool
    private let lock = NSLock()
    init(_ value: Bool) { self.value = value }
    func exchange(_ new: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let old = value
        value = new
        return old
    }
}
