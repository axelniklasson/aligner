import AppKit

/// Full-screen transparent view that draws the committed lines plus whatever
/// is being dragged. Mouse events only arrive while the owning window is in
/// capture mode (see `OverlayWindow`).
///
/// Dragging on empty space draws a new line. Hovering a line shows Preview-style
/// endpoint handles: dragging the body moves the line, dragging a handle moves
/// that end while the other stays put, and double-clicking extends the line
/// across the screen. With an `EdgeMap` available, anchors, ends and moved
/// lines snap to element edges found on screen.
final class OverlayView: NSView {
    /// Called after a drag finishes so the window can release capture if the
    /// modifier was let go mid-drag.
    var onDragEnded: (() -> Void)?

    /// Captures this view's display as an `EdgeMap`; nil when unavailable.
    var edgeMapProvider: ((@escaping (EdgeMap?) -> Void) -> Void)?

    /// Whether snapping to on-screen edges is on (setting and permission).
    var snapToEdges = false {
        didSet { if !snapToEdges { edgeMap = nil } }
    }

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

    /// An edge to draw while dragging: the one snapped to, others lying on
    /// the same boundary along the line, or near-misses within snap range
    /// (with their offset from the line, in points).
    struct EdgeHighlight {
        enum Kind {
            case snapped
            case aligned
            case nearMiss(CGFloat)
        }
        var edge: DetectedEdge
        var kind: Kind
    }

    private struct DragState {
        enum Kind {
            case draw(rawStart: NSPoint)
            /// `original` is the line in view coordinates when the drag began.
            case move(index: Int, original: Line, anchor: NSPoint)
            case resize(index: Int, original: Line, end: End)
        }

        var kind: Kind
        var current: NSPoint
        /// Mirrors ⇧: a dragged end snaps to 45° while it is held.
        var snap45: Bool
        /// Mirrors ⌘ (inverted): hold ⌘ to skip edge snapping.
        var edgeSnap: Bool
        var preview: Line?
        var highlights: [EdgeHighlight] = []

        var editingIndex: Int? {
            switch kind {
            case .draw: nil
            case .move(let index, _, _), .resize(let index, _, _): index
            }
        }
    }

    private var drag: DragState?
    private var hovered: Target?
    private var storeObserver: NSObjectProtocol?

    /// Set while a scripted demo feeds synthesized events: hover and edge
    /// captures work as if capturing, without intercepting the real pointer.
    var scripted = false

    /// A cursor drawn by the view itself (view coords), for scripted demos
    /// where no real pointer moves.
    var virtualCursor: NSPoint? {
        didSet {
            let image = NSCursor.crosshair.image
            for point in [oldValue, virtualCursor].compactMap({ $0 }) {
                setNeedsDisplay(NSRect(x: point.x - image.size.width, y: point.y - image.size.height, width: image.size.width * 2, height: image.size.height * 2))
            }
        }
    }

    private var edgeMap: EdgeMap?
    private var edgeMapTime: TimeInterval = 0
    private var captureInFlight = false

    private static let haloWidth: CGFloat = 4
    private static let haloAlpha: CGFloat = 0.14
    private static let handleRadius: CGFloat = 4.5
    private static let activeHandleRadius: CGFloat = 6
    private static let handleHitRadius: CGFloat = 9
    private static let edgeHighlightColor = NSColor(srgbRed: 0, green: 0.8, blue: 1, alpha: 0.9)
    private static let nearMissColor = NSColor(srgbRed: 1, green: 0.55, blue: 0, alpha: 0.95)

    var isDragging: Bool { drag != nil }

    /// Fed by the app's modifier poll so a drag reacts to ⇧/⌘ even while the
    /// mouse is still.
    var shiftHeld = false {
        didSet {
            guard shiftHeld != oldValue, drag != nil else { return }
            drag?.snap45 = shiftHeld
            recomputePreview()
        }
    }

    var commandHeld = false {
        didSet {
            guard commandHeld != oldValue, drag != nil else { return }
            drag?.edgeSnap = !commandHeld
            recomputePreview()
        }
    }

    var isCapturing = false {
        didSet {
            guard isCapturing != oldValue else { return }
            if !isCapturing {
                setHovered(nil)
                edgeMap = nil
            }
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
        guard isCapturing || scripted, drag == nil else { return }
        setHovered(target(near: convert(event.locationInWindow, from: nil)))
        // Keep a recent map around so the anchor can snap the moment the
        // mouse goes down.
        refreshEdgeMap(maxAge: 1.0)
    }

    private func updateCursor() {
        guard isCapturing else {
            NSCursor.arrow.set()
            return
        }
        switch drag?.kind {
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

        let kind: DragState.Kind
        switch target {
        case .endpoint(let index, let end):
            guard let line = localLine(at: index) else { return }
            kind = .resize(index: index, original: line, end: end)
            Debug.log("resize start \(index) \(end)")
        case .body(let index):
            guard let line = localLine(at: index) else { return }
            kind = .move(index: index, original: line, anchor: point)
            Debug.log("move start \(index)")
        case nil:
            kind = .draw(rawStart: point)
            Debug.log("draw start \(point)")
        }
        drag = DragState(
            kind: kind,
            current: point,
            snap45: event.modifierFlags.contains(.shift),
            edgeSnap: !event.modifierFlags.contains(.command)
        )
        hovered = target
        refreshEdgeMap(maxAge: 0.3)
        recomputePreview()
        updateCursor()
    }

    override func mouseDragged(with event: NSEvent) {
        guard drag != nil else { return }
        drag?.current = convert(event.locationInWindow, from: nil)
        drag?.snap45 = event.modifierFlags.contains(.shift)
        drag?.edgeSnap = !event.modifierFlags.contains(.command)
        recomputePreview()
    }

    override func mouseUp(with event: NSEvent) {
        defer { onDragEnded?() }
        guard drag != nil, let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        // Commit exactly what was previewed: keep the modifier state from the
        // last drag event rather than re-reading it now.
        drag?.current = point
        recomputePreview()
        guard let state = drag else { return }
        drag = nil
        invalidate(state.preview)
        invalidateHighlights(state.highlights)

        if let result = state.preview, Self.length(of: result) >= 2 {
            switch state.kind {
            case .draw:
                Debug.log("commit \(result)")
                LineStore.shared.add(screenLine(result, window: window))
            case .move(let index, let original, _), .resize(let index, let original, _):
                if !Self.sameEndpoints(result, original) {
                    Debug.log("edit \(index) -> \(result.start) \(result.end)")
                    LineStore.shared.replace(at: index, with: screenLine(result, window: window))
                }
            }
        }
        setHovered(target(near: point))
        updateCursor()
    }

    // MARK: - Preview & snapping

    /// Recomputes the dragged line from the drag state, the current edge map
    /// and the modifier flags, and invalidates what changed.
    private func recomputePreview() {
        guard var state = drag, let window else { return }
        let previous = state.preview
        let previousHighlights = state.highlights
        let map = state.edgeSnap ? edgeMap : nil
        var highlights: [EdgeHighlight] = []
        /// The edge the line itself was placed on (as opposed to an end
        /// snapping to a crossing edge); the along-line scan follows it.
        var lineEdge: DetectedEdge?

        func snap(_ point: NSPoint, to axis: DetectedEdge.Orientation, flush: CGFloat?, side: NSPoint) -> NSPoint? {
            guard let map, let (snapped, edge) = snapped(point, axis: axis, flushWidth: flush, side: side, map: map, window: window) else { return nil }
            highlights.append(EdgeHighlight(edge: edge, kind: .snapped))
            return snapped
        }

        switch state.kind {
        case .draw(let rawStart):
            let style = LineSettings.shared.style
            // Direction comes from the raw gesture; snapping then shifts the
            // whole line so a nudged anchor can't flip the angle.
            let probe = Snap.snapped(from: rawStart, to: state.current)
            let horizontal = probe.y == rawStart.y && probe.x != rawStart.x
            let vertical = probe.x == rawStart.x && probe.y != rawStart.y
            let undecided = probe == rawStart
            var start = rawStart
            if horizontal || vertical || undecided {
                // Flush against the edge the line runs along, exactly on the
                // edge the line starts from.
                if let p = snap(start, to: .horizontal, flush: (horizontal || undecided) ? style.width : nil, side: rawStart) {
                    start.y = p.y
                    if horizontal { lineEdge = highlights.last?.edge }
                }
                if let p = snap(start, to: .vertical, flush: (vertical || undecided) ? style.width : nil, side: rawStart) {
                    start.x = p.x
                    if vertical { lineEdge = highlights.last?.edge }
                }
            }
            var end = NSPoint(x: probe.x + (start.x - rawStart.x), y: probe.y + (start.y - rawStart.y))
            if horizontal, let p = snap(end, to: .vertical, flush: nil, side: end) { end.x = p.x }
            if vertical, let p = snap(end, to: .horizontal, flush: nil, side: end) { end.y = p.y }
            state.preview = Line(start: start, end: end, style: style)

        case .move(_, let original, let anchor):
            var moved = original.translated(by: NSPoint(x: state.current.x - anchor.x, y: state.current.y - anchor.y))
            if Self.isHorizontal(moved) {
                let probe = NSPoint(x: state.current.x, y: moved.start.y)
                if let p = snap(probe, to: .horizontal, flush: original.style.width, side: probe) {
                    moved.start.y = p.y
                    moved.end.y = p.y
                    lineEdge = highlights.last?.edge
                }
            } else if Self.isVertical(moved) {
                let probe = NSPoint(x: moved.start.x, y: state.current.y)
                if let p = snap(probe, to: .vertical, flush: original.style.width, side: probe) {
                    moved.start.x = p.x
                    moved.end.x = p.x
                    lineEdge = highlights.last?.edge
                }
            }
            state.preview = moved

        case .resize(_, let original, let end):
            let fixed = end == .start ? original.end : original.start
            var moving = state.snap45 ? Snap.snapped(from: fixed, to: state.current) : state.current
            let horizontal = moving.y == fixed.y && moving.x != fixed.x
            let vertical = moving.x == fixed.x && moving.y != fixed.y
            if horizontal {
                if let p = snap(moving, to: .vertical, flush: nil, side: moving) { moving.x = p.x }
            } else if vertical {
                if let p = snap(moving, to: .horizontal, flush: nil, side: moving) { moving.y = p.y }
            } else if !state.snap45 {
                if let p = snap(moving, to: .horizontal, flush: nil, side: moving) { moving.y = p.y }
                if let p = snap(moving, to: .vertical, flush: nil, side: moving) { moving.x = p.x }
            }
            var line = original
            if end == .start { line.start = moving } else { line.end = moving }
            state.preview = line
        }

        if let map, let lineEdge, let preview = state.preview {
            highlights += alongLineHighlights(for: preview, on: lineEdge, map: map, window: window)
        }

        state.highlights = highlights
        drag = state
        invalidate(previous)
        invalidate(state.preview)
        invalidateHighlights(previousHighlights)
        invalidateHighlights(highlights)
    }

    /// Follows a line that was placed on `edge` along its whole span: every
    /// other edge segment on the same boundary is reported as aligned, and
    /// segments from other elements within snap range but off the boundary
    /// as near-misses with their offset.
    private func alongLineHighlights(for line: Line, on edge: DetectedEdge, map: EdgeMap, window: NSWindow) -> [EdgeHighlight] {
        let horizontal = edge.orientation == .horizontal
        let a = map.pixel(fromScreen: window.convertPoint(toScreen: convert(line.start, to: nil)))
        let b = map.pixel(fromScreen: window.convertPoint(toScreen: convert(line.end, to: nil)))
        let from = Int((horizontal ? min(a.x, b.x) : min(a.y, b.y)).rounded())
        let to = Int((horizontal ? max(a.x, b.x) : max(a.y, b.y)).rounded())
        var parameters = EdgeDetector.Parameters()
        parameters.window = Int((SnapEngine.window * map.scale).rounded())
        parameters.minExtent = Int((SnapEngine.minExtent * map.scale).rounded())

        let onLine = EdgeDetector.segments(in: map, orientation: edge.orientation, boundary: edge.position, from: from, to: to, parameters: parameters)
        var highlights: [EdgeHighlight] = onLine
            .filter { !($0.start <= edge.start && $0.end >= edge.end) }   // the snapped edge is already shown
            .map { EdgeHighlight(edge: $0, kind: .aligned) }

        // Near-misses: other elements' edges within snap range. Anything
        // overlapping an on-line segment is the same element (the other side
        // of a border, an anti-aliasing neighbour) and is skipped.
        let occupied = onLine + [edge]
        let radius = Int((SnapEngine.nearMissRadius * map.scale).rounded(.up))
        var misses: [(DetectedEdge, Int)] = []
        for offset in -radius...radius where offset != 0 {
            for segment in EdgeDetector.segments(in: map, orientation: edge.orientation, boundary: edge.position + offset, from: from, to: to, parameters: parameters) {
                let sameElement = occupied.contains { $0.start < segment.end && segment.start < $0.end }
                guard !sameElement else { continue }
                // Anti-aliased edges appear on two neighbouring boundaries; keep the stronger.
                if let i = misses.firstIndex(where: { abs($0.1 - offset) <= 1 && $0.0.start < segment.end && segment.start < $0.0.end }) {
                    if segment.strength > misses[i].0.strength { misses[i] = (segment, offset) }
                } else {
                    misses.append((segment, offset))
                }
            }
        }
        highlights += misses.map { EdgeHighlight(edge: $0.0, kind: .nearMiss(CGFloat($0.1) / map.scale)) }
        return highlights
    }

    /// Snaps one coordinate of `point` (view coords) to the nearest edge of
    /// `axis`'s orientation. See `SnapEngine.snap` for `flushWidth`/`side`.
    private func snapped(
        _ point: NSPoint,
        axis: DetectedEdge.Orientation,
        flushWidth: CGFloat?,
        side: NSPoint,
        map: EdgeMap,
        window: NSWindow
    ) -> (NSPoint, DetectedEdge)? {
        let screenPoint = window.convertPoint(toScreen: convert(point, to: nil))
        let screenSide = window.convertPoint(toScreen: convert(side, to: nil))
        let horizontal = axis == .horizontal
        guard let result = SnapEngine.snap(
            map,
            orientation: axis,
            value: horizontal ? screenPoint.y : screenPoint.x,
            along: horizontal ? screenPoint.x : screenPoint.y,
            flushWidth: flushWidth,
            side: horizontal ? screenSide.y : screenSide.x
        ) else { return nil }
        var snappedScreen = screenPoint
        if horizontal { snappedScreen.y = result.value } else { snappedScreen.x = result.value }
        Debug.log("snap \(axis) value=\(horizontal ? screenPoint.y : screenPoint.x) flush=\(String(describing: flushWidth)) side=\(horizontal ? screenSide.y : screenSide.x) -> boundary \(result.edge.position) [\(result.edge.start)-\(result.edge.end)] step \(result.edge.step) => \(result.value)")
        return (convert(window.convertPoint(fromScreen: snappedScreen), from: nil), result.edge)
    }

    private func refreshEdgeMap(maxAge: TimeInterval) {
        guard snapToEdges, !captureInFlight, let provider = edgeMapProvider else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard edgeMap == nil || now - edgeMapTime > maxAge else { return }
        captureInFlight = true
        provider { [weak self] map in
            guard let self else { return }
            captureInFlight = false
            guard let map, isCapturing || scripted || drag != nil else { return }
            edgeMap = map
            edgeMapTime = ProcessInfo.processInfo.systemUptime
            if drag != nil { recomputePreview() }
        }
    }

    // MARK: - Geometry

    private static func isHorizontal(_ line: Line) -> Bool { abs(line.start.y - line.end.y) < 0.001 }
    private static func isVertical(_ line: Line) -> Bool { abs(line.start.x - line.end.x) < 0.001 }

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

    private func invalidateHighlights(_ highlights: [EdgeHighlight]) {
        guard !highlights.isEmpty, let map = edgeMap, let window else { return }
        for highlight in highlights {
            let (a, b) = edgeEndpoints(highlight.edge, map: map, window: window)
            let rect = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            setNeedsDisplay(rect.insetBy(dx: -40, dy: -40))   // room for offset labels
        }
    }

    private func edgeEndpoints(_ edge: DetectedEdge, map: EdgeMap, window: NSWindow) -> (NSPoint, NSPoint) {
        let a: CGPoint, b: CGPoint
        switch edge.orientation {
        case .horizontal:
            a = CGPoint(x: edge.start, y: edge.position)
            b = CGPoint(x: edge.end, y: edge.position)
        case .vertical:
            a = CGPoint(x: edge.position, y: edge.start)
            b = CGPoint(x: edge.position, y: edge.end)
        }
        return (
            convert(window.convertPoint(fromScreen: map.screen(fromPixel: a)), from: nil),
            convert(window.convertPoint(fromScreen: map.screen(fromPixel: b)), from: nil)
        )
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

        // The halo is only a "close enough to grab" cue while hovering; once a
        // line is grabbed the handles are enough.
        if let preview = drag?.preview {
            stroke(preview, in: context, scale: scale)
            if case .resize(_, _, let end) = drag?.kind {
                drawHandles(for: preview, active: end, in: context)
            } else if editingIndex != nil {
                drawHandles(for: preview, active: nil, in: context)
            }
        } else if let hoveredIndex, let local = localLine(at: hoveredIndex) {
            var active: End?
            if case .endpoint(_, let end) = hovered { active = end }
            drawHandles(for: local, active: active, in: context)
        }

        if let highlights = drag?.highlights, !highlights.isEmpty, let map = edgeMap {
            for highlight in highlights {
                drawEdgeHighlight(highlight, map: map, window: window, in: context)
            }
        }

        if let virtualCursor {
            let cursor = NSCursor.crosshair
            let origin = NSPoint(x: virtualCursor.x - cursor.hotSpot.x, y: virtualCursor.y - (cursor.image.size.height - cursor.hotSpot.y))
            cursor.image.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
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
        context.setStrokeColor(line.style.color.withAlphaComponent(Self.haloAlpha).cgColor)
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

    /// Marks an element edge along its detected extent with a tick at each
    /// end: cyan for the edge snapped to and others on the same line, orange
    /// with an offset label for near-misses.
    private func drawEdgeHighlight(_ highlight: EdgeHighlight, map: EdgeMap, window: NSWindow, in context: CGContext) {
        let edge = highlight.edge
        let (a, b) = edgeEndpoints(edge, map: map, window: window)
        var color = Self.edgeHighlightColor
        var offset: CGFloat?
        if case .nearMiss(let value) = highlight.kind {
            color = Self.nearMissColor
            offset = value
        }
        context.setLineDash(phase: 0, lengths: [])
        context.setLineCap(.butt)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(2)
        context.move(to: a)
        context.addLine(to: b)
        let tick: CGFloat = 5
        if edge.orientation == .horizontal {
            for p in [a, b] {
                context.move(to: CGPoint(x: p.x, y: p.y - tick))
                context.addLine(to: CGPoint(x: p.x, y: p.y + tick))
            }
        } else {
            for p in [a, b] {
                context.move(to: CGPoint(x: p.x - tick, y: p.y))
                context.addLine(to: CGPoint(x: p.x + tick, y: p.y))
            }
        }
        context.strokePath()

        if let offset {
            // Label on the far side of the segment from the line. Pixel rows
            // grow downwards, so a positive offset means below / to the right.
            let mid = NSPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let away: CGFloat = 14
            let at: NSPoint
            if edge.orientation == .horizontal {
                at = NSPoint(x: mid.x, y: offset > 0 ? mid.y - away : mid.y + away)
            } else {
                at = NSPoint(x: offset > 0 ? mid.x + away : mid.x - away, y: mid.y)
            }
            let magnitude = abs(offset)
            let text = magnitude == magnitude.rounded() ? "\(Int(magnitude)) pt off" : String(format: "%.1f pt off", magnitude)
            drawLabel(text, centeredAt: at, color: color)
        }
    }

    private func drawLabel(_ text: String, centeredAt point: NSPoint, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let rect = NSRect(x: point.x - size.width / 2 - 5, y: point.y - size.height / 2 - 2, width: size.width + 10, height: size.height + 4)
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        string.draw(at: NSPoint(x: rect.minX + 5, y: rect.minY + 2))
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
