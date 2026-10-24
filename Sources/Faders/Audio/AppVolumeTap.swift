import CoreAudio
import Foundation
import os

/// Controls the volume of one app.
///
/// macOS has no built-in per-app volume, so we do what the system allows since
/// macOS 14.2:
///
///   1. **Tap** the app's audio with a Core Audio *process tap*. The tap is created
///      "muted when tapped", so the app's sound no longer goes straight to the speakers.
///   2. Wrap the tap in a private **aggregate device** that also contains the real
///      output (your speakers/headphones).
///   3. Run a tiny **render callback** on that device that copies the tapped audio to
///      the output, multiplied by our volume.
///
///     App ──► Process tap ──► [ × volume ] ──► Speakers
///
/// We only create a tap once the user moves a slider away from 100%, so apps you
/// never touch are left completely alone.
final class AppVolumeTap {

    let processObjectIDs: [AudioObjectID]
    private let gain = Gain()

    private var tapID = AudioObjectID.unknown
    private let tapUUID = UUID()
    private var aggregateDeviceID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?

    private static let log = Logger(subsystem: "Faders", category: "AppVolumeTap")

    /// Starts routing the app's audio through us. Returns nil if macOS refused
    /// (most commonly because the user denied the audio-capture permission).
    init?(appName: String, processObjectIDs: [AudioObjectID], output: OutputDevice, volume: Float) {
        self.processObjectIDs = processObjectIDs
        gain.target = volume

        do {
            try createTap(appName: appName)
            try createAggregateDevice(appName: appName, output: output)
            try startRendering()
        } catch {
            Self.log.error("Could not control \(appName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            stop()
            return nil
        }
    }

    deinit { stop() }

    /// 0.0 = silent, 1.0 = the app's normal level. Safe to call from the main thread.
    var volume: Float {
        get { gain.target }
        set { gain.target = min(max(newValue, 0), 1) }
    }

    // MARK: - Setup steps

    private func createTap(appName: String) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = tapUUID
        description.name = "Faders – \(appName)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped   // we become the only path to the speakers

        try check(AudioHardwareCreateProcessTap(description, &tapID), "create process tap")
    }

    private func createAggregateDevice(appName: String, output: OutputDevice) throws {
        let tapUID = tapUUID.uuidString

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Faders – \(appName)",
            kAudioAggregateDeviceUIDKey: "com.faders.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,      // hidden from Sound settings
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: output.uid],
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true],
            ],
        ]

        try check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateDeviceID),
            "create aggregate device"
        )
    }

    private func startRendering() throws {
        let gain = self.gain   // capture only the gain, never `self`, on the audio thread
        let queue = DispatchQueue(label: "Faders.render", qos: .userInteractive)

        try check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, queue) { _, input, _, output, _ in
                gain.render(from: input, to: output)
            },
            "create render callback"
        )
        try check(AudioDeviceStart(aggregateDeviceID, ioProcID), "start device")
    }

    // MARK: - Teardown (reverse order of setup)

    func stop() {
        if aggregateDeviceID.isValid, let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        ioProcID = nil

        if aggregateDeviceID.isValid {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = .unknown
        }
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)   // the app's normal audio path comes back
            tapID = .unknown
        }
    }

    // MARK: - Errors

    private struct TapError: LocalizedError {
        let step: String
        let status: OSStatus
        var errorDescription: String? { "Failed to \(step) (OSStatus \(status))" }
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw TapError(step: step, status: status) }
    }
}

// MARK: - The audio-thread part

/// Applies volume to audio buffers.
///
/// `render` runs on Core Audio's real-time thread, so it must never allocate,
/// lock, log or wait. It only reads `target` and does simple math.
private final class Gain: @unchecked Sendable {

    /// Set from the UI. A single aligned Float is read/written atomically on
    /// Apple silicon and Intel, which is all we need here.
    var target: Float = 1

    /// The level actually applied last time (only touched on the audio thread).
    private var current: Float = 1

    func render(from input: UnsafePointer<AudioBufferList>, to output: UnsafeMutablePointer<AudioBufferList>) {
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputBuffers = UnsafeMutableAudioBufferListPointer(output)

        // Glide from the previous level to the new one across this buffer,
        // so dragging the slider never causes clicks.
        let start = current
        let end = target

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
            let step = count > 0 ? (end - start) / Float(count) : 0

            for i in 0..<count {
                outSamples[i] = inSamples[i] * (start + step * Float(i))
            }
            if count < outCount {
                (outSamples + count).update(repeating: 0, count: outCount - count)
            }
        }

        current = end
    }
}
