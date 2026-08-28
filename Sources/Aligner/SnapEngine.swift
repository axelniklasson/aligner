import AppKit

/// Turns detected edges into snapped screen coordinates.
enum SnapEngine {
    /// How close (in points) a coordinate has to be to an edge to snap.
    static let radius: CGFloat = 6
    /// Half-width (in points) of the stretch of edge used to rank boundaries.
    static let window: CGFloat = 20
    /// Shortest edge (in points) worth snapping to — filters out text glyphs.
    static let minExtent: CGFloat = 12

    struct Result {
        var value: CGFloat
        var edge: DetectedEdge
    }

    /// Snaps one screen coordinate to the nearest edge of `orientation`.
    ///
    /// - value: the coordinate to snap (y for horizontal edges, x for vertical).
    /// - along: the other coordinate — where along the edge to look.
    /// - flushWidth: when set, the result is the centre of a line this many
    ///   points wide placed flush against the edge, on the side `side` is on
    ///   ("just outside"); when nil the result lands exactly on the boundary.
    static func snap(
        _ map: EdgeMap,
        orientation: DetectedEdge.Orientation,
        value: CGFloat,
        along: CGFloat,
        flushWidth: CGFloat?,
        side: CGFloat
    ) -> Result? {
        let horizontal = orientation == .horizontal
        let scale = map.scale
        func toPixel(_ v: CGFloat, vertical: Bool) -> CGFloat {
            vertical ? (map.frame.maxY - v) * scale : (v - map.frame.minX) * scale
        }
        let valuePx = toPixel(value, vertical: horizontal)
        let alongPx = toPixel(along, vertical: !horizontal)
        let sidePx = toPixel(side, vertical: horizontal)

        var parameters = EdgeDetector.Parameters()
        parameters.window = Int((window * scale).rounded())
        parameters.minExtent = Int((minExtent * scale).rounded())
        let radiusPx = Int((radius * scale).rounded(.up))
        let edges = EdgeDetector.edges(
            in: map,
            orientation: orientation,
            near: Int(valuePx.rounded()),
            along: Int(alongPx.rounded()),
            radius: radiusPx,
            parameters: parameters
        )
        guard let edge = edges.first, abs(CGFloat(edge.position) - valuePx) <= radius * scale else { return nil }

        let boundary = CGFloat(edge.position)
        var snappedPx = boundary
        if let flushWidth {
            let widthPx = max(flushWidth * scale, 1)
            snappedPx = sidePx < boundary ? boundary - widthPx / 2 : boundary + widthPx / 2
        }
        let snapped = horizontal ? map.frame.maxY - snappedPx / scale : map.frame.minX + snappedPx / scale
        return Result(value: snapped, edge: edge)
    }
}
