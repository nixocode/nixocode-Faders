import Atomics
import CoreAudio

/// The part of a tap that runs on Core Audio's real-time audio thread: it copies
/// the app's audio to the speakers, multiplied by the volume.
///
/// `render` must never allocate, lock, log or wait — the audio thread has a few
/// milliseconds to fill each buffer, and any of those can make it miss the
/// deadline (you'd hear a click or a dropout). So it only reads one atomic value
/// and does simple math.
///
/// It makes no assumptions about how the audio is laid out. Everything it needs
/// is in the buffers themselves: each `AudioBuffer` says how many channels it
/// interleaves, so the same code handles "L R L R…" in one buffer and one buffer
/// per channel, on either side. Sample rates always match, because the
/// aggregate device resamples the tap to the output's rate before we see it.
final class TapRenderer: @unchecked Sendable {
    // @unchecked: `targetBits` and `heardBits` are atomic, `layout` never
    // changes, and `current` is only ever touched by the audio thread.

    /// The gain the UI asked for. It's written on the main thread and read on the
    /// audio thread, so a plain `Float` would be a data race: the compiler is free
    /// to cache, reorder or tear it. Atomics only hold integers, so we store the
    /// Float's bit pattern.
    private let targetBits: UnsafeAtomic<UInt32>

    /// The gain applied at the end of the previous buffer (audio thread only).
    private var current: Float

    /// Set by the audio thread the first time the tap delivers anything but
    /// silence (see `hasHeardSound`).
    private let heardBits = UnsafeAtomic<Bool>.create(false)

    let layout: RenderLayout

    init(gain: Float, layout: RenderLayout) {
        targetBits = .create(gain.bitPattern)
        // Start at the requested level. Starting at 1.0 would ramp down from full
        // volume across the very first buffer — a short blip of loud audio.
        current = gain
        self.layout = layout
    }

    deinit {
        targetBits.destroy()
        heardBits.destroy()
    }

    /// 0.0 = silent, 1.0 = unchanged. Safe to set from any thread.
    var targetGain: Float {
        // Relaxed ordering is enough: the gain is a single value, and no other
        // memory is published along with it.
        get { Float(bitPattern: targetBits.load(ordering: .relaxed)) }
        set { targetBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    /// True once the tap has delivered real sound. Without the audio-recording
    /// permission macOS doesn't report an error, it just hands over silence, so
    /// this is the only way to tell that we're allowed to hear the app.
    var hasHeardSound: Bool { heardBits.load(ordering: .relaxed) }

    /// Called by Core Audio for every buffer.
    func render(from input: UnsafePointer<AudioBufferList>, to output: UnsafeMutablePointer<AudioBufferList>) {
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputBuffers = UnsafeMutableAudioBufferListPointer(output)
        let source = StereoSource(inputBuffers, tapBuffers: layout.tapBuffers)
        let end = targetGain

        // Only until the first sound arrives; after that it's one atomic read.
        if let source, !hasHeardSound, source.containsSound {
            heardBits.store(true, ordering: .relaxed)
        }

        var firstChannel = 0   // index of this buffer's first channel, counted across all output buffers
        for buffer in outputBuffers {
            let channels = Int(buffer.mNumberChannels)
            defer { firstChannel += channels }
            guard channels > 0, let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let frames = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)

            // Start from silence: extra channels (e.g. the rest of an 8-channel
            // HDMI output) stay silent, and so does anything the tap can't fill.
            samples.update(repeating: 0, count: frames * channels)
            guard let source else { continue }

            let ramp = GainRamp(from: current, to: end, frameCount: frames)
            for channel in 0..<channels {
                let outputChannel = firstChannel + channel
                let isLeft = outputChannel == layout.left
                let isRight = outputChannel == layout.right
                guard isLeft || isRight else { continue }

                for frame in 0..<min(frames, source.frames) {
                    // Both sides land on the same channel only for a mono output: mix them.
                    let value = isLeft && isRight
                        ? (source.left(frame) + source.right(frame)) * 0.5
                        : isLeft ? source.left(frame) : source.right(frame)
                    samples[frame * channels + channel] = value * ramp.gain(atFrame: frame)
                }
            }
        }

        current = end
    }
}

/// Where the renderer finds the tap's audio and where it puts it. Worked out
/// once, before any audio flows, from the aggregate device's streams.
struct RenderLayout: Equatable {
    /// The input buffers that hold the tap's audio. The aggregate device lists the
    /// output device's own inputs first (say, the AirPods microphone) and the tap
    /// after them, so the tap's buffers are always the last ones.
    let tapBuffers: Range<Int>

    /// The output channels (0-based, counted across all output buffers) that get
    /// the left and right signal. Every other channel gets silence. Both on the
    /// same channel means a mono output, which gets the two mixed.
    let left: Int
    let right: Int

    /// - Parameters:
    ///   - deviceInputStreams: input streams of the real output device (its microphone, if any).
    ///   - aggregateInputStreams: input streams of the aggregate device (the above plus the tap's).
    ///   - outputChannels: total output channels of the device.
    ///   - preferredStereo: the device's speaker pair from Audio MIDI Setup (1-based), usually [1, 2].
    init?(deviceInputStreams: Int, aggregateInputStreams: Int, outputChannels: Int, preferredStereo: [UInt32]) {
        guard aggregateInputStreams > deviceInputStreams, outputChannels > 0 else { return nil }
        tapBuffers = deviceInputStreams..<aggregateInputStreams

        if outputChannels == 1 {
            (left, right) = (0, 0)
        } else if preferredStereo.count == 2,
                  let l = preferredStereo.first, let r = preferredStereo.last,
                  (1...outputChannels).contains(Int(l)), (1...outputChannels).contains(Int(r)) {
            // Usually channels 1 and 2, but an audio interface may have its
            // speakers on, say, outputs 3 and 4.
            (left, right) = (Int(l) - 1, Int(r) - 1)
        } else {
            (left, right) = (0, 1)
        }
    }

    init(tapBuffers: Range<Int>, left: Int, right: Int) {
        self.tapBuffers = tapBuffers
        self.left = left
        self.right = right
    }
}

/// The left and right channels of the tap's audio, wherever they are in the
/// input buffers. A mono tap supplies the same channel for both sides.
private struct StereoSource {
    private var leftSamples: UnsafePointer<Float>
    private var rightSamples: UnsafePointer<Float>
    private var leftStride = 1
    private var rightStride = 1
    private(set) var frames = 0

    /// Returns nil if the tap delivered no audio this time.
    init?(_ buffers: UnsafeMutableAudioBufferListPointer, tapBuffers: Range<Int>) {
        // Walk the tap's channels in order and keep the first two. No arrays:
        // this runs on the audio thread, so nothing may allocate.
        var found = 0
        var first: (UnsafePointer<Float>, Int)?
        var second: (UnsafePointer<Float>, Int)?
        var frames = Int.max

        for index in tapBuffers where index < buffers.count && found < 2 {
            let buffer = buffers[index]
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            frames = min(frames, Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size))

            for channel in 0..<min(channels, 2 - found) {
                let entry = (UnsafePointer(data + channel), channels)   // channel start, and the step between frames
                if found == 0 { first = entry } else { second = entry }
                found += 1
            }
        }

        guard let first else { return nil }
        (leftSamples, leftStride) = first
        (rightSamples, rightStride) = second ?? first
        self.frames = frames
    }

    func left(_ frame: Int) -> Float { leftSamples[frame * leftStride] }
    func right(_ frame: Int) -> Float { rightSamples[frame * rightStride] }

    /// True if any sample isn't exactly zero.
    var containsSound: Bool {
        for frame in 0..<frames where left(frame) != 0 || right(frame) != 0 { return true }
        return false
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
