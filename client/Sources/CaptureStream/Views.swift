import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var client: StreamClient
    @AppStorage("host") private var host = ""
    @AppStorage("mode") private var mode = "720p60"
    @State private var hovering = false

    var body: some View {
        Group {
            if client.state == .streaming {
                streamView
            } else {
                connectView
            }
        }
        .frame(minWidth: 480, minHeight: 270)
        .background(Color.black)
    }

    private var streamView: some View {
        VideoView(layer: client.video.displayLayer)
            .ignoresSafeArea()
            .onTapGesture(count: 2) { toggleFullScreen() }
            .onHover { hovering = $0 }
            .overlay(alignment: .topLeading) {
                if client.showStats { StatsOverlay(snapshot: client.snapshot).padding(10) }
            }
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button("Disconnect") { client.disconnect() }
                        .padding(10)
                }
            }
            .overlay(alignment: .bottom) {
                if let warning = client.warning {
                    Text(warning)
                        .padding(8)
                        .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(.white)
                        .padding()
                }
            }
            .onExitCommand { exitFullScreen() }
    }

    private var connectView: some View {
        VStack(spacing: 16) {
            Text("Capture Stream").font(.title2.bold())
            Form {
                TextField("Server", text: $host, prompt: Text("hostname or IP"))
                    .onSubmit(connect)
                Picker("Mode", selection: $mode) {
                    ForEach(client.modes, id: \.self) { Text($0) }
                }
            }
            .frame(width: 320)
            Button(client.state == .connecting ? "Connecting…" : "Connect", action: connect)
                .keyboardShortcut(.defaultAction)
                .disabled(host.isEmpty || client.state == .connecting)
            if case .failed(let message) = client.state {
                Text(message).foregroundStyle(.red).multilineTextAlignment(.center).frame(maxWidth: 360)
            }
            Text("⌘F full screen · S stats · ⌘D disconnect")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func connect() {
        client.connect(host: host, mode: mode)
    }
}

struct StatsOverlay: View {
    let snapshot: StreamStats.Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "%.1f fps  %.1f Mbps", snapshot.fps, snapshot.mbps))
            Text("dropped \(snapshot.droppedLastSecond)/s, \(snapshot.droppedTotal) total")
            Text("video delay \(ms(snapshot.videoDelayMs))  audio delay \(ms(snapshot.audioDelayMs))")
            Text("audio gaps \(snapshot.audioGaps)  skips \(snapshot.audioSkips)")
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }

    private func ms(_ value: Double?) -> String {
        value.map { String(format: "%.0f ms", $0) } ?? "–"
    }
}

/// Hosts the AVSampleBufferDisplayLayer that shows decoded frames. The cursor hides itself
/// after a few seconds without mouse movement (like a video player or game) and comes back
/// on the next move.
struct VideoView: NSViewRepresentable {
    let layer: CALayer

    func makeNSView(context: Context) -> NSView {
        let view = LayerHostView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.hosted = layer
        view.layer?.addSublayer(layer)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class LayerHostView: NSView {
        var hosted: CALayer?
        private static let idleHideDelay: TimeInterval = 2.5
        private var idleHideItem: DispatchWorkItem?
        private var cursorHidden = false

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted?.frame = bounds
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
            if window != nil {
                noteCursorActivity()
            } else {
                revealCursor()
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        override func mouseMoved(with event: NSEvent) { noteCursorActivity() }
        override func mouseEntered(with event: NSEvent) { noteCursorActivity() }
        override func mouseExited(with event: NSEvent) { revealCursor() }

        /// The cursor moved, or the mouse is over the view: show it and restart the idle timer.
        private func noteCursorActivity() {
            idleHideItem?.cancel()
            if cursorHidden {
                NSCursor.unhide()
                cursorHidden = false
            }
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.window?.isKeyWindow == true else { return }
                NSCursor.hide()
                self.cursorHidden = true
            }
            idleHideItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleHideDelay, execute: item)
        }

        /// Show the cursor and stop the hide timer (leaving the view, disconnecting, deinit).
        private func revealCursor() {
            idleHideItem?.cancel()
            idleHideItem = nil
            if cursorHidden {
                NSCursor.unhide()
                cursorHidden = false
            }
        }

        deinit { revealCursor() }
    }
}

func toggleFullScreen() {
    NSApp.keyWindow?.toggleFullScreen(nil)
}

func exitFullScreen() {
    if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
        window.toggleFullScreen(nil)
    }
}
