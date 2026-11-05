import XCTest
@testable import Faders

/// Renders one buffer. Taking the fixtures as arguments keeps them alive for the
/// whole call; `fixture().pointer` alone would let the fixture be freed first.
private func render(_ renderer: TapRenderer, from input: BufferListFixture, to output: BufferListFixture) {
    renderer.render(from: input.pointer, to: output.pointer)
}

final class GainRampTests: XCTestCase {

    func testLastFrameLandsExactlyOnTheNewGain() {
        let ramp = GainRamp(from: 1, to: 0.5, frameCount: 4)
        XCTAssertEqual(ramp.gain(atFrame: 3), 0.5)
    }

    func testGlidesInEqualSteps() {
        let ramp = GainRamp(from: 0, to: 1, frameCount: 4)
        XCTAssertEqual((0..<4).map(ramp.gain(atFrame:)), [0.25, 0.5, 0.75, 1])
    }

    func testFlatWhenTheGainDoesNotChange() {
        let ramp = GainRamp(from: 0.3, to: 0.3, frameCount: 512)
        XCTAssertEqual(ramp.gain(atFrame: 0), 0.3)
        XCTAssertEqual(ramp.gain(atFrame: 511), 0.3)
    }

    func testEmptyBufferIsSafe() {
        XCTAssertEqual(GainRamp(from: 1, to: 0, frameCount: 0).gain(atFrame: 0), 0)
    }
}

final class TapRendererTests: XCTestCase {

    /// The common case: one interleaved stereo tap buffer, channels 1 and 2 out.
    private let stereo = RenderLayout(tapBuffers: 0..<1, left: 0, right: 1)

    /// A tap buffer with left = 0.5 and right = -0.25 on every frame.
    private func stereoTap(frames: Int = 4) -> BufferListFixture {
        let tap = BufferListFixture(channelsPerBuffer: [2], frames: frames)
        tap.fill(buffer: 0, channel: 0, with: 0.5)
        tap.fill(buffer: 0, channel: 1, with: -0.25)
        return tap
    }

    func testTargetGainRoundTrips() {
        let renderer = TapRenderer(gain: 0.25, layout: stereo)
        XCTAssertEqual(renderer.targetGain, 0.25)
        renderer.targetGain = 0.8
        XCTAssertEqual(renderer.targetGain, 0.8)
    }

    /// A new tap must start at its own level. Ramping down from 1.0 would play
    /// the first buffer at close to full volume.
    func testFirstBufferIsAlreadyAtTheRequestedLevel() {
        let input = BufferListFixture(channelsPerBuffer: [2], frames: 4, fill: 1)
        let output = BufferListFixture(channelsPerBuffer: [2], frames: 4)

        render(TapRenderer(gain: 0.2, layout: stereo), from: input, to: output)

        for frame in 0..<4 {
            XCTAssertEqual(output[0, 0, frame], 0.2, accuracy: 1e-6)
        }
    }

    func testRampsToANewTargetAndStaysThere() {
        let renderer = TapRenderer(gain: 1, layout: RenderLayout(tapBuffers: 0..<1, left: 0, right: 0))
        let input = BufferListFixture(channelsPerBuffer: [1], frames: 4, fill: 1)
        let output = BufferListFixture(channelsPerBuffer: [1], frames: 4)

        renderer.targetGain = 0
        render(renderer, from: input, to: output)
        XCTAssertEqual((0..<4).map { output[0, 0, $0] }, [0.75, 0.5, 0.25, 0])

        render(renderer, from: input, to: output)
        XCTAssertEqual((0..<4).map { output[0, 0, $0] }, [0, 0, 0, 0])
    }

    // MARK: Channel layouts

    func testInterleavedStereoToInterleavedStereo() {
        let output = BufferListFixture(channelsPerBuffer: [2], frames: 4)
        render(TapRenderer(gain: 0.5, layout: stereo), from: stereoTap(), to: output)

        XCTAssertEqual(output[0, 0, 3], 0.25)
        XCTAssertEqual(output[0, 1, 3], -0.125)
    }

    func testNonInterleavedTapIsReadChannelByChannel() {
        let tap = BufferListFixture(channelsPerBuffer: [1, 1], frames: 4)
        tap.fill(buffer: 0, channel: 0, with: 0.5)
        tap.fill(buffer: 1, channel: 0, with: -0.25)
        let output = BufferListFixture(channelsPerBuffer: [2], frames: 4)

        render(TapRenderer(gain: 1, layout: RenderLayout(tapBuffers: 0..<2, left: 0, right: 1)), from: tap, to: output)

        XCTAssertEqual(output[0, 0, 2], 0.5)
        XCTAssertEqual(output[0, 1, 2], -0.25)
    }

    func testNonInterleavedOutputGetsOneChannelPerBuffer() {
        let output = BufferListFixture(channelsPerBuffer: [1, 1, 1, 1], frames: 4, fill: 9)
        render(TapRenderer(gain: 1, layout: stereo), from: stereoTap(), to: output)

        XCTAssertEqual(output[0, 0, 1], 0.5)
        XCTAssertEqual(output[1, 0, 1], -0.25)
        XCTAssertEqual(output[2, 0, 1], 0)
        XCTAssertEqual(output[3, 0, 1], 0)
    }

    /// An HDMI receiver or audio interface: stereo goes to the first two channels,
    /// the other six are silent (not left with garbage from the previous buffer).
    func testEightChannelOutputSilencesTheExtraChannels() {
        let output = BufferListFixture(channelsPerBuffer: [8], frames: 4, fill: 9)
        render(TapRenderer(gain: 1, layout: stereo), from: stereoTap(), to: output)

        for frame in 0..<4 {
            XCTAssertEqual(output[0, 0, frame], 0.5)
            XCTAssertEqual(output[0, 1, frame], -0.25)
            for channel in 2..<8 { XCTAssertEqual(output[0, channel, frame], 0) }
        }
    }

    func testPreferredStereoPairIsHonored() {
        let output = BufferListFixture(channelsPerBuffer: [4], frames: 4)
        render(TapRenderer(gain: 1, layout: RenderLayout(tapBuffers: 0..<1, left: 2, right: 3)), from: stereoTap(), to: output)

        XCTAssertEqual(output[0, 0, 0], 0)
        XCTAssertEqual(output[0, 1, 0], 0)
        XCTAssertEqual(output[0, 2, 0], 0.5)
        XCTAssertEqual(output[0, 3, 0], -0.25)
    }

    func testMonoOutputMixesBothSides() {
        let output = BufferListFixture(channelsPerBuffer: [1], frames: 4)
        render(TapRenderer(gain: 1, layout: RenderLayout(tapBuffers: 0..<1, left: 0, right: 0)), from: stereoTap(), to: output)

        XCTAssertEqual(output[0, 0, 0], 0.125)
    }

    func testMonoTapFeedsBothSides() {
        let tap = BufferListFixture(channelsPerBuffer: [1], frames: 4, fill: 0.5)
        let output = BufferListFixture(channelsPerBuffer: [2], frames: 4)
        render(TapRenderer(gain: 1, layout: stereo), from: tap, to: output)

        XCTAssertEqual(output[0, 0, 0], 0.5)
        XCTAssertEqual(output[0, 1, 0], 0.5)
    }

    /// AirPods and USB headsets have a microphone, which the aggregate device
    /// lists before the tap. Its sound must never reach the output.
    func testDeviceMicrophoneIsNeverPlayed() {
        let input = BufferListFixture(channelsPerBuffer: [1, 2], frames: 4)
        input.fill(buffer: 0, channel: 0, with: 0.9)    // the microphone
        input.fill(buffer: 1, channel: 0, with: 0.5)    // the tap
        input.fill(buffer: 1, channel: 1, with: -0.25)
        let output = BufferListFixture(channelsPerBuffer: [2], frames: 4)

        render(TapRenderer(gain: 1, layout: RenderLayout(tapBuffers: 1..<2, left: 0, right: 1)), from: input, to: output)

        XCTAssertEqual(output[0, 0, 0], 0.5)
        XCTAssertEqual(output[0, 1, 0], -0.25)
    }

    func testMissingTapAudioGivesSilence() {
        let tap = stereoTap()
        tap.disable(buffer: 0)
        let output = BufferListFixture(channelsPerBuffer: [2], frames: 4, fill: 9)
        render(TapRenderer(gain: 1, layout: stereo), from: tap, to: output)

        XCTAssertEqual(output[0, 0, 0], 0)
        XCTAssertEqual(output[0, 1, 3], 0)
    }

    func testShortTapBufferLeavesTheRestSilent() {
        let output = BufferListFixture(channelsPerBuffer: [2], frames: 8, fill: 9)
        render(TapRenderer(gain: 1, layout: stereo), from: stereoTap(frames: 4), to: output)

        XCTAssertEqual(output[0, 0, 3], 0.5)
        XCTAssertEqual(output[0, 0, 4], 0)
        XCTAssertEqual(output[0, 1, 7], 0)
    }
}

final class RenderLayoutTests: XCTestCase {

    func testTapComesAfterTheDeviceInputs() {
        let layout = RenderLayout(deviceInputStreams: 1, aggregateInputStreams: 2, outputChannels: 2, preferredStereo: [1, 2])
        XCTAssertEqual(layout, RenderLayout(tapBuffers: 1..<2, left: 0, right: 1))
    }

    func testSpeakersWithoutInputs() {
        let layout = RenderLayout(deviceInputStreams: 0, aggregateInputStreams: 1, outputChannels: 2, preferredStereo: [1, 2])
        XCTAssertEqual(layout?.tapBuffers, 0..<1)
    }

    func testNoTapStreamMeansNoLayout() {
        XCTAssertNil(RenderLayout(deviceInputStreams: 1, aggregateInputStreams: 1, outputChannels: 2, preferredStereo: [1, 2]))
    }

    func testPreferredPairOnAnInterface() {
        let layout = RenderLayout(deviceInputStreams: 0, aggregateInputStreams: 1, outputChannels: 8, preferredStereo: [3, 4])
        XCTAssertEqual(layout?.left, 2)
        XCTAssertEqual(layout?.right, 3)
    }

    func testInvalidPreferredPairFallsBackToTheFirstTwoChannels() {
        let layout = RenderLayout(deviceInputStreams: 0, aggregateInputStreams: 1, outputChannels: 2, preferredStereo: [5, 6])
        XCTAssertEqual(layout?.left, 0)
        XCTAssertEqual(layout?.right, 1)
    }

    func testMonoDevice() {
        let layout = RenderLayout(deviceInputStreams: 0, aggregateInputStreams: 1, outputChannels: 1, preferredStereo: [1, 2])
        XCTAssertEqual(layout?.left, 0)
        XCTAssertEqual(layout?.right, 0)
    }
}
