import Atomics
import CoreAudio

/// The part of a tap that runs on Core Audio's real-time audio thread: it copies
/// the app's audio to the speakers, multiplied by the volume.
///
/// `render` must never allocate, lock, log or wait — the audio thread has a few
/// milliseconds to fill each buffer, and any of those can make it miss the
/// deadline (you'd hear a click or a dropout). So it only reads one atomic value
/// and does simple math.
final class TapRenderer: @unchecked Sendable {
    // @unchecked: `targetBits` is atomic, and `current` is only ever touched by
    // the audio thread.

    /// The gain the UI asked for. It's written on the main thread and read on the
    /// audio thread, so a plain `Float` would be a data race: the compiler is free
    /// to cache, reorder or tear it. Atomics only hold integers, so we store the
    /// Float's bit pattern.
    private let targetBits: UnsafeAtomic<UInt32>

    /// The gain applied at the end of the previous buffer (audio thread only).
    private var current: Float

    init(gain: Float) {
        targetBits = .create(gain.bitPattern)
        // Start at the requested level. Starting at 1.0 would ramp down from full
        // volume across the very first buffer — a short blip of loud audio.
        current = gain
    }

    deinit { targetBits.destroy() }

    /// 0.0 = silent, 1.0 = unchanged. Safe to set from any thread.
    var targetGain: Float {
        // Relaxed ordering is enough: the gain is a single value, and no other
        // memory is published along with it.
        get { Float(bitPattern: targetBits.load(ordering: .relaxed)) }
        set { targetBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    /// Called by Core Audio for every buffer.
    func render(from input: UnsafePointer<AudioBufferList>, to output: UnsafeMutablePointer<AudioBufferList>) {
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputBuffers = UnsafeMutableAudioBufferListPointer(output)
        let end = targetGain

        for index in 0..<outputBuffers.count {
            let out = outputBuffers[index]
            guard let outSamples = out.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let outCount = Int(out.mDataByteSize) / MemoryLayout<Float>.size

            // No matching input buffer → output silence.
            guard index < inputBuffers.count,
                  let inSamples = inputBuffers[index].mData?.assumingMemoryBound(to: Float.self)
            else {
                outSamples.update(repeating: 0, count: outCount)
                continue
            }

            let count = min(outCount, Int(inputBuffers[index].mDataByteSize) / MemoryLayout<Float>.size)
            let ramp = GainRamp(from: current, to: end, frameCount: count)
            for i in 0..<count {
                outSamples[i] = inSamples[i] * ramp.gain(atFrame: i)
            }
            if count < outCount {
                (outSamples + count).update(repeating: 0, count: outCount - count)
            }
        }

        current = end
    }
}

/// A straight-line glide from one gain to another across one buffer, so moving
/// a slider never causes a click.
///
/// The last frame lands exactly on the new gain, so consecutive buffers join up
/// without a step.
struct GainRamp {
    let start: Float
    let end: Float
    let frameCount: Int

    init(from start: Float, to end: Float, frameCount: Int) {
        self.start = start
        self.end = end
        self.frameCount = frameCount
    }

    func gain(atFrame frame: Int) -> Float {
        guard frameCount > 0, start != end else { return end }
        return start + (end - start) * Float(frame + 1) / Float(frameCount)
    }
}
