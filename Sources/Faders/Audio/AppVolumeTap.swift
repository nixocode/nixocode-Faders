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
    private let renderer: TapRenderer

    private var tapID = AudioObjectID.unknown
    private let tapUUID = UUID()
    private var aggregateDeviceID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?

    private static let log = Logger(subsystem: "Faders", category: "AppVolumeTap")

    /// Starts routing the app's audio through us. Returns nil if macOS refused
    /// (most commonly because the user denied the audio-capture permission).
    init?(appName: String, processObjectIDs: [AudioObjectID], output: OutputDevice, volume: Float) {
        self.processObjectIDs = processObjectIDs
        renderer = TapRenderer(gain: min(max(volume, 0), 1))

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
        get { renderer.targetGain }
        set { renderer.targetGain = min(max(newValue, 0), 1) }
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
        let renderer = self.renderer   // capture only the renderer, never `self`, on the audio thread
        let queue = DispatchQueue(label: "Faders.render", qos: .userInteractive)

        try check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, queue) { _, input, _, output, _ in
                renderer.render(from: input, to: output)
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
