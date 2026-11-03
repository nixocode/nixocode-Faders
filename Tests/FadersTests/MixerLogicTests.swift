import XCTest
@testable import Faders

/// The slider → loudness curve.
final class VolumeCurveTests: XCTestCase {

    func testEndsStayPut() {
        XCTAssertEqual(AppVolumeTap.gain(forLevel: 0), 0)
        XCTAssertEqual(AppVolumeTap.gain(forLevel: 1), 1)
    }

    /// Half way sounds about half as loud: a quarter of the signal, −12 dB.
    func testHalfWayIsAQuarterOfTheSignal() {
        XCTAssertEqual(AppVolumeTap.gain(forLevel: 0.5), 0.25, accuracy: 1e-6)
    }

    func testOutOfRangeLevelsAreClamped() {
        XCTAssertEqual(AppVolumeTap.gain(forLevel: -0.2), 0)
        XCTAssertEqual(AppVolumeTap.gain(forLevel: 1.5), 1)
    }

    func testAlwaysGetsLouderAsTheSliderGoesUp() {
        let gains = stride(from: Float(0), through: 1, by: 0.05).map(AppVolumeTap.gain(forLevel:))
        XCTAssertEqual(gains, gains.sorted())
        XCTAssertEqual(Set(gains).count, gains.count)
    }
}

/// How the renderer tells real sound from the silence macOS hands over when
/// Faders isn't allowed to hear an app.
final class HeardSoundTests: XCTestCase {

    private let stereo = RenderLayout(tapBuffers: 0..<1, left: 0, right: 1)

    private func render(_ renderer: TapRenderer, input: BufferListFixture) {
        let output = BufferListFixture(channelsPerBuffer: [2], frames: input.frames)
        renderer.render(from: input.pointer, to: output.pointer)
    }

    func testSilenceIsNotSound() {
        let renderer = TapRenderer(gain: 0.5, layout: stereo)
        render(renderer, input: BufferListFixture(channelsPerBuffer: [2], frames: 64))
        XCTAssertFalse(renderer.hasHeardSound)
    }

    func testOneNonZeroSampleIsSound() {
        let renderer = TapRenderer(gain: 0.5, layout: stereo)
        let input = BufferListFixture(channelsPerBuffer: [2], frames: 64)
        input[0, 1, 63] = 0.001
        render(renderer, input: input)
        XCTAssertTrue(renderer.hasHeardSound)
    }

    func testStaysTrueThroughLaterSilence() {
        let renderer = TapRenderer(gain: 0.5, layout: stereo)
        render(renderer, input: BufferListFixture(channelsPerBuffer: [2], frames: 8, fill: 0.2))
        render(renderer, input: BufferListFixture(channelsPerBuffer: [2], frames: 8))
        XCTAssertTrue(renderer.hasHeardSound)
    }

    /// Sound turned all the way down is still sound: the check reads the tap, not the output.
    func testCountsEvenAtZeroGain() {
        let renderer = TapRenderer(gain: 0, layout: stereo)
        render(renderer, input: BufferListFixture(channelsPerBuffer: [2], frames: 8, fill: 0.2))
        XCTAssertTrue(renderer.hasHeardSound)
    }

    /// AirPods' microphone is always live; it must not pass for the app's sound.
    func testDeviceMicrophoneDoesNotCount() {
        let renderer = TapRenderer(gain: 1, layout: RenderLayout(tapBuffers: 1..<2, left: 0, right: 1))
        let input = BufferListFixture(channelsPerBuffer: [1, 2], frames: 8)
        input.fill(buffer: 0, channel: 0, with: 0.3)   // the mic
        render(renderer, input: input)
        XCTAssertFalse(renderer.hasHeardSound)
    }
}

/// Grouping helper processes with the app they belong to, by where they live.
final class BundleContainmentTests: XCTestCase {

    private let apps = ["/Applications/Google Chrome.app", "/Applications/Discord.app", "/Applications/Disc.app"]

    func testHelperInsideItsApp() {
        let helper = "/Applications/Discord.app/Contents/Frameworks/Discord Helper (Renderer).app/Contents/MacOS/Discord Helper (Renderer)"
        XCTAssertEqual(AudioAppScanner.bundle(containing: helper, among: apps), "/Applications/Discord.app")
    }

    /// "/Applications/Disc.app" must not claim "/Applications/Disc.app2/…".
    func testNamePrefixIsNotContainment() {
        XCTAssertNil(AudioAppScanner.bundle(containing: "/Applications/Disc.app2/Contents/MacOS/x", among: apps))
    }

    func testToolOutsideAnyApp() {
        XCTAssertNil(AudioAppScanner.bundle(containing: "/usr/bin/afplay", among: apps))
    }

    func testInnermostBundleWins() {
        let nested = ["/Applications/Suite.app", "/Applications/Suite.app/Contents/Applications/Player.app"]
        let path = "/Applications/Suite.app/Contents/Applications/Player.app/Contents/MacOS/Player"
        XCTAssertEqual(AudioAppScanner.bundle(containing: path, among: nested), nested[1])
    }
}

/// Giving WebKit's per-app processes to their app.
final class WebKitOwnerTests: XCTestCase {

    private let apps = ["Safari", "Finder", "Mail", "Safari Technology Preview"]

    func testNamedAfterItsApp() {
        XCTAssertEqual(AudioAppScanner.appName(in: "Safari Graphics and Media", among: apps), "Safari")
        XCTAssertEqual(AudioAppScanner.appName(in: "Mail Graphics and Media", among: apps), "Mail")
    }

    func testOtherWordOrder() {
        XCTAssertEqual(AudioAppScanner.appName(in: "Gráficos y multimedia de Safari", among: apps), "Safari")
    }

    func testLongestNameWins() {
        XCTAssertEqual(
            AudioAppScanner.appName(in: "Safari Technology Preview Graphics and Media", among: apps),
            "Safari Technology Preview"
        )
    }

    func testWholeWordsOnly() {
        XCTAssertNil(AudioAppScanner.appName(in: "Mailbox Graphics and Media", among: apps))
    }

    func testNotAnApp() {
        XCTAssertNil(AudioAppScanner.appName(in: "WebThumbnailExtension Graphics and Media", among: apps))
    }
}
