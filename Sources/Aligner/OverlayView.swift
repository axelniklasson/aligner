import AppKit

/// Full-screen transparent view that draws the committed lines plus whatever
/// is being dragged. Mouse events only arrive while the owning window is in
/// capture mode (see `OverlayWindow`). Dragging on empty space draws a new
/// line; dragging on an existing line moves it.
final class OverlayView: NSView {
    /// Called after a drag finishes so the window can release capture if the
    /// modifier was let go mid-drag.
    var onDragEnded: (() -> Void)?

    private enum Drag {
        case draw(start: NSPoint, current: NSPoint)
        /// `original` is the line in view coordinates as it was when the drag began.
        case move(index: Int, original: Line, anchor: NSPoint, current: NSPoint)
    }

    private var drag: Drag?
    private var hoveredIndex: Int?
    private var storeObserver: NSObjectProtocol?

    private static let haloWidth: CGFloat = 6

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
            // Indices are no longer trustworthy; abandon an in-flight move.
            if case .move = drag { drag = nil }
            hoveredIndex = nil
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
        setHovered(lineIndex(near: convert(event.locationInWindow, from: nil)))
    }

    private func updateCursor() {
        guard isCapturing else {
            NSCursor.arrow.set()
            return
        }
        if case .move = drag {
            NSCursor.closedHand.set()
        } else if hoveredIndex != nil {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    private func setHovered(_ index: Int?) {
        guard index != hoveredIndex else { return }
        invalidate(localLine(at: hoveredIndex))
        hoveredIndex = index
        invalidate(localLine(at: hoveredIndex))
        updateCursor()
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = lineIndex(near: point), let line = localLine(at: index) {
            drag = .move(index: index, original: line, anchor: point, current: point)
            hoveredIndex = index
            Debug.log("move start \(index)")
        } else {
            drag = .draw(start: point, current: point)
            Debug.log("draw start \(point)")
        }
        invalidate(previewLine)
        updateCursor()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let previous = previewLine
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .draw(let start, _):
            self.drag = .draw(start: start, current: point)
        case .move(let index, let original, let anchor, _):
            self.drag = .move(index: index, original: original, anchor: anchor, current: point)
        }
        invalidate(previous)
        invalidate(previewLine)
    }

    override func mouseUp(with event: NSEvent) {
        defer { onDragEnded?() }
        guard let drag, let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        let previous = previewLine
        self.drag = nil
        invalidate(previous)

        switch drag {
        case .draw(let start, _):
            let end = Snap.snapped(from: start, to: point)
            // Ignore accidental clicks; only keep real drags.
            if hypot(end.x - start.x, end.y - start.y) >= 2 {
                let line = Line(start: start, end: end, style: LineSettings.shared.style)
                Debug.log("commit \(line)")
                LineStore.shared.add(screenLine(line, window: window))
            }
        case .move(let index, let original, let anchor, _):
            let moved = original.translated(by: NSPoint(x: point.x - anchor.x, y: point.y - anchor.y))
            Debug.log("move end \(index) -> \(moved.start)")
            LineStore.shared.replace(at: index, with: screenLine(moved, window: window))
        }
        setHovered(lineIndex(near: point))
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
        case nil:
            nil
        }
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

    /// Index of the closest committed line within grabbing distance of `point`.
    private func lineIndex(near point: NSPoint) -> Int? {
        guard let window else { return nil }
        var best: (index: Int, distance: CGFloat)?
        for (index, line) in LineStore.shared.lines.enumerated() {
            let local = localLine(line, window: window)
            let tolerance = max(6, line.style.width / 2 + 4)
            let distance = Self.distance(from: point, toSegment: local)
            if distance <= tolerance, distance < (best?.distance ?? .infinity) {
                best = (index, distance)
            }
        }
        return best?.index
    }

    private static func distance(from p: NSPoint, toSegment line: Line) -> CGFloat {
        let a = line.start, b = line.end
        let abx = b.x - a.x, aby = b.y - a.y
        let lengthSquared = abx * abx + aby * aby
        var t: CGFloat = 0
        if lengthSquared > 0 {
            t = ((p.x - a.x) * abx + (p.y - a.y) * aby) / lengthSquared
            t = min(max(t, 0), 1)
        }
        let closest = NSPoint(x: a.x + abx * t, y: a.y + aby * t)
        return hypot(p.x - closest.x, p.y - closest.y)
    }

    private func invalidate(_ line: Line?) {
        guard let line else { return }
        let rect = NSRect(
            x: min(line.start.x, line.end.x),
            y: min(line.start.y, line.end.y),
            width: abs(line.end.x - line.start.x),
            height: abs(line.end.y - line.start.y)
        )
        let margin = line.style.width + Self.haloWidth + 2
        setNeedsDisplay(rect.insetBy(dx: -margin, dy: -margin))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let window else { return }
        let scale = window.backingScaleFactor

        var movingIndex: Int?
        if case .move(let index, _, _, _) = drag { movingIndex = index }

        for (index, line) in LineStore.shared.lines.enumerated() where index != movingIndex {
            let local = localLine(line, window: window)
            if index == hoveredIndex { strokeHalo(local, in: context, scale: scale) }
            stroke(local, in: context, scale: scale)
        }
        if let preview = previewLine {
            if movingIndex != nil { strokeHalo(preview, in: context, scale: scale) }
            stroke(preview, in: context, scale: scale)
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
