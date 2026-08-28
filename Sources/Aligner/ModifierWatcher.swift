import AppKit

/// Polls the hardware modifier state ~60×/s. This needs no Accessibility or
/// Input Monitoring permission (unlike global key event monitors) and is cheap.
final class ModifierWatcher {
    var required: CGEventFlags {
        didSet { poll() }
    }
    var onChange: ((Bool) -> Void)?
    /// Fired whenever the relevant modifier flags change, whether or not the
    /// draw modifier is involved — used to toggle snapping mid-drag.
    var onFlagsChange: ((CGEventFlags) -> Void)?
    /// Fired after each clean tap of the modifier with the length of the
    /// current tap sequence (1 = single, 2 = double, 3 = triple, …).
    var onTap: ((Int) -> Void)?
    private(set) var isHeld = false
    private(set) var flags: CGEventFlags = []

    private var timer: Timer?
    private var taps = TapDetector()
    private static let relevant: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
    private static let otherInputTypes: [CGEventType] = [
        .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
    ]

    init(required: CGEventFlags) {
        self.required = required
    }

    func start() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer.tolerance = 0.004
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        // Exact match on the four main modifiers, so ⌘⇧-shortcuts don't
        // accidentally put the overlay into drawing mode.
        let flags = CGEventSource.flagsState(.combinedSessionState).intersection(Self.relevant)
        if flags != self.flags {
            self.flags = flags
            onFlagsChange?(flags)
        }
        let held = flags == required
        guard held != isHeld else { return }
        isHeld = held
        Debug.log("modifier held=\(held)")
        onChange?(held)

        let count = taps.update(
            held: held,
            now: ProcessInfo.processInfo.systemUptime,
            otherInputSince: Self.otherInputOccurred(within:)
        )
        if count > 0 {
            Debug.log("tap x\(count)")
            onTap?(count)
        }
    }

    /// Whether any key press, click or scroll happened in the last `interval`
    /// seconds. The margin absorbs the 60 Hz polling granularity.
    private static func otherInputOccurred(within interval: TimeInterval) -> Bool {
        otherInputTypes.contains { type in
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type) < interval + 0.05
        }
    }
}
