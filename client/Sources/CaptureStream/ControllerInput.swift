import CoreHaptics
import GameController

/// One DualShock 4's worth of state, in Control4Free's units: sticks and triggers 0–255
/// (sticks centred at 128, up and left 0), touch positions on a 1920×942 pad.
struct PadState: Equatable {
    struct Touch: Equatable {
        var id: Int
        var x: Int
        var y: Int
    }

    var buttons: UInt32 = 0
    var lx = 128, ly = 128, rx = 128, ry = 128
    var l2 = 0, r2 = 0
    var touches: [Touch] = []

    static let share: UInt32 = 0x0001, l3: UInt32 = 0x0002, r3: UInt32 = 0x0004, options: UInt32 = 0x0008
    static let up: UInt32 = 0x0010, right: UInt32 = 0x0020, down: UInt32 = 0x0040, left: UInt32 = 0x0080
    static let l2Button: UInt32 = 0x0100, r2Button: UInt32 = 0x0200, l1: UInt32 = 0x0400, r1: UInt32 = 0x0800
    static let triangle: UInt32 = 0x1000, circle: UInt32 = 0x2000, cross: UInt32 = 0x4000, square: UInt32 = 0x8000
    static let ps: UInt32 = 0x10000, touchpad: UInt32 = 0x100000
}

/// Reads the first connected game controller with Apple's GameController framework, even while
/// the app is in the background, and drives its rumble and light bar. Any controller macOS
/// supports works (DualShock 4, DualSense, Xbox, …); the PS4 always sees a DualShock 4.
@MainActor
final class ControllerInput: ObservableObject {
    @Published private(set) var name: String?
    /// Called on every change of the controller's state.
    var onChange: ((PadState) -> Void)?
    private(set) var state = PadState()

    private var controller: GCController?
    private var hapticEngine: CHHapticEngine?
    private var hapticPlayer: CHHapticAdvancedPatternPlayer?
    private var rumbleTimeout: DispatchWorkItem?
    private var touchIDs: [Int?] = [nil, nil]
    private var nextTouchID = 0

    init() {
        // Keep receiving input when the stream window isn't frontmost.
        GCController.shouldMonitorBackgroundEvents = true
        let center = NotificationCenter.default
        center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            let controller = note.object as? GCController
            MainActor.assumeIsolated { if self?.controller == nil, let controller { self?.attach(controller) } }
        }
        center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            let controller = note.object as? GCController
            MainActor.assumeIsolated {
                guard let self, controller === self.controller else { return }
                self.detach()
                if let next = GCController.controllers().first(where: { $0.extendedGamepad != nil }) { self.attach(next) }
            }
        }
        if let first = GCController.controllers().first(where: { $0.extendedGamepad != nil }) { attach(first) }
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        self.controller = controller
        name = controller.vendorName ?? "Game controller"
        // Without this, macOS takes the PS/Home and Share buttons for its own gestures
        // (Launchpad, screenshots) instead of passing them to the app.
        for button in controller.physicalInputProfile.allButtons {
            button.preferredSystemGestureState = .disabled
        }
        pad.valueChangedHandler = { [weak self] gamepad, _ in
            MainActor.assumeIsolated { self?.update(from: gamepad) }
        }
        update(from: pad)
    }

    private func detach() {
        controller?.extendedGamepad?.valueChangedHandler = nil
        controller = nil
        name = nil
        hapticPlayer = nil
        hapticEngine?.stop()
        hapticEngine = nil
        state = PadState()
        onChange?(state)
    }

    private func update(from pad: GCExtendedGamepad) {
        var s = PadState()
        func set(_ bit: UInt32, _ pressed: Bool?) { if pressed == true { s.buttons |= bit } }
        set(PadState.cross, pad.buttonA.isPressed)
        set(PadState.circle, pad.buttonB.isPressed)
        set(PadState.square, pad.buttonX.isPressed)
        set(PadState.triangle, pad.buttonY.isPressed)
        set(PadState.l1, pad.leftShoulder.isPressed)
        set(PadState.r1, pad.rightShoulder.isPressed)
        set(PadState.l2Button, pad.leftTrigger.isPressed)
        set(PadState.r2Button, pad.rightTrigger.isPressed)
        set(PadState.l3, pad.leftThumbstickButton?.isPressed)
        set(PadState.r3, pad.rightThumbstickButton?.isPressed)
        set(PadState.options, pad.buttonMenu.isPressed)
        set(PadState.share, pad.buttonOptions?.isPressed)
        set(PadState.ps, pad.buttonHome?.isPressed)
        set(PadState.up, pad.dpad.up.isPressed)
        set(PadState.down, pad.dpad.down.isPressed)
        set(PadState.left, pad.dpad.left.isPressed)
        set(PadState.right, pad.dpad.right.isPressed)

        s.lx = Self.axis(pad.leftThumbstick.xAxis.value)
        s.ly = Self.axis(-pad.leftThumbstick.yAxis.value)
        s.rx = Self.axis(pad.rightThumbstick.xAxis.value)
        s.ry = Self.axis(-pad.rightThumbstick.yAxis.value)
        s.l2 = Int((pad.leftTrigger.value * 255).rounded())
        s.r2 = Int((pad.rightTrigger.value * 255).rounded())

        if let ds4 = pad as? GCDualShockGamepad {
            set(PadState.touchpad, ds4.touchpadButton.isPressed)
            s.touches = touches(ds4.touchpadPrimary, ds4.touchpadSecondary)
        } else if let dualSense = pad as? GCDualSenseGamepad {
            set(PadState.touchpad, dualSense.touchpadButton.isPressed)
            s.touches = touches(dualSense.touchpadPrimary, dualSense.touchpadSecondary)
        }

        guard s != state else { return }
        state = s
        onChange?(s)
    }

    /// GameController reports touch positions from −1 to 1 and exactly 0,0 when no finger is
    /// down. A new finger gets a new id, as the DS4 does.
    private func touches(_ primary: GCControllerDirectionPad, _ secondary: GCControllerDirectionPad) -> [PadState.Touch] {
        var result: [PadState.Touch] = []
        for (slot, pad) in [primary, secondary].enumerated() {
            let x = pad.xAxis.value, y = pad.yAxis.value
            guard x != 0 || y != 0 else {
                touchIDs[slot] = nil
                continue
            }
            let id = touchIDs[slot] ?? {
                nextTouchID = (nextTouchID + 1) & 0x7F
                return nextTouchID
            }()
            touchIDs[slot] = id
            result.append(PadState.Touch(id: id,
                                         x: Int(((x + 1) / 2 * 1919).rounded()).clamped(0, 1919),
                                         y: Int(((1 - y) / 2 * 941).rounded()).clamped(0, 941)))
        }
        return result
    }

    private static func axis(_ value: Float) -> Int {
        Int(((value + 1) / 2 * 255).rounded()).clamped(0, 255)
    }

    /// Plays the PS4's rumble (0–255 per motor). Control4Free repeats nonzero rumble every
    /// 200 ms, so it stops by itself if no renewal arrives within 650 ms.
    func rumble(large: Int, small: Int) {
        rumbleTimeout?.cancel()
        let level = Float(max(large, small)) / 255
        guard level > 0 else {
            try? hapticPlayer?.stop(atTime: CHHapticTimeImmediate)
            return
        }
        do {
            if hapticPlayer == nil {
                guard let engine = controller?.haptics?.createEngine(withLocality: .default) else { return }
                try engine.start()
                let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: large >= small ? 0.2 : 0.8),
                ], relativeTime: 0, duration: 30)
                let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
                player.loopEnabled = true
                hapticEngine = engine
                hapticPlayer = player
            }
            try hapticPlayer?.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                                                       value: level, relativeTime: 0)],
                                             atTime: CHHapticTimeImmediate)
            try hapticPlayer?.start(atTime: CHHapticTimeImmediate)
        } catch {
            hapticPlayer = nil
            hapticEngine = nil
        }
        let timeout = DispatchWorkItem { [weak self] in try? self?.hapticPlayer?.stop(atTime: CHHapticTimeImmediate) }
        rumbleTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: timeout)
    }

    /// Sets the controller's light bar to the colour the PS4 gave its virtual controller.
    func setLight(red: Int, green: Int, blue: Int) {
        controller?.light?.color = GCColor(red: Float(red) / 255, green: Float(green) / 255, blue: Float(blue) / 255)
    }
}

private extension Int {
    func clamped(_ low: Int, _ high: Int) -> Int { Swift.min(Swift.max(self, low), high) }
}
