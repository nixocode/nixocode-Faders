import XCTest
@testable import Faders

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

    func testTargetGainRoundTrips() {
        let renderer = TapRenderer(gain: 0.25)
        XCTAssertEqual(renderer.targetGain, 0.25)
        renderer.targetGain = 0.8
        XCTAssertEqual(renderer.targetGain, 0.8)
    }

    /// A new tap must start at its own level. Ramping down from 1.0 would play
    /// the first buffer at close to full volume.
    func testFirstBufferIsAlreadyAtTheRequestedLevel() {
        let input = BufferListFixture(channelsPerBuffer: [2], frames: 4, fill: 1)
        let output = BufferListFixture(channelsPerBuffer: [2], frames: 4)

        TapRenderer(gain: 0.2).render(from: input.pointer, to: output.pointer)

        for frame in 0..<4 {
            XCTAssertEqual(output[0, 0, frame], 0.2, accuracy: 1e-6)
        }
    }

    func testRampsToANewTargetAndStaysThere() {
        let renderer = TapRenderer(gain: 1)
        let input = BufferListFixture(channelsPerBuffer: [1], frames: 4, fill: 1)
        let output = BufferListFixture(channelsPerBuffer: [1], frames: 4)

        renderer.targetGain = 0
        renderer.render(from: input.pointer, to: output.pointer)
        XCTAssertEqual((0..<4).map { output[0, 0, $0] }, [0.75, 0.5, 0.25, 0])

        renderer.render(from: input.pointer, to: output.pointer)
        XCTAssertEqual((0..<4).map { output[0, 0, $0] }, [0, 0, 0, 0])
    }
}
