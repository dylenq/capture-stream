import SwiftUI

@main
struct CaptureStreamApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var client = StreamClient()
    @StateObject private var link = ControllerLink()
    @AppStorage("controllerEnabled") private var controllerEnabled = false

    var body: some Scene {
        Window("Capture Stream", id: "main") {
            ContentView(client: client, link: link)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    client.disconnect()
                    link.stop()
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
                Divider()
                Toggle("Use Controller on PS4", isOn: $controllerEnabled)
                    .keyboardShortcut("k")
            }
        }
    }
}

extension CaptureStreamApp {
    /// `--connect <host> [--mode <mode>]` connects on launch; `--controller <PS4 IP>` turns the
    /// controller link on; `--show-stats` turns the stats overlay on; `--log-stats` prints the
    /// stats line to stdout every second.
    private func applyLaunchArguments() {
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        if let console = value(after: "--controller") {
            UserDefaults.standard.set(console, forKey: "consoleHost")
            controllerEnabled = true
        }
        client.logStats = args.contains("--log-stats")
        link.logStatus = client.logStats
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
