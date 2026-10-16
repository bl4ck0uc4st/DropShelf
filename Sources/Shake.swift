import Cocoa

enum Settings {
    private static let d = UserDefaults.standard

    /// 1 = low, 2 = normal, 3 = high
    static var sensitivity: Int {
        get {
            let v = d.integer(forKey: "sensitivity")
            return (1...3).contains(v) ? v : 2
        }
        set { d.set(newValue, forKey: "sensitivity") }
    }

    /// Keep files on the shelf after they were dragged out (default: remove them).
    static var keepAfterDragOut: Bool {
        get { d.bool(forKey: "keepAfterDragOut") }
        set { d.set(newValue, forKey: "keepAfterDragOut") }
    }

    /// 0 = follow system, 1 = light, 2 = dark
    static var appearance: Int {
        get {
            let v = d.integer(forKey: "appearance")
            return (0...2).contains(v) ? v : 0
        }
        set { d.set(newValue, forKey: "appearance") }
    }

    static var nsAppearance: NSAppearance? {
        switch appearance {
        case 1: return NSAppearance(named: .aqua)
        case 2: return NSAppearance(named: .darkAqua)
        default: return nil
        }
    }
}

/// Detects a quick left-right-left "shake" of the pointer while the mouse button is held.
final class ShakeDetector {
    var onShake: (() -> Void)?

    private var lastX: CGFloat?
    private var direction = 0            // +1 right, -1 left, 0 unknown
    private var segmentTravel: CGFloat = 0
    private var reversalTimes: [TimeInterval] = []
    private var fired = false

    private let window: TimeInterval = 0.8   // reversals must happen within this many seconds
    private let minimumSwing: CGFloat = 12   // a swing shorter than this is jitter, not a shake

    private var requiredReversals: Int {
        switch Settings.sensitivity {
        case 1: return 6
        case 3: return 3
        default: return 4
        }
    }

    func beginDrag() {
        lastX = nil
        direction = 0
        segmentTravel = 0
        reversalTimes.removeAll()
        fired = false
    }

    func feed(x: CGFloat, at time: TimeInterval) {
        guard !fired else { return }
        defer { lastX = x }
        guard let previous = lastX else { return }

        let dx = x - previous
        if abs(dx) < 2 { return }
        let dir = dx > 0 ? 1 : -1

        if direction != 0 && dir != direction {
            if segmentTravel >= minimumSwing { reversalTimes.append(time) }
            segmentTravel = 0
        }
        direction = dir
        segmentTravel += abs(dx)

        reversalTimes.removeAll { time - $0 > window }
        if reversalTimes.count >= requiredReversals {
            fired = true
            onShake?()
        }
    }
}
