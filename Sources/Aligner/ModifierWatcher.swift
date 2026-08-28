import AppKit

/// Polls the hardware modifier state ~60×/s. This needs no Accessibility or
/// Input Monitoring permission (unlike global key event monitors) and is cheap.
final class ModifierWatcher {
    var required: CGEventFlags {
        didSet { poll() }
    }
    var onChange: ((Bool) -> Void)?
    /// Fired when the modifier is tapped twice quickly with no other input.
    var onDoubleTap: (() -> Void)?
    private(set) var isHeld = false

    private var timer: Timer?
    private var doubleTap = DoubleTapDetector()
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
        let held = flags == required
        guard held != isHeld else { return }
        isHeld = held
        Debug.log("modifier held=\(held)")
        onChange?(held)

        let tapped = doubleTap.update(
            held: held,
            now: ProcessInfo.processInfo.systemUptime,
            otherInputSince: Self.otherInputOccurred(within:)
        )
        if tapped {
            Debug.log("double-tap")
            onDoubleTap?()
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
