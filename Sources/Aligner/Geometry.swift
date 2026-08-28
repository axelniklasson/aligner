import CoreGraphics
import Foundation

enum Geometry {
    /// Distance from `point` to the closest point on segment a–b.
    static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let lengthSquared = abx * abx + aby * aby
        var t: CGFloat = 0
        if lengthSquared > 0 {
            t = ((point.x - a.x) * abx + (point.y - a.y) * aby) / lengthSquared
            t = min(max(t, 0), 1)
        }
        let closest = CGPoint(x: a.x + abx * t, y: a.y + aby * t)
        return hypot(point.x - closest.x, point.y - closest.y)
    }

    /// Extends segment a–b in both directions until it hits the edges of
    /// `rect`. Returns the input unchanged for a zero-length segment.
    static func extend(_ a: CGPoint, _ b: CGPoint, to rect: CGRect) -> (CGPoint, CGPoint) {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0 else { return (a, b) }
        let ux = dx / length, uy = dy / length

        var tMin = -CGFloat.infinity, tMax = CGFloat.infinity
        if abs(ux) > 1e-9 {
            let t1 = (rect.minX - a.x) / ux, t2 = (rect.maxX - a.x) / ux
            tMin = max(tMin, min(t1, t2))
            tMax = min(tMax, max(t1, t2))
        }
        if abs(uy) > 1e-9 {
            let t1 = (rect.minY - a.y) / uy, t2 = (rect.maxY - a.y) / uy
            tMin = max(tMin, min(t1, t2))
            tMax = min(tMax, max(t1, t2))
        }
        guard tMin.isFinite, tMax.isFinite, tMin < tMax else { return (a, b) }
        return (
            CGPoint(x: a.x + ux * tMin, y: a.y + uy * tMin),
            CGPoint(x: a.x + ux * tMax, y: a.y + uy * tMax)
        )
    }
}
