import AppKit

/// Full-screen transparent view that draws the committed lines plus whatever
/// is being dragged. Mouse events only arrive while the owning window is in
/// capture mode (see `OverlayWindow`).
///
/// Dragging on empty space draws a new line. Hovering a line shows Preview-style
/// endpoint handles: dragging the body moves the line, dragging a handle moves
/// that end while the other stays put (snapped to 45° like drawing), and
/// double-clicking extends the line across the screen.
final class OverlayView: NSView {
    /// Called after a drag finishes so the window can release capture if the
    /// modifier was let go mid-drag.
    var onDragEnded: (() -> Void)?

    enum End { case start, end }

    private enum Target: Equatable {
        case body(Int)
        case endpoint(Int, End)

        var index: Int {
            switch self {
            case .body(let index), .endpoint(let index, _): index
            }
        }
    }

    private enum Drag {
        case draw(start: NSPoint, current: NSPoint)
        /// `original` is the line in view coordinates as it was when the drag began.
        case move(index: Int, original: Line, anchor: NSPoint, current: NSPoint)
        case resize(index: Int, original: Line, end: End, current: NSPoint)

        var editingIndex: Int? {
            switch self {
            case .draw: nil
            case .move(let index, _, _, _), .resize(let index, _, _, _): index
            }
        }

        func with(current: NSPoint) -> Drag {
            switch self {
            case .draw(let start, _): .draw(start: start, current: current)
            case .move(let index, let original, let anchor, _): .move(index: index, original: original, anchor: anchor, current: current)
            case .resize(let index, let original, let end, _): .resize(index: index, original: original, end: end, current: current)
            }
        }
    }

    private var drag: Drag?
    private var hovered: Target?
    private var storeObserver: NSObjectProtocol?

    private static let haloWidth: CGFloat = 6
    private static let handleRadius: CGFloat = 4.5
    private static let activeHandleRadius: CGFloat = 6
    private static let handleHitRadius: CGFloat = 9

    var isDragging: Bool { drag != nil }

    var isCapturing = false {
        didSet {
            guard isCapturing != oldValue else { return }
            if !isCapturing { setHovered(nil) }
            updateCursor()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        storeObserver = NotificationCenter.default.addObserver(
            forName: LineStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Indices are no longer trustworthy; abandon an in-flight edit.
            if drag?.editingIndex != nil { drag = nil }
            hovered = nil
            needsDisplay = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let storeObserver {
            NotificationCenter.default.removeObserver(storeObserver)
        }
    }

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Cursor & hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        if isCapturing {
            updateCursor()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard isCapturing, drag == nil else { return }
        setHovered(target(near: convert(event.locationInWindow, from: nil)))
    }

    private func updateCursor() {
        guard isCapturing else {
            NSCursor.arrow.set()
            return
        }
        switch drag {
        case .move:
            NSCursor.closedHand.set()
        case .draw, .resize:
            NSCursor.crosshair.set()
        case nil:
            if case .body = hovered {
                NSCursor.openHand.set()
            } else {
                NSCursor.crosshair.set()
            }
        }
    }

    private func setHovered(_ target: Target?) {
        guard target != hovered else { return }
        invalidate(localLine(at: hovered?.index))
        hovered = target
        invalidate(localLine(at: hovered?.index))
        updateCursor()
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let target = target(near: point)

        if event.clickCount == 2, let target, let line = localLine(at: target.index), let window {
            let (start, end) = Geometry.extend(line.start, line.end, to: bounds)
            var extended = line
            extended.start = start
            extended.end = end
            Debug.log("extend \(target.index)")
            drag = nil
            LineStore.shared.replace(at: target.index, with: screenLine(extended, window: window))
            return
        }

        switch target {
        case .endpoint(let index, let end):
            guard let line = localLine(at: index) else { return }
            drag = .resize(index: index, original: line, end: end, current: point)
            Debug.log("resize start \(index) \(end)")
        case .body(let index):
            guard let line = localLine(at: index) else { return }
            drag = .move(index: index, original: line, anchor: point, current: point)
            Debug.log("move start \(index)")
        case nil:
            drag = .draw(start: point, current: point)
            Debug.log("draw start \(point)")
        }
        hovered = target
        invalidate(previewLine)
        updateCursor()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let previous = previewLine
        self.drag = drag.with(current: convert(event.locationInWindow, from: nil))
        invalidate(previous)
        invalidate(previewLine)
    }

    override func mouseUp(with event: NSEvent) {
        defer { onDragEnded?() }
        guard let drag, let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        self.drag = drag.with(current: point)
        let result = previewLine
        self.drag = nil
        invalidate(result)

        if let result, Self.length(of: result) >= 2 {
            switch drag {
            case .draw:
                Debug.log("commit \(result)")
                LineStore.shared.add(screenLine(result, window: window))
            case .move(let index, let original, _, _), .resize(let index, let original, _, _):
                if !Self.sameEndpoints(result, original) {
                    Debug.log("edit \(index) -> \(result.start) \(result.end)")
                    LineStore.shared.replace(at: index, with: screenLine(result, window: window))
                }
            }
        }
        setHovered(target(near: point))
        updateCursor()
    }

    // MARK: - Geometry

    /// The line being dragged, in view coordinates.
    private var previewLine: Line? {
        switch drag {
        case .draw(let start, let current):
            Line(start: start, end: Snap.snapped(from: start, to: current), style: LineSettings.shared.style)
        case .move(_, let original, let anchor, let current):
            original.translated(by: NSPoint(x: current.x - anchor.x, y: current.y - anchor.y))
        case .resize(_, let original, let end, let current):
            resized(original, end: end, to: current)
        case nil:
            nil
        }
    }

    /// Moves one end of `line` to `point` (snapped relative to the other end,
    /// which stays fixed).
    private func resized(_ line: Line, end: End, to point: NSPoint) -> Line {
        var result = line
        switch end {
        case .start: result.start = Snap.snapped(from: line.end, to: point)
        case .end: result.end = Snap.snapped(from: line.start, to: point)
        }
        return result
    }

    private static func length(of line: Line) -> CGFloat {
        hypot(line.end.x - line.start.x, line.end.y - line.start.y)
    }

    private static func sameEndpoints(_ a: Line, _ b: Line) -> Bool {
        a.start == b.start && a.end == b.end
    }

    private func localLine(_ line: Line, window: NSWindow) -> Line {
        var local = line
        local.start = convert(window.convertPoint(fromScreen: line.start), from: nil)
        local.end = convert(window.convertPoint(fromScreen: line.end), from: nil)
        return local
    }

    private func localLine(at index: Int?) -> Line? {
        guard let index, let window, LineStore.shared.lines.indices.contains(index) else { return nil }
        return localLine(LineStore.shared.lines[index], window: window)
    }

    private func screenLine(_ line: Line, window: NSWindow) -> Line {
        var screen = line
        screen.start = window.convertPoint(toScreen: convert(line.start, to: nil))
        screen.end = window.convertPoint(toScreen: convert(line.end, to: nil))
        return screen
    }

    /// What's under `point`: an endpoint handle takes priority over a line
    /// body; among several candidates the closest wins.
    private func target(near point: NSPoint) -> Target? {
        guard let window else { return nil }
        var bestEndpoint: (target: Target, distance: CGFloat)?
        var bestBody: (target: Target, distance: CGFloat)?

        for (index, line) in LineStore.shared.lines.enumerated() {
            let local = localLine(line, window: window)
            for (end, endpoint) in [(End.start, local.start), (End.end, local.end)] {
                let distance = hypot(point.x - endpoint.x, point.y - endpoint.y)
                if distance <= Self.handleHitRadius, distance < (bestEndpoint?.distance ?? .infinity) {
                    bestEndpoint = (.endpoint(index, end), distance)
                }
            }
            let tolerance = max(6, line.style.width / 2 + 4)
            let distance = Geometry.distance(from: point, toSegment: local.start, local.end)
            if distance <= tolerance, distance < (bestBody?.distance ?? .infinity) {
                bestBody = (.body(index), distance)
            }
        }
        return bestEndpoint?.target ?? bestBody?.target
    }

    private func invalidate(_ line: Line?) {
        guard let line else { return }
        let rect = NSRect(
            x: min(line.start.x, line.end.x),
            y: min(line.start.y, line.end.y),
            width: abs(line.end.x - line.start.x),
            height: abs(line.end.y - line.start.y)
        )
        let margin = line.style.width + Self.haloWidth + Self.activeHandleRadius + 4
        setNeedsDisplay(rect.insetBy(dx: -margin, dy: -margin))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let window else { return }
        let scale = window.backingScaleFactor
        let editingIndex = drag?.editingIndex
        let hoveredIndex = hovered?.index

        for (index, line) in LineStore.shared.lines.enumerated() where index != editingIndex {
            let local = localLine(line, window: window)
            if index == hoveredIndex { strokeHalo(local, in: context, scale: scale) }
            stroke(local, in: context, scale: scale)
        }

        if let preview = previewLine {
            if editingIndex != nil { strokeHalo(preview, in: context, scale: scale) }
            stroke(preview, in: context, scale: scale)
            if case .resize(_, _, let end, _) = drag {
                drawHandles(for: preview, active: end, in: context)
            } else if editingIndex != nil {
                drawHandles(for: preview, active: nil, in: context)
            }
        } else if let hoveredIndex, let local = localLine(at: hoveredIndex) {
            var active: End?
            if case .endpoint(_, let end) = hovered { active = end }
            drawHandles(for: local, active: active, in: context)
        }
    }

    private func stroke(_ line: Line, in context: CGContext, scale: CGFloat) {
        let width = max(line.style.width, 1 / scale)
        var a = line.start
        var b = line.end
        // Horizontal and vertical lines are what you use to check alignment,
        // so make sure they land exactly on device pixels instead of blurring
        // across two.
        if abs(a.y - b.y) < 0.001 {
            let y = crisp(a.y, width: width, scale: scale)
            a = NSPoint(x: pixel(a.x, scale: scale), y: y)
            b = NSPoint(x: pixel(b.x, scale: scale), y: y)
        } else if abs(a.x - b.x) < 0.001 {
            let x = crisp(a.x, width: width, scale: scale)
            a = NSPoint(x: x, y: pixel(a.y, scale: scale))
            b = NSPoint(x: x, y: pixel(b.y, scale: scale))
        }

        context.setStrokeColor(line.style.color.cgColor)
        context.setLineWidth(width)
        switch line.style.dash {
        case .solid:
            context.setLineDash(phase: 0, lengths: [])
            context.setLineCap(.butt)
        case .dashed:
            context.setLineDash(phase: 0, lengths: [6 * width, 4 * width])
            context.setLineCap(.butt)
        case .dotted:
            context.setLineDash(phase: 0, lengths: [0, 2.5 * width])
            context.setLineCap(.round)
        }
        context.move(to: a)
        context.addLine(to: b)
        context.strokePath()
    }

    private func strokeHalo(_ line: Line, in context: CGContext, scale: CGFloat) {
        context.setLineDash(phase: 0, lengths: [])
        context.setLineCap(.round)
        context.setLineWidth(max(line.style.width, 1 / scale) + Self.haloWidth)
        context.setStrokeColor(line.style.color.withAlphaComponent(0.3).cgColor)
        context.move(to: line.start)
        context.addLine(to: line.end)
        context.strokePath()
    }

    /// Preview-style endpoint handles: accent-coloured discs with a white ring.
    /// The `active` one (hovered or being dragged) is drawn larger.
    private func drawHandles(for line: Line, active: End?, in context: CGContext) {
        context.setLineDash(phase: 0, lengths: [])
        for (end, point) in [(End.start, line.start), (End.end, line.end)] {
            let radius = end == active ? Self.activeHandleRadius : Self.handleRadius
            let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            context.setFillColor(NSColor.controlAccentColor.cgColor)
            context.fillEllipse(in: rect)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: rect)
        }
    }

    /// Aligns a coordinate so a `width`-wide stroke centred on it covers whole
    /// device pixels.
    private func crisp(_ value: CGFloat, width: CGFloat, scale: CGFloat) -> CGFloat {
        let half = width * scale / 2
        return ((value * scale - half).rounded() + half) / scale
    }

    private func pixel(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }
}
