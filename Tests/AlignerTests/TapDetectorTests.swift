import XCTest
@testable import Aligner

final class TapDetectorTests: XCTestCase {
    /// Feeds held/released transitions; `input` lists timestamps of other input.
    private func run(_ steps: [(Bool, TimeInterval)], input: [TimeInterval] = []) -> [Int] {
        var detector = TapDetector()
        return steps.map { held, now in
            detector.update(held: held, now: now) { interval in
                input.contains { $0 > now - interval - 0.05 && $0 <= now }
            }
        }
    }

    func testSingleTap() { XCTAssertEqual(run([(true, 0.0), (false, 0.1)]), [0, 1]) }
    func testDoubleTap() { XCTAssertEqual(run([(true, 0.0), (false, 0.1), (true, 0.3), (false, 0.4)]), [0, 1, 0, 2]) }
    func testTripleTap() { XCTAssertEqual(run([(true, 0.0), (false, 0.1), (true, 0.2), (false, 0.3), (true, 0.4), (false, 0.5)]), [0, 1, 0, 2, 0, 3]) }
    func testQuadTapKeepsCounting() {
        XCTAssertEqual(run([(true, 0.0), (false, 0.1), (true, 0.2), (false, 0.3), (true, 0.4), (false, 0.5), (true, 0.6), (false, 0.7)]), [0, 1, 0, 2, 0, 3, 0, 4])
    }
    func testGapTooLongRestarts() { XCTAssertEqual(run([(true, 0.0), (false, 0.1), (true, 1.0), (false, 1.1)]), [0, 1, 0, 1]) }
    func testHoldBreaksSequence() { XCTAssertEqual(run([(true, 0.0), (false, 0.8), (true, 0.9), (false, 1.0)]), [0, 0, 0, 1]) }
    func testTypingCapitalsIsNotATap() { XCTAssertEqual(run([(true, 0.0), (false, 0.15), (true, 0.25), (false, 0.4)], input: [0.05, 0.3]), [0, 0, 0, 0]) }
    func testDrawThenTap() { XCTAssertEqual(run([(true, 0.0), (false, 0.3), (true, 0.4), (false, 0.5)], input: [0.1]), [0, 0, 0, 1]) }
    func testClickBetweenTaps() { XCTAssertEqual(run([(true, 0.0), (false, 0.1), (true, 0.3), (false, 0.4)], input: [0.2]), [0, 1, 0, 0]) }
    func testClickAfterDoubleBreaksTriple() {
        XCTAssertEqual(run([(true, 0.0), (false, 0.1), (true, 0.2), (false, 0.3), (true, 0.5), (false, 0.6)], input: [0.4]), [0, 1, 0, 2, 0, 0])
    }
    func testOldInputIgnored() { XCTAssertEqual(run([(true, 5.0), (false, 5.1), (true, 5.3), (false, 5.4)], input: [1.0]), [0, 1, 0, 2]) }
    func testNewSequenceAfterPause() {
        XCTAssertEqual(run([(true, 0.0), (false, 0.1), (true, 0.2), (false, 0.3), (true, 2.0), (false, 2.1), (true, 2.2), (false, 2.3)]), [0, 1, 0, 2, 0, 1, 0, 2])
    }
}
