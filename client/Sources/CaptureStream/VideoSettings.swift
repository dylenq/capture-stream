import Foundation

/// Picture settings, stored in UserDefaults so the Settings window, the Stream menu and the
/// launch flags all write the same place. VideoPipeline reloads them whenever they change.
struct VideoSettings: Equatable {
    enum Key {
        static let upscale = "upscale"
        static let upscaleTarget = "upscaleTarget"
        static let sharpness = "sharpness"
        static let fpsCap = "fpsCap"
        static let scalingFilter = "scalingFilter"
        static let customWidth = "customWidth"
        static let customHeight = "customHeight"
        static let customFps = "customFps"
    }

    /// What MetalFX upscales to. The display layer then fits the result to the window.
    enum UpscaleTarget: String, CaseIterable, Identifiable {
        case window, x1_5 = "1.5x", x2 = "2x", p1440 = "1440p", p2160 = "2160p"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .window: return "Window size"
            case .x1_5: return "1.5×"
            case .x2: return "2×"
            case .p1440: return "1440p"
            case .p2160: return "4K (2160p)"
            }
        }
    }

    /// How the display layer scales frames that aren't upscaled (or don't exactly fit).
    enum ScalingFilter: String, CaseIterable, Identifiable {
        case smooth, sharp
        var id: String { rawValue }
        var label: String { self == .smooth ? "Smooth" : "Sharp pixels" }
    }

    static let fpsCaps = [0, 60, 50, 30, 24]

    var upscale = false
    var target = UpscaleTarget.window
    /// 0 is off; up to 1 for the strongest contrast-adaptive sharpening after MetalFX.
    var sharpness = 0.0
    /// Frames shown per second at most; 0 shows every frame.
    var fpsCap = 0
    var filter = ScalingFilter.smooth

    static func load(_ defaults: UserDefaults = .standard) -> VideoSettings {
        VideoSettings(
            upscale: defaults.bool(forKey: Key.upscale),
            target: defaults.string(forKey: Key.upscaleTarget).flatMap(UpscaleTarget.init) ?? .window,
            sharpness: min(max(defaults.double(forKey: Key.sharpness), 0), 1),
            fpsCap: max(defaults.integer(forKey: Key.fpsCap), 0),
            filter: defaults.string(forKey: Key.scalingFilter).flatMap(ScalingFilter.init) ?? .smooth)
    }

    /// The custom capture mode chosen in Settings (sent to the server as width/height/fps).
    static func customMode(_ defaults: UserDefaults = .standard) -> (width: Int, height: Int, fps: Int) {
        func value(_ key: String, _ fallback: Int) -> Int {
            defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
        }
        return (value(Key.customWidth, 1600), value(Key.customHeight, 900), value(Key.customFps, 60))
    }
}
