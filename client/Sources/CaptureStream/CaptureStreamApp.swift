import SwiftUI

@main
struct CaptureStreamApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var client = StreamClient()

    var body: some Scene {
        Window("Capture Stream", id: "main") {
            ContentView(client: client)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    client.disconnect()
                }
                .onAppear(perform: applyLaunchArguments)
        }
        .defaultSize(width: 1280, height: 720)
        .commands {
            CommandMenu("Stream") {
                Button("Disconnect") { client.disconnect() }
                    .keyboardShortcut("d")
                    .disabled(client.state != .streaming)
                Button(client.showStats ? "Hide Stats" : "Show Stats") { client.showStats.toggle() }
                    .keyboardShortcut("s", modifiers: [])
                Button("Toggle Full Screen") { toggleFullScreen() }
                    .keyboardShortcut("f")
            }
        }
    }
}

extension CaptureStreamApp {
    /// `--connect <host> [--mode <mode>]` connects on launch; `--show-stats` turns the stats
    /// overlay on; `--log-stats` prints the stats line to stdout every second.
    private func applyLaunchArguments() {
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        client.logStats = args.contains("--log-stats")
        if args.contains("--show-stats") { client.showStats = true }
        if let host = value(after: "--connect") {
            let mode = value(after: "--mode") ?? UserDefaults.standard.string(forKey: "mode") ?? "720p60"
            UserDefaults.standard.set(host, forKey: "host")
            UserDefaults.standard.set(mode, forKey: "mode")
            client.connect(host: host, mode: mode)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched as a bare SwiftPM executable (no bundle), make it a regular foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
