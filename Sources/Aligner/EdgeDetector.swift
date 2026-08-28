import Foundation

/// A straight, axis-aligned luminance edge found in an `EdgeMap`.
struct DetectedEdge: Equatable {
    enum Orientation { case horizontal, vertical }

    var orientation: Orientation
    /// Pixel boundary: for a horizontal edge the y between rows `position-1`
    /// and `position`; for a vertical edge the x between those columns.
    var position: Int
    /// Extent along the edge in pixels, `start ..< end`.
    var start: Int
    var end: Int
    /// Mean signed luminance step across the boundary; positive means brighter
    /// below (horizontal) or to the right (vertical).
    var step: Int
    /// Mean absolute step, capped per pixel — used to rank candidates.
    var strength: Double
}

/// Finds element edges near a point. A pixel boundary qualifies when a
/// contiguous, same-direction luminance step runs through the point for at
/// least `minExtent` pixels (text glyphs and noise are too short), and its
/// step magnitude is a local maximum across neighbouring boundaries without
/// being part of a plateau (gradients and soft shadows). Anti-aliased edges,
/// hairlines and thin borders all pass.
enum EdgeDetector {
    struct Parameters {
        /// Half-width, in pixels, of the window along the edge used to rank
        /// boundaries against their neighbours.
        var window = 40
        /// A candidate is a plateau (gradient/shadow) if this many consecutive
        /// boundaries, itself included, are within 60 % of its strength.
        var plateauRun = 3
        /// Extent tracing: keep going while the same-direction step is ≥ this,
        /// tolerating `extentGap` consecutive weaker pixels (anti-aliasing,
        /// rounded corners, dotted borders).
        var extentStep = 4
        var extentGap = 2
        /// Shortest contiguous edge that counts, in pixels.
        var minExtent = 24
        var minWindow = 8
    }

    /// Edges of `orientation` whose boundary lies within `radius` px of
    /// `position`, scored over the window centred on `along`, nearest first.
    static func edges(
        in map: EdgeMap,
        orientation: DetectedEdge.Orientation,
        near position: Int,
        along: Int,
        radius: Int,
        parameters p: Parameters = Parameters()
    ) -> [DetectedEdge] {
        let axis = Axis(map: map, horizontal: orientation == .horizontal)
        let margin = p.plateauRun + 1
        let lo = max(1, position - radius - margin)
        let hi = min(axis.boundaryCount - 1, position + radius + margin)
        guard lo <= hi else { return [] }
        let along = min(max(along, 0), axis.alongCount - 1)
        let c0 = max(0, along - p.window)
        let c1 = min(axis.alongCount - 1, along + p.window)
        guard c1 - c0 + 1 >= p.minWindow else { return [] }

        let stats = (lo...hi).map { axis.stats(boundary: $0, from: c0, to: c1, p) }
        var results: [DetectedEdge] = []

        for (i, b) in (lo...hi).enumerated() where abs(b - position) <= radius {
            let s = stats[i]
            guard s.meanAbs >= Double(p.extentStep) * 0.25 else { continue }

            // Local maximum of the step magnitude.
            let prev = i > 0 ? stats[i - 1].meanAbs : 0
            let next = i + 1 < stats.count ? stats[i + 1].meanAbs : 0
            guard s.meanAbs >= prev, s.meanAbs >= next, s.meanAbs > prev || s.meanAbs > next else { continue }

            // Plateau: a run of similar boundaries means a gradient or a soft
            // shadow, not an edge.
            let similar = s.meanAbs * 0.6
            var run = 1
            var j = i - 1
            while j >= 0, stats[j].meanAbs >= similar { run += 1; j -= 1 }
            j = i + 1
            while j < stats.count, stats[j].meanAbs >= similar { run += 1; j += 1 }
            guard run < p.plateauRun else { continue }

            let (start, end) = axis.extent(boundary: b, from: along, sign: s.sign, p)
            guard end - start >= p.minExtent else { continue }
            results.append(DetectedEdge(
                orientation: orientation,
                position: b,
                start: start,
                end: end,
                step: Int(s.meanSigned.rounded()),
                strength: s.meanAbs
            ))
        }

        return mergeAdjacent(results).sorted { abs($0.position - position) < abs($1.position - position) }
    }

    /// An anti-aliased edge scores on two neighbouring boundaries; keep the stronger.
    private static func mergeAdjacent(_ edges: [DetectedEdge]) -> [DetectedEdge] {
        var merged: [DetectedEdge] = []
        for edge in edges.sorted(by: { $0.position < $1.position }) {
            if let last = merged.last, edge.position - last.position <= 1 {
                if edge.strength > last.strength { merged[merged.count - 1] = edge }
            } else {
                merged.append(edge)
            }
        }
        return merged
    }

    private struct Stats {
        var meanAbs: Double
        var meanSigned: Double
        var sign: Int
    }

    /// Reads the map along one axis so the same code scores rows and columns.
    private struct Axis {
        let map: EdgeMap
        let horizontal: Bool

        var boundaryCount: Int { horizontal ? map.height : map.width }
        var alongCount: Int { horizontal ? map.width : map.height }

        @inline(__always)
        func step(boundary b: Int, along c: Int) -> Int {
            horizontal ? map.value(c, b) - map.value(c, b - 1) : map.value(b, c) - map.value(b - 1, c)
        }

        func stats(boundary b: Int, from c0: Int, to c1: Int, _ p: Parameters) -> Stats {
            var sumAbs = 0, sumSigned = 0
            for c in c0...c1 {
                let s = step(boundary: b, along: c)
                sumAbs += min(abs(s), 64)
                sumSigned += s
            }
            let n = Double(c1 - c0 + 1)
            return Stats(
                meanAbs: Double(sumAbs) / n,
                meanSigned: Double(sumSigned) / n,
                sign: sumSigned >= 0 ? 1 : -1
            )
        }

        func extent(boundary b: Int, from c: Int, sign: Int, _ p: Parameters) -> (Int, Int) {
            func matches(_ x: Int) -> Bool {
                let s = step(boundary: b, along: x)
                return sign > 0 ? s >= p.extentStep : s <= -p.extentStep
            }
            var start = c, misses = 0, x = c
            while x - 1 >= 0 {
                x -= 1
                if matches(x) { start = x; misses = 0 } else { misses += 1; if misses > p.extentGap { break } }
            }
            var end = c + 1
            misses = 0
            x = c
            while x + 1 < alongCount {
                x += 1
                if matches(x) { end = x + 1; misses = 0 } else { misses += 1; if misses > p.extentGap { break } }
            }
            return (start, end)
        }
    }
}
