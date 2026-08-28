import AppKit

/// A committed guide line, stored in global screen coordinates (points).
struct Line {
    var start: NSPoint
    var end: NSPoint
    var style: LineStyle

    func translated(by delta: NSPoint) -> Line {
        var copy = self
        copy.start.x += delta.x
        copy.start.y += delta.y
        copy.end.x += delta.x
        copy.end.y += delta.y
        return copy
    }
}

/// All committed lines, shared by every overlay window so a line drawn on
/// one screen survives screen reconfiguration and undo/clear apply globally.
final class LineStore {
    static let shared = LineStore()
    static let didChange = Notification.Name("LineStore.didChange")

    private(set) var lines: [Line] = []

    func add(_ line: Line) {
        lines.append(line)
        changed()
    }

    func replace(at index: Int, with line: Line) {
        guard lines.indices.contains(index) else { return }
        lines[index] = line
        changed()
    }

    func undo() {
        guard !lines.isEmpty else { return }
        lines.removeLast()
        changed()
    }

    func clear() {
        guard !lines.isEmpty else { return }
        lines.removeAll()
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
