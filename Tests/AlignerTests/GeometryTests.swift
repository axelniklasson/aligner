import XCTest
@testable import Aligner

final class GeometryTests: XCTestCase {
    private let rect = CGRect(x: 0, y: 0, width: 1000, height: 500)

    private func assertExtend(_ a: CGPoint, _ b: CGPoint, _ ea: CGPoint, _ eb: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        let (ra, rb) = Geometry.extend(a, b, to: rect)
        XCTAssertEqual(ra.x, ea.x, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(ra.y, ea.y, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(rb.x, eb.x, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(rb.y, eb.y, accuracy: 1e-6, file: file, line: line)
    }

    func testDistanceOnSegment() { XCTAssertEqual(Geometry.distance(from: CGPoint(x: 5, y: 0), toSegment: CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)), 0) }
    func testDistancePerpendicular() { XCTAssertEqual(Geometry.distance(from: CGPoint(x: 5, y: 3), toSegment: CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)), 3) }
    func testDistanceBeyondEndClamps() { XCTAssertEqual(Geometry.distance(from: CGPoint(x: 13, y: 4), toSegment: CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)), 5) }
    func testDistanceToPoint() { XCTAssertEqual(Geometry.distance(from: CGPoint(x: 3, y: 4), toSegment: .zero, .zero), 5) }

    func testExtendHorizontal() { assertExtend(CGPoint(x: 100, y: 200), CGPoint(x: 300, y: 200), CGPoint(x: 0, y: 200), CGPoint(x: 1000, y: 200)) }
    func testExtendVertical() { assertExtend(CGPoint(x: 400, y: 100), CGPoint(x: 400, y: 150), CGPoint(x: 400, y: 0), CGPoint(x: 400, y: 500)) }
    func testExtendDiagonal() { assertExtend(CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 200), CGPoint(x: 0, y: 0), CGPoint(x: 500, y: 500)) }
    func testExtendDiagonalHitsTopBeforeSide() { assertExtend(CGPoint(x: 900, y: 100), CGPoint(x: 800, y: 200), CGPoint(x: 1000, y: 0), CGPoint(x: 500, y: 500)) }
    func testExtendKeepsDirection() { assertExtend(CGPoint(x: 300, y: 200), CGPoint(x: 100, y: 200), CGPoint(x: 1000, y: 200), CGPoint(x: 0, y: 200)) }
    func testExtendZeroLengthUnchanged() { assertExtend(CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5)) }
}
