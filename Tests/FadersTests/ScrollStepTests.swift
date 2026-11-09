import XCTest
@testable import Faders

/// Two-finger sideways swipes over a row.
final class ScrollStepTests: XCTestCase {

    /// With natural scrolling, fingers moving right report a positive x:
    /// the level goes up, like content following the fingers.
    func testRightIsLouder() {
        XCTAssertGreaterThan(ScrollStep.change(deltaX: 10, isPrecise: true), 0)
        XCTAssertLessThan(ScrollStep.change(deltaX: -10, isPrecise: true), 0)
    }

    /// 250 trackpad points cross the whole range; one wheel click is 5%.
    func testScale() {
        XCTAssertEqual(ScrollStep.change(deltaX: 250, isPrecise: true), 1, accuracy: 1e-6)
        XCTAssertEqual(ScrollStep.change(deltaX: 1, isPrecise: false), 0.05, accuracy: 1e-6)
    }
}

/// Apps hidden from the list (right-click → Hide).
final class HiddenAppsTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "FadersTests.HiddenApps"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testNothingHiddenAtFirst() {
        XCTAssertTrue(HiddenApps.load(from: defaults).isEmpty)
    }

    func testRoundTrip() {
        HiddenApps.save(["com.apple.Music", "us.zoom.xos"], to: defaults)
        XCTAssertEqual(HiddenApps.load(from: defaults), ["com.apple.Music", "us.zoom.xos"])
    }

    func testShowingAllClearsTheList() {
        HiddenApps.save(["com.apple.Music"], to: defaults)
        HiddenApps.save([], to: defaults)
        XCTAssertTrue(HiddenApps.load(from: defaults).isEmpty)
    }
}

/// Which devices the output menu offers.
final class OutputMenuTests: XCTestCase {

    func testSpeakersAreListed() {
        XCTAssertTrue(OutputDevice.isListed(uid: "BuiltInSpeakerDevice", isHidden: false, outputStreams: 1))
    }

    /// A microphone has no output streams.
    func testInputOnlyDevicesAreNot() {
        XCTAssertFalse(OutputDevice.isListed(uid: "BuiltInMicrophoneDevice", isHidden: false, outputStreams: 0))
    }

    func testHiddenDevicesAreNot() {
        XCTAssertFalse(OutputDevice.isListed(uid: "SomeVirtualDevice", isHidden: true, outputStreams: 2))
    }

    /// Faders' own aggregate devices are private, but Faders itself still sees them.
    func testFadersOwnDevicesAreNot() {
        XCTAssertFalse(OutputDevice.isListed(uid: AppVolumeTap.aggregateUIDPrefix + UUID().uuidString, isHidden: false, outputStreams: 2))
    }
}
