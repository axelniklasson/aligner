import XCTest
@testable import Aligner

/// Synthetic luminance images: rows are top-down, values 0–255.
func makeMap(w: Int, h: Int, scale: CGFloat = 1, fill: (Int, Int) -> Int) -> EdgeMap {
    var luma = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h { for x in 0..<w { luma[y * w + x] = UInt8(clamping: fill(x, y)) } }
    return EdgeMap(width: w, height: h, luma: luma, frame: NSRect(x: 0, y: 0, width: CGFloat(w) / scale, height: CGFloat(h) / scale), scale: scale)
}

/// A 200×120 box at (100, 80) — luminance 60 on 200.
func inBox(_ x: Int, _ y: Int) -> Bool { x >= 100 && x < 300 && y >= 80 && y < 200 }
let boxMap = makeMap(w: 400, h: 300) { x, y in inBox(x, y) ? 60 : 200 }

final class EdgeDetectorTests: XCTestCase {
    private func edges(_ map: EdgeMap, _ o: DetectedEdge.Orientation, near: Int, along: Int, radius: Int = 12) -> [DetectedEdge] {
        EdgeDetector.edges(in: map, orientation: o, near: near, along: along, radius: radius)
    }

    func testBoxTopEdgeWithExtentAndSign() {
        let top = edges(boxMap, .horizontal, near: 83, along: 200)
        XCTAssertEqual(top.count, 1)
        XCTAssertEqual(top.first?.position, 80)
        XCTAssertEqual(top.first?.start, 100)
        XCTAssertEqual(top.first?.end, 300)
        XCTAssertLessThan(top.first?.step ?? 0, 0)
    }

    func testBoxBottomLeftRight() {
        XCTAssertEqual(edges(boxMap, .horizontal, near: 197, along: 150).map(\.position), [200])
        XCTAssertGreaterThan(edges(boxMap, .horizontal, near: 197, along: 150).first?.step ?? 0, 0)
        let left = edges(boxMap, .vertical, near: 104, along: 150)
        XCTAssertEqual(left.map(\.position), [100])
        XCTAssertEqual(left.first?.start, 80)
        XCTAssertEqual(left.first?.end, 200)
        XCTAssertEqual(edges(boxMap, .vertical, near: 290, along: 150).map(\.position), [300])
    }

    func testNothingInsideOrOutsideExtent() {
        XCTAssertTrue(edges(boxMap, .horizontal, near: 140, along: 200).isEmpty)
        XCTAssertTrue(edges(boxMap, .horizontal, near: 80, along: 30).isEmpty)
    }

    func testFaintEdgeFoundButNotTooFaint() {
        let faint = makeMap(w: 400, h: 300) { x, y in inBox(x, y) ? 244 : 250 }
        XCTAssertEqual(edges(faint, .horizontal, near: 80, along: 200).map(\.position), [80])
        let tooFaint = makeMap(w: 400, h: 300) { x, y in inBox(x, y) ? 247 : 250 }
        XCTAssertTrue(edges(tooFaint, .horizontal, near: 80, along: 200).isEmpty)
    }

    func testGradientsRejected() {
        let gentle = makeMap(w: 400, h: 300) { _, y in min(255, y * 6) }
        XCTAssertTrue(edges(gentle, .horizontal, near: 20, along: 200).isEmpty)
        XCTAssertTrue(edges(gentle, .horizontal, near: 42, along: 200, radius: 6).isEmpty, "clamp point of the gradient")
        let steep = makeMap(w: 400, h: 300) { _, y in min(255, y * 14) }
        XCTAssertTrue(edges(steep, .horizontal, near: 10, along: 200, radius: 8).isEmpty)
    }

    func testSoftShadowTailRejectedBoxEdgeKept() {
        let shadow = makeMap(w: 400, h: 300) { x, y in
            guard x >= 100 && x < 300 else { return 200 }
            if y >= 80 && y < 200 { return 60 }
            if y >= 200 && y < 206 { return 164 + (y - 200) * 6 }
            return 200
        }
        XCTAssertEqual(edges(shadow, .horizontal, near: 203, along: 200).map(\.position), [200])
    }

    func testTextLikeNoiseIgnored() {
        let text = makeMap(w: 400, h: 300) { x, y in (y == 150 && (x % 15) < 5) ? 0 : 255 }
        XCTAssertTrue(edges(text, .horizontal, near: 150, along: 200).isEmpty)
    }

    func testAntiAliasedEdgeMergedToOne() {
        let aa = makeMap(w: 400, h: 300) { _, y in y < 100 ? 200 : (y == 100 ? 130 : 60) }
        let found = edges(aa, .horizontal, near: 100, along: 200)
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue((100...101).contains(found.first?.position ?? -1))
    }

    func testThinLinesKeepBothSides() {
        let border = makeMap(w: 400, h: 300) { _, y in (y == 100 || y == 101) ? 0 : 255 }
        XCTAssertEqual(edges(border, .horizontal, near: 101, along: 200).map(\.position).sorted(), [100, 102])
        let hairline = makeMap(w: 400, h: 300) { _, y in y == 100 ? 0 : 255 }
        XCTAssertEqual(edges(hairline, .horizontal, near: 100, along: 200).map(\.position).sorted(), [100, 101])
    }

    func testExtentCrossesSmallGap() {
        let notched = makeMap(w: 400, h: 300) { x, y in inBox(x, y) ? ((y == 80 && x >= 150 && x < 152) ? 200 : 60) : 200 }
        let edge = edges(notched, .horizontal, near: 80, along: 200).first
        XCTAssertEqual(edge?.start, 100)
        XCTAssertEqual(edge?.end, 300)
    }

    func testShortFeaturesNeedMinExtent() {
        let small = makeMap(w: 400, h: 300) { x, y in (x >= 190 && x < 206 && y >= 100 && y < 120) ? 0 : 255 }
        XCTAssertTrue(edges(small, .horizontal, near: 100, along: 198, radius: 6).isEmpty, "16 px is shorter than the 24 px minimum")
        let button = makeMap(w: 400, h: 300) { x, y in (x >= 185 && x < 215 && y >= 100 && y < 120) ? 0 : 255 }
        XCTAssertEqual(edges(button, .horizontal, near: 100, along: 200, radius: 6).count, 1)
    }

    func testEdgeFoundNearItsCorner() {
        let corner = edges(boxMap, .horizontal, near: 80, along: 104, radius: 6)
        XCTAssertEqual(corner.count, 1)
        XCTAssertEqual(corner.first?.start, 100)
    }

    func testDottedBorderFound() {
        let dotted = makeMap(w: 400, h: 300) { x, y in (y == 100 && x >= 100 && x < 300 && (x % 4) < 2) ? 0 : 255 }
        XCTAssertEqual(edges(dotted, .horizontal, near: 100, along: 200, radius: 6).map(\.position).sorted(), [100, 101], "both sides of a dotted 1 px line")
    }

    // MARK: segments()

    func testSegmentsAlongBoundary() {
        let top = EdgeDetector.segments(in: boxMap, orientation: .horizontal, boundary: 80, from: 0, to: 399)
        XCTAssertEqual(top.map { [$0.start, $0.end] }, [[100, 300]])
        XCTAssertLessThan(top.first?.step ?? 0, 0)
        XCTAssertTrue(EdgeDetector.segments(in: boxMap, orientation: .horizontal, boundary: 140, from: 0, to: 399).isEmpty)
        XCTAssertEqual(EdgeDetector.segments(in: boxMap, orientation: .horizontal, boundary: 80, from: 150, to: 399).map { [$0.start, $0.end] }, [[150, 300]], "clipped to the span")
        XCTAssertEqual(EdgeDetector.segments(in: boxMap, orientation: .vertical, boundary: 100, from: 0, to: 299).map { [$0.start, $0.end] }, [[80, 200]])
    }

    func testSegmentsRejectGradientsAndShortRuns() {
        let gentle = makeMap(w: 400, h: 300) { _, y in min(255, y * 6) }
        XCTAssertTrue(EdgeDetector.segments(in: gentle, orientation: .horizontal, boundary: 20, from: 0, to: 399).isEmpty)
        let small = makeMap(w: 400, h: 300) { x, y in (x >= 190 && x < 206 && y >= 100 && y < 120) ? 0 : 255 }
        XCTAssertTrue(EdgeDetector.segments(in: small, orientation: .horizontal, boundary: 100, from: 0, to: 399).isEmpty)
    }

    func testSegmentsFindAlignedBoxesAndTheOddOneOut() {
        let row = makeMap(w: 600, h: 300) { x, y in
            let a = x >= 20 && x < 180 && y >= 80 && y < 200
            let b = x >= 220 && x < 380 && y >= 80 && y < 200
            let c = x >= 420 && x < 580 && y >= 84 && y < 200
            return (a || b || c) ? 60 : 200
        }
        XCTAssertEqual(EdgeDetector.segments(in: row, orientation: .horizontal, boundary: 80, from: 0, to: 599).map { [$0.start, $0.end] }, [[20, 180], [220, 380]])
        XCTAssertEqual(EdgeDetector.segments(in: row, orientation: .horizontal, boundary: 84, from: 0, to: 599).map { [$0.start, $0.end] }, [[420, 580]])
    }

    func testSegmentsSplitOnSignFlip() {
        let flip = makeMap(w: 400, h: 300) { x, y in y < 100 ? 128 : (x < 200 ? 30 : 230) }
        let runs = EdgeDetector.segments(in: flip, orientation: .horizontal, boundary: 100, from: 0, to: 399)
        XCTAssertEqual(runs.count, 2)
        XCTAssertLessThan(runs[0].step, 0)
        XCTAssertGreaterThan(runs[1].step, 0)
        XCTAssertEqual(runs[0].end, 200)
        XCTAssertEqual(runs[1].start, 200)
    }
}
