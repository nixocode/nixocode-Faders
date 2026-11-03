import XCTest
@testable import Faders

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
