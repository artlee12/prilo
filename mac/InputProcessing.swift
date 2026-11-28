import Foundation

struct PointerMotion {
    let speed: Double
    private var remainderX = 0.0
    private var remainderY = 0.0

    init(speed: Double) {
        self.speed = speed.isFinite ? min(2, max(0.2, speed)) : 1
    }

    mutating func scale(x: Int32, y: Int32) -> (x: Int32, y: Int32) {
        let scaledX = Double(min(5000, max(-5000, x))) * speed + remainderX
        let scaledY = Double(min(5000, max(-5000, y))) * speed + remainderY
        let wholeX = scaledX.rounded(.towardZero)
        let wholeY = scaledY.rounded(.towardZero)
        remainderX = scaledX - wholeX
        remainderY = scaledY - wholeY
        return (Int32(wholeX), Int32(wholeY))
    }
}

struct ScrollMotion {
    let smoothness: Double
    private var remainderX = 0.0
    private var remainderY = 0.0

    init(smoothness: Double) {
        self.smoothness = smoothness.isFinite ? min(3.0, max(0.2, smoothness)) : 1.0
    }

    mutating func scale(x: Double, y: Double, continuous: Bool) -> (x: Int32, y: Int32) {
        let clampedX = continuous ? min(4000.0, max(-4000.0, x)) : min(50.0, max(-50.0, x))
        let clampedY = continuous ? min(4000.0, max(-4000.0, y)) : min(50.0, max(-50.0, y))
        let factor = (continuous ? 2.2 : 120.0) * smoothness
        let scaledX = clampedX * factor + remainderX
        let scaledY = clampedY * factor + remainderY
        let wholeX = scaledX.rounded(.towardZero)
        let wholeY = scaledY.rounded(.towardZero)
        remainderX = scaledX - wholeX
        remainderY = scaledY - wholeY
        let outX = Int32(min(10000.0, max(-10000.0, wholeX)))
        let outY = Int32(min(10000.0, max(-10000.0, wholeY)))
        return (outX, outY)
    }
}

struct TopEdgePush {
    let threshold: Int32
    let maxStep: Int32
    let window: TimeInterval
    private var push: Int32 = 0
    private var lastPush: TimeInterval = -.infinity

    init(threshold: Int32 = -75, maxStep: Int32 = -45, window: TimeInterval = 0.25) {
        self.threshold = threshold
        self.maxStep = maxStep
        self.window = window
    }

    mutating func reset() {
        push = 0
        lastPush = -.infinity
    }

    mutating func advance(dx: Int32, dy: Int32, atTopEdge: Bool, now: TimeInterval) -> Bool {
        guard atTopEdge, dy < 0, abs(dx) <= -dy else {
            reset()
            return false
        }
        if now - lastPush > window {
            push = 0
        }
        lastPush = now
        push += max(maxStep, dy)
        guard push <= threshold else { return false }
        reset()
        return true
    }
}

enum ThreeFingerSwipeAction: String, CaseIterable {
    case desktops
    case switchApps
    case browserHistory
    case off
}

enum SwipeDirection: Equatable {
    case left
    case right
    case up
    case down
}

struct ThreeFingerSwipeDetector {
    private var anchor: (x: Double, y: Double)?
    private var triggeredInGesture = false
    private var lastTrigger: TimeInterval = -.infinity
    private var lastUpdate: TimeInterval = -.infinity

    mutating func reset() {
        anchor = nil
        triggeredInGesture = false
    }

    mutating func update(touchCount: Int, x: Double, y: Double, now: TimeInterval) -> SwipeDirection? {
        if now - lastUpdate > 0.25 {
            reset()
        }
        lastUpdate = now
        guard touchCount == 3 else {
            reset()
            return nil
        }
        guard let anchor else {
            self.anchor = (x, y)
            return nil
        }
        guard !triggeredInGesture, now - lastTrigger >= 0.35 else { return nil }
        let dx = x - anchor.x
        let dy = y - anchor.y
        if abs(dx) >= 0.11, abs(dx) > abs(dy) * 1.35 {
            triggeredInGesture = true
            lastTrigger = now
            return dx < 0 ? .left : .right
        }
        if dy >= 0.11, dy > abs(dx) * 1.35 {
            triggeredInGesture = true
            lastTrigger = now
            return .up
        }
        if dy <= -0.11, -dy > abs(dx) * 1.35 {
            triggeredInGesture = true
            lastTrigger = now
            return .down
        }
        return nil
    }
}

func swipeShortcutAction(direction: SwipeDirection, horizontalAction: ThreeFingerSwipeAction, upEnabled: Bool, downEnabled: Bool) -> String? {
    switch direction {
    case .up:
        return upEnabled ? "taskView" : nil
    case .down:
        return downEnabled ? "showDesktop" : nil
    case .left, .right:
        switch horizontalAction {
        case .off:
            return nil
        case .desktops:
            return direction == .left ? "desktopNext" : "desktopPrev"
        case .switchApps:
            return direction == .left ? "switchAppNext" : "switchAppPrev"
        case .browserHistory:
            return direction == .left ? "browserForward" : "browserBack"
        }
    }
}

func swipeKeySequence(direction: SwipeDirection, horizontalAction: ThreeFingerSwipeAction, upEnabled: Bool, downEnabled: Bool = true) -> [Input] {
    let combo: [UInt16]
    switch direction {
    case .up:
        guard upEnabled else { return [] }
        combo = [0x15b, 0x0f] // Win + Tab
    case .down:
        guard downEnabled else { return [] }
        combo = [0x15b, 0x20] // Win + D
    case .left, .right:
        switch horizontalAction {
        case .off:
            return []
        case .desktops:
            combo = [0x1d, 0x15b, direction == .left ? 0x14d : 0x14b] // Ctrl + Win + Right / Left
        case .switchApps:
            combo = direction == .left ? [0x38, 0x0f] : [0x38, 0x2a, 0x0f] // Alt+Tab / Alt+Shift+Tab
        case .browserHistory:
            combo = [0x38, direction == .left ? 0x14d : 0x14b] // Alt + Right / Left
        }
    }
    return combo.map { Input(kind: "key", code: $0, down: true) } +
           combo.reversed().map { Input(kind: "key", code: $0, down: false) }
}

struct PinchZoomDetector {
    let step: Double
    let activateDelta: Double
    let cooldown: TimeInterval
    let resetWindow: TimeInterval
    private var anchorDistance: Double?
    private var anchorMid: (x: Double, y: Double)?
    private var lastTriggerDistance = 0.0
    private var lastTrigger: TimeInterval = -.infinity
    private var lastUpdate: TimeInterval = -.infinity
    private var suppressScrollUntil: TimeInterval = -.infinity
    private(set) var active = false

    init(step: Double = 0.075, activateDelta: Double = 0.045, cooldown: TimeInterval = 0.11, resetWindow: TimeInterval = 0.25) {
        self.step = step
        self.activateDelta = activateDelta
        self.cooldown = cooldown
        self.resetWindow = resetWindow
    }

    func shouldSuppressScroll(now: TimeInterval) -> Bool {
        active || now < suppressScrollUntil
    }

    mutating func reset() {
        anchorDistance = nil
        anchorMid = nil
        lastTriggerDistance = 0
        lastUpdate = -.infinity
        active = false
    }

    mutating func update(touches: [(x: Double, y: Double)], now: TimeInterval) -> String? {
        if now - lastUpdate > resetWindow {
            reset()
        }
        guard touches.count == 2 else {
            if active {
                suppressScrollUntil = now + 0.15
            }
            reset()
            return nil
        }
        lastUpdate = now
        let p0 = touches[0]
        let p1 = touches[1]
        let dx = p0.x - p1.x
        let dy = p0.y - p1.y
        let dist = (dx * dx + dy * dy).squareRoot()
        let mid = (x: (p0.x + p1.x) * 0.5, y: (p0.y + p1.y) * 0.5)

        guard let baseDist = anchorDistance, let baseMid = anchorMid else {
            anchorDistance = dist
            anchorMid = mid
            lastTriggerDistance = dist
            return nil
        }

        let deltaFromAnchor = dist - baseDist
        let midShift = hypot(mid.x - baseMid.x, mid.y - baseMid.y)

        if !active {
            // Parallel 2-finger scrolling shifts both fingers together without changing spread.
            if midShift >= 0.06 && abs(deltaFromAnchor) < activateDelta * 0.6 {
                anchorDistance = dist
                anchorMid = mid
                lastTriggerDistance = dist
                return nil
            }
            guard abs(deltaFromAnchor) >= activateDelta, abs(deltaFromAnchor) > midShift * 0.85 else {
                return nil
            }
            active = true
            suppressScrollUntil = now + 0.20
            lastTriggerDistance = baseDist
        } else {
            suppressScrollUntil = now + 0.20
        }

        let delta = dist - lastTriggerDistance
        guard now - lastTrigger >= cooldown else { return nil }
        if delta >= step {
            lastTriggerDistance = dist
            lastTrigger = now
            return "zoomIn"
        }
        if delta <= -step {
            lastTriggerDistance = dist
            lastTrigger = now
            return "zoomOut"
        }
        return nil
    }
}

struct RemoteKeyboard {
    let commandIsControl: Bool
    let commandSpaceSwitchesLanguage: Bool
    let macShortcuts: Bool
    private var held: [Int64: UInt16] = [:]
    private var physicalCommand: Set<Int64> = []
    private var physicalOption: Set<Int64> = []
    private var physicalShift: Set<Int64> = []
    private var physicalControl: Set<Int64> = []
    private var suppressedCommand: [Int64: UInt16] = [:]
    private var suppressedOption: [Int64: UInt16] = [:]
    private var suppressedShiftControl: [Int64: UInt16] = [:]
    private var optionWordCtrlActive = false
    private var remappedKeys: [Int64: UInt16] = [:]
    private var suppressedKeyUps: Set<Int64> = []
    private var languageSwitchActive = false

    private static let commandKeys: [Int64] = [55, 54]
    private static let optionKeys: [Int64] = [58, 61]
    private static let shiftKeys: Set<Int64> = [56, 60]
    private static let controlKeys: Set<Int64> = [59, 62]
    private static let otherModifiers: Set<Int64> = [56, 60, 58, 61, 59, 62]

    init(commandIsControl: Bool, commandSpaceSwitchesLanguage: Bool = true, macShortcuts: Bool = true) {
        self.commandIsControl = commandIsControl
        self.commandSpaceSwitchesLanguage = commandSpaceSwitchesLanguage
        self.macShortcuts = macShortcuts
    }

    private var otherModifierHeld: Bool {
        held.keys.contains { Self.otherModifiers.contains($0) }
    }

    mutating func releaseAllModifiers() -> [Input] {
        var out: [Input] = []
        if optionWordCtrlActive {
            optionWordCtrlActive = false
            if !held.values.contains(0x1d) {
                out.append(Input(kind: "key", code: 0x1d, down: false))
            }
        }
        let modifierOrder: [Int64] = [55, 54, 58, 61, 56, 60, 59, 62]
        for modKey in modifierOrder {
            guard let modCode = held.removeValue(forKey: modKey) else { continue }
            if Self.commandKeys.contains(modKey) {
                suppressedCommand[modKey] = modCode
            } else if Self.optionKeys.contains(modKey) {
                suppressedOption[modKey] = modCode
            } else {
                suppressedShiftControl[modKey] = modCode
            }
            if !held.values.contains(modCode) {
                out.append(Input(kind: "key", code: modCode, down: false))
            }
        }
        return out
    }

    private mutating func releaseSuppressedCommand() -> [Input] {
        var ups: [Input] = []
        for cmdKey in Self.commandKeys {
            if let cmdCode = held.removeValue(forKey: cmdKey) {
                suppressedCommand[cmdKey] = cmdCode
                if !held.values.contains(cmdCode) {
                    ups.append(Input(kind: "key", code: cmdCode, down: false))
                }
            }
        }
        return ups
    }

    private mutating func deactivateOptionWordCtrl() -> [Input] {
        var seq: [Input] = []
        if optionWordCtrlActive {
            optionWordCtrlActive = false
            if !held.values.contains(0x1d) {
                seq.append(Input(kind: "key", code: 0x1d, down: false))
            }
        }
        for optKey in Self.optionKeys {
            if let optCode = suppressedOption.removeValue(forKey: optKey) {
                let alreadyHeld = held.values.contains(optCode)
                held[optKey] = optCode
                if !alreadyHeld {
                    seq.append(Input(kind: "key", code: optCode, down: true))
                }
            }
        }
        return seq
    }

    mutating func events(for key: Int64, down: Bool, flagsChanged: Bool) -> [Input] {
        guard var code = scanCodes[key] else { return [] }
        if commandIsControl {
            if key == 55 { code = 0x1d }
            if key == 54 { code = 0x11d }
        }
        if key == 57 && flagsChanged {
            return [Input(kind: "key", code: code, down: true), Input(kind: "key", code: code)]
        }
        if flagsChanged {
            if key == 55 || key == 54 {
                if down {
                    physicalCommand.insert(key)
                } else {
                    physicalCommand.remove(key)
                    if suppressedCommand.removeValue(forKey: key) != nil { return [] }
                }
            } else if key == 58 || key == 61 {
                if down {
                    physicalOption.insert(key)
                } else {
                    physicalOption.remove(key)
                    if suppressedOption.removeValue(forKey: key) != nil {
                        if optionWordCtrlActive && physicalOption.isEmpty {
                            optionWordCtrlActive = false
                            if !held.values.contains(0x1d) {
                                return [Input(kind: "key", code: 0x1d, down: false)]
                            }
                        }
                        return []
                    }
                }
            } else if Self.shiftKeys.contains(key) {
                if down {
                    physicalShift.insert(key)
                } else {
                    physicalShift.remove(key)
                    if suppressedShiftControl.removeValue(forKey: key) != nil { return [] }
                }
            } else if Self.controlKeys.contains(key) {
                if down {
                    physicalControl.insert(key)
                } else {
                    physicalControl.remove(key)
                    if suppressedShiftControl.removeValue(forKey: key) != nil { return [] }
                }
            }
        }

        if !flagsChanged && !down {
            if let mappedCode = remappedKeys.removeValue(forKey: key) {
                guard held.removeValue(forKey: key) != nil, !held.values.contains(mappedCode) else { return [] }
                return [Input(kind: "key", code: mappedCode, down: false)]
            }
            if suppressedKeyUps.remove(key) != nil {
                return []
            }
        }

        if key == 49 && !flagsChanged {
            if down {
                if languageSwitchActive { return [] }
                if commandSpaceSwitchesLanguage, !physicalCommand.isEmpty, !otherModifierHeld, held[49] == nil {
                    languageSwitchActive = true
                    let releasedCmdUps = releaseSuppressedCommand()
                    var sequence: [Input] = []
                    if commandIsControl {
                        sequence.append(contentsOf: releasedCmdUps)
                        sequence.append(Input(kind: "key", code: 0x2a, down: true))
                        sequence.append(Input(kind: "key", code: 0x38, down: true))
                    } else {
                        // Hold Shift before releasing Win so Windows does not open the Start menu.
                        sequence.append(Input(kind: "key", code: 0x2a, down: true))
                        sequence.append(contentsOf: releasedCmdUps)
                        sequence.append(Input(kind: "key", code: 0x38, down: true))
                    }
                    return sequence
                }
            } else if languageSwitchActive {
                languageSwitchActive = false
                return [Input(kind: "key", code: 0x38, down: false), Input(kind: "key", code: 0x2a, down: false)]
            }
        }

        if macShortcuts && down && !flagsChanged {
            if commandIsControl && !physicalCommand.isEmpty && physicalOption.isEmpty && physicalControl.isEmpty {
                if key == 123 || key == 124 {
                    let mappedCode: UInt16 = (key == 123) ? 0x147 : 0x14f // Home / End
                    let ups = releaseSuppressedCommand()
                    remappedKeys[key] = mappedCode
                    held[key] = mappedCode
                    return ups + [Input(kind: "key", code: mappedCode, down: true)]
                }
                if key == 51 && physicalShift.isEmpty {
                    if suppressedKeyUps.contains(51) { return [] }
                    suppressedKeyUps.insert(51)
                    let ups = releaseSuppressedCommand()
                    return ups + [
                        Input(kind: "key", code: 0x2a, down: true),
                        Input(kind: "key", code: 0x147, down: true),
                        Input(kind: "key", code: 0x147, down: false),
                        Input(kind: "key", code: 0x2a, down: false),
                        Input(kind: "key", code: 0x0e, down: true),
                        Input(kind: "key", code: 0x0e, down: false),
                    ]
                }
            }
            if !physicalOption.isEmpty && physicalCommand.isEmpty && physicalControl.isEmpty &&
                (key == 123 || key == 124 || (key == 51 && physicalShift.isEmpty)) {
                var sequence: [Input] = []
                if !optionWordCtrlActive {
                    optionWordCtrlActive = true
                    if !held.values.contains(0x1d) {
                        sequence.append(Input(kind: "key", code: 0x1d, down: true))
                    }
                    for optKey in Self.optionKeys {
                        if let optCode = held.removeValue(forKey: optKey) {
                            suppressedOption[optKey] = optCode
                            if !held.values.contains(optCode) {
                                sequence.append(Input(kind: "key", code: optCode, down: false))
                            }
                        }
                    }
                }
                held[key] = code
                sequence.append(Input(kind: "key", code: code, down: true))
                return sequence
            }
        }

        var prefix: [Input] = []
        if down && !flagsChanged && optionWordCtrlActive {
            prefix.append(contentsOf: deactivateOptionWordCtrl())
        }
        if down, !languageSwitchActive, !suppressedCommand.isEmpty, !(flagsChanged && (key == 55 || key == 54)) {
            for cmdKey in Self.commandKeys {
                if let cmdCode = suppressedCommand.removeValue(forKey: cmdKey) {
                    let alreadyHeld = held.values.contains(cmdCode)
                    held[cmdKey] = cmdCode
                    if !alreadyHeld {
                        prefix.append(Input(kind: "key", code: cmdCode, down: true))
                    }
                }
            }
        }
        if down, !suppressedShiftControl.isEmpty, !flagsChanged {
            for modKey in [56, 60, 59, 62] as [Int64] {
                if let modCode = suppressedShiftControl.removeValue(forKey: modKey) {
                    let alreadyHeld = held.values.contains(modCode)
                    held[modKey] = modCode
                    if !alreadyHeld {
                        prefix.append(Input(kind: "key", code: modCode, down: true))
                    }
                }
            }
        }
        if down {
            let alreadyHeld = held.values.contains(code)
            held[key] = code
            // Only ordinary key presses repeat. Multiple physical modifiers can share one scan code.
            if alreadyHeld && flagsChanged { return prefix }
        } else {
            guard held.removeValue(forKey: key) != nil, !held.values.contains(code) else { return prefix }
        }
        return prefix + [Input(kind: "key", code: code, down: down)]
    }
}
