import AppKit

enum Snap {
    /// Unit vectors for 0°, 45°, 90°, … 315°, kept exact so axis-aligned lines
    /// are detectable with a plain comparison later.
    private static let directions: [NSPoint] = {
        let d = CGFloat(0.5).squareRoot()
        return [
            NSPoint(x: 1, y: 0), NSPoint(x: d, y: d),
            NSPoint(x: 0, y: 1), NSPoint(x: -d, y: d),
            NSPoint(x: -1, y: 0), NSPoint(x: -d, y: -d),
            NSPoint(x: 0, y: -1), NSPoint(x: d, y: -d),
        ]
    }()

    /// Projects `point` onto the 45°-increment direction closest to start→point,
    /// which is how Preview behaves when you shift-drag: the line follows the
    /// cursor along the snapped axis.
    static func snapped(from start: NSPoint, to point: NSPoint) -> NSPoint {
        let dx = point.x - start.x
        let dy = point.y - start.y
        guard dx != 0 || dy != 0 else { return point }

        let step = CGFloat.pi / 4
        let index = Int((atan2(dy, dx) / step).rounded())  // -4...4
        let dir = directions[((index % 8) + 8) % 8]
        let length = dx * dir.x + dy * dir.y
        return NSPoint(x: start.x + dir.x * length, y: start.y + dir.y * length)
    }
}
