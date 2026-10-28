import CoreAudio

/// Builds an `AudioBufferList` like the ones Core Audio hands to the render
/// callback, so the renderer can be tested without any audio hardware.
///
///     // One interleaved stereo buffer + one 8-channel interleaved buffer, 4 frames each:
///     let list = BufferListFixture(channelsPerBuffer: [2, 8], frames: 4)
final class BufferListFixture {
    let list: UnsafeMutableAudioBufferListPointer
    let frames: Int
    private var storage: [UnsafeMutablePointer<Float>] = []

    init(channelsPerBuffer: [Int], frames: Int, fill: Float = 0) {
        self.frames = frames
        list = AudioBufferList.allocate(maximumBuffers: channelsPerBuffer.count)
        for (index, channels) in channelsPerBuffer.enumerated() {
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: channels * frames)
            samples.initialize(repeating: fill, count: channels * frames)
            storage.append(samples)
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(channels * frames * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(samples)
            )
        }
    }

    deinit {
        storage.forEach { $0.deallocate() }
        free(list.unsafeMutablePointer)
    }

    var pointer: UnsafeMutablePointer<AudioBufferList> { list.unsafeMutablePointer }

    /// Marks a buffer as unused, the way Core Audio does for a disabled stream.
    func disable(buffer: Int) { list[buffer].mData = nil }

    /// Reads/writes one sample: buffer, channel within that buffer, frame.
    subscript(buffer: Int, channel: Int, frame: Int) -> Float {
        get { sample(buffer, channel, frame).pointee }
        set { sample(buffer, channel, frame).pointee = newValue }
    }

    /// Sets every frame of one channel to `value`.
    func fill(buffer: Int, channel: Int, with value: Float) {
        for frame in 0..<frames { self[buffer, channel, frame] = value }
    }

    private func sample(_ buffer: Int, _ channel: Int, _ frame: Int) -> UnsafeMutablePointer<Float> {
        let channels = Int(list[buffer].mNumberChannels)
        return storage[buffer] + frame * channels + channel
    }
}
