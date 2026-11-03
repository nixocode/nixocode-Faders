import XCTest
@testable import Faders

/// Two-finger swipes and mouse wheels over a row.
final class ScrollStepTests: XCTestCase {

    /// With natural scrolling, fingers moving right report a positive x:
    /// the level goes up, like content following the fingers.
    func testRightIsLouder() {
        XCTAssertGreaterThan(ScrollStep.change(along: .horizontal, deltaX: 10, deltaY: 0, isPrecise: true), 0)
        XCTAssertLessThan(ScrollStep.change(along: .horizontal, deltaX: -10, deltaY: 0, isPrecise: true), 0)
    }

    /// Fingers moving up report a negative y (content moves up): louder.
    func testUpIsLouder() {
        XCTAssertGreaterThan(ScrollStep.change(along: .vertical, deltaX: 0, deltaY: -10, isPrecise: true), 0)
        XCTAssertLessThan(ScrollStep.change(along: .vertical, deltaX: 0, deltaY: 10, isPrecise: true), 0)
    }

    /// Only the swipe's own axis counts, so a slightly diagonal swipe is steady.
    func testOnlyTheSwipeAxisCounts() {
        XCTAssertEqual(ScrollStep.change(along: .horizontal, deltaX: 0, deltaY: 50, isPrecise: true), 0)
        XCTAssertEqual(ScrollStep.change(along: .vertical, deltaX: 50, deltaY: 0, isPrecise: true), 0)
    }

    /// 250 trackpad points cross the whole range; one wheel click is 5%.
    func testScale() {
        XCTAssertEqual(ScrollStep.change(along: .horizontal, deltaX: 250, deltaY: 0, isPrecise: true), 1, accuracy: 1e-6)
        XCTAssertEqual(ScrollStep.change(along: .vertical, deltaX: 0, deltaY: -1, isPrecise: false), 0.05, accuracy: 1e-6)
    }
}
