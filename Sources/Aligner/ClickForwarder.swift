import AppKit
import ApplicationServices

/// Re-posts mouse events that turned out to be meant for the app underneath:
/// a ⇧-press that ended without a drag is a click, not a guide. Needs
/// Accessibility access (the only feature that does); without it, events are
/// simply swallowed as before.
enum ClickForwarder {
    /// Stamped on everything we post so the overlay never re-captures it.
    private static let tag: Int64 = 0x414C_4E52  // 'ALNR'

    static var isAuthorized: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestAuthorization(prompting: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompting] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func isForwarded(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == tag
    }

    /// Posts a click pair at `screenPoint` (AppKit coordinates) while `window`
    /// briefly lets events through.
    static func forwardClick(
        at screenPoint: NSPoint,
        right: Bool = false,
        flags: CGEventFlags,
        clickCount: Int,
        through window: OverlayWindow
    ) {
        guard isAuthorized else { return }
        let location = cgLocation(of: screenPoint)
        let button: CGMouseButton = right ? .right : .left
        guard
            let down = CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseDown : .leftMouseDown, mouseCursorPosition: location, mouseButton: button),
            let up = CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseUp : .leftMouseUp, mouseCursorPosition: location, mouseButton: button)
        else { return }
        for event in [down, up] {
            event.flags = flags
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
            event.setIntegerValueField(.eventSourceUserData, value: tag)
        }
        Debug.log("forward \(right ? "right-" : "")click at \(screenPoint) cc=\(clickCount)")
        post([down, up], through: window)
    }

    static func forwardScroll(_ event: NSEvent, through window: OverlayWindow) {
        guard isAuthorized, let scroll = event.cgEvent?.copy() else { return }
        scroll.setIntegerValueField(.eventSourceUserData, value: tag)
        post([scroll], through: window)
    }

    /// The window goes click-through while the posted events travel through
    /// the window server, so they reach the app underneath instead of us.
    private static func post(_ events: [CGEvent], through window: OverlayWindow) {
        window.beginForwardingHold()
        for event in events { event.post(tap: .cghidEventTap) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            window.endForwardingHold()
        }
    }

    private static func cgLocation(of screenPoint: NSPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y)
    }
}
