import AppKit

/// One borderless, always-on-top, non-activating panel per screen. It is
/// click-through until `setCapturing(true)`, at which point it swallows mouse
/// events so the user can draw without the app underneath reacting.
final class OverlayWindow: NSPanel {
    let overlayView: OverlayView
    let displayID: CGDirectDisplayID

    private var wantsCapture = false
    private(set) var isCapturing = false

    init(screen: NSScreen) {
        overlayView = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        displayID = number.map { CGDirectDisplayID($0.uint32Value) } ?? CGMainDisplayID()
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        // Fully transparent. Verified with the ALIGNER_DEBUG self-test that the
        // window server still routes clicks here while capturing, so there's no
        // need for the old "0.01 alpha background" trick — which would shift
        // every pixel on screen by 1/255 and show up in Digital Color Meter.
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        worksWhenModal = true
        acceptsMouseMovedEvents = true

        contentView = overlayView
        setFrame(screen.frame, display: false)

        overlayView.onDragEnded = { [weak self] in
            self?.applyCapture()
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setCapturing(_ capture: Bool) {
        wantsCapture = capture
        applyCapture()
    }

    private func applyCapture() {
        // Never drop capture in the middle of a drag; the remaining drag and
        // mouse-up events need to keep arriving at this window.
        let effective = wantsCapture || overlayView.isDragging
        guard effective != isCapturing else { return }
        isCapturing = effective
        ignoresMouseEvents = !effective
        overlayView.isCapturing = effective
        Debug.log("window \(windowNumber) capturing=\(effective)")
    }
}
