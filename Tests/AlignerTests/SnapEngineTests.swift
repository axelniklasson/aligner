import XCTest
@testable import Aligner

final class SnapEngineTests: XCTestCase {
    // boxMap is 400×300 at scale 1: screen y = 300 − pixel y, so the box's top edge (pixel 80) is screen y 220.

    func testFlushAboveWhenCursorIsOutside() {
        let result = SnapEngine.snap(boxMap, orientation: .horizontal, value: 224, along: 200, flushWidth: 2, side: 224)
        XCTAssertEqual(result?.value, 221)
        XCTAssertEqual(result?.edge.position, 80)
    }

    func testFlushBelowWhenCursorIsInside() {
        XCTAssertEqual(SnapEngine.snap(boxMap, orientation: .horizontal, value: 217, along: 200, flushWidth: 2, side: 217)?.value, 219)
    }

    func testExactOnBoundary() {
        XCTAssertEqual(SnapEngine.snap(boxMap, orientation: .horizontal, value: 224, along: 200, flushWidth: nil, side: 224)?.value, 220)
    }

    func testNoSnapBeyondRadiusOrOutsideExtent() {
        XCTAssertNil(SnapEngine.snap(boxMap, orientation: .horizontal, value: 240, along: 200, flushWidth: nil, side: 240))
        XCTAssertNil(SnapEngine.snap(boxMap, orientation: .vertical, value: 96, along: 250, flushWidth: 1, side: 96))
    }

    func testVerticalFlushLeft() {
        let result = SnapEngine.snap(boxMap, orientation: .vertical, value: 96, along: 150, flushWidth: 1, side: 96)
        XCTAssertEqual(result?.value, 99.5)
        XCTAssertEqual(result?.edge.position, 100)
    }

    func testRetinaPlacement() {
        // 400×300 px over a 200×150 pt frame; the box top (px 80) is screen y 110.
        let retina = makeMap(w: 400, h: 300, scale: 2) { x, y in inBox(x, y) ? 60 : 200 }
        XCTAssertEqual(SnapEngine.snap(retina, orientation: .horizontal, value: 112, along: 100, flushWidth: 1, side: 112)?.value, 110.5)
        XCTAssertEqual(SnapEngine.snap(retina, orientation: .horizontal, value: 112, along: 100, flushWidth: 0.5, side: 112)?.value, 110.25)
        XCTAssertEqual(SnapEngine.snap(retina, orientation: .horizontal, value: 108, along: 100, flushWidth: 1, side: 108)?.value, 109.5)
        XCTAssertEqual(retina.pixel(fromScreen: NSPoint(x: 10, y: 140)), CGPoint(x: 20, y: 20))
        XCTAssertEqual(retina.screen(fromPixel: CGPoint(x: 20, y: 20)), NSPoint(x: 10, y: 140))
    }

    func testQueryIsFast() {
        let big = makeMap(w: 5120, h: 2880) { x, y in ((x / 200) + (y / 150)) % 2 == 0 ? 230 : 40 }
        let started = ProcessInfo.processInfo.systemUptime
        for i in 0..<200 {
            _ = SnapEngine.snap(big, orientation: .horizontal, value: CGFloat(300 + i * 7), along: CGFloat(100 + i * 20), flushWidth: 1, side: CGFloat(300 + i * 7))
        }
        XCTAssertLessThan((ProcessInfo.processInfo.systemUptime - started) / 200, 0.001)
    }
}
