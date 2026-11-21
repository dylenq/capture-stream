import SwiftUI

/// The Settings window (⌘,). Everything here is stored in UserDefaults and applied live.
struct SettingsView: View {
    private typealias Key = VideoSettings.Key
    @AppStorage(Key.upscale) private var upscale = false
    @AppStorage(Key.upscaleTarget) private var target = VideoSettings.UpscaleTarget.window
    @AppStorage(Key.sharpness) private var sharpness = 0.0
    @AppStorage(Key.fpsCap) private var fpsCap = 0
    @AppStorage(Key.scalingFilter) private var filter = VideoSettings.ScalingFilter.smooth
    @AppStorage(Key.customWidth) private var customWidth = 1600
    @AppStorage(Key.customHeight) private var customHeight = 900
    @AppStorage(Key.customFps) private var customFps = 60

    var body: some View {
        Form {
            Section {
                Toggle("MetalFX upscaling", isOn: $upscale)
                Picker("Upscale to", selection: $target) {
                    ForEach(VideoSettings.UpscaleTarget.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!upscale)
                LabeledContent("Sharpening") {
                    HStack {
                        Slider(value: $sharpness, in: 0...1)
                        Text(sharpness == 0 ? "Off" : "\(Int((sharpness * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                .disabled(!upscale)
            } header: {
                Text("Upscaling")
            } footer: {
                Text("Window size upscales to exactly fit the window. Fixed sizes are fitted to the window afterwards. Adds about 3–5 ms of video delay.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Picker("Frame rate cap", selection: $fpsCap) {
                    ForEach(VideoSettings.fpsCaps, id: \.self) { Text($0 == 0 ? "Unlimited" : "\($0) fps").tag($0) }
                }
                Picker("Scaling filter", selection: $filter) {
                    ForEach(VideoSettings.ScalingFilter.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Display")
            } footer: {
                Text("The cap skips frames on the Mac; to save bandwidth too, use a custom mode with a lower fps. Sharp pixels scales with nearest-neighbour instead of smoothing; it applies when MetalFX is off.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                TextField("Width", value: $customWidth, format: .number.grouping(.never))
                TextField("Height", value: $customHeight, format: .number.grouping(.never))
                TextField("Frame rate", value: $customFps, format: .number.grouping(.never))
            } header: {
                Text("Custom capture mode")
            } footer: {
                Text("Choose Custom as the mode when connecting. Width and height 160–4096, 1–240 fps; the capture card must support MJPEG at that size and rate.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
