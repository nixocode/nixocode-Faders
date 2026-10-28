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
///      the output, multiplied by our volume (see `TapRenderer`).
///
///     App ──► Process tap ──► [ × volume ] ──► Speakers
///
/// We only create a tap once the user moves a slider away from 100%, so apps you
/// never touch are left completely alone.
final class AppVolumeTap {

    let processObjectIDs: [AudioObjectID]

    /// 0.0 = silent, 1.0 = the app's normal level.
    var volume: Float {
        didSet { renderer?.targetGain = min(max(volume, 0), 1) }
    }

    private var renderer: TapRenderer?
    private var tapID = AudioObjectID.unknown
    private let tapUUID = UUID()
    private var aggregateDeviceID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?

    private static let log = Logger(subsystem: "Faders", category: "AppVolumeTap")

    /// Starts routing the app's audio through us. Returns nil if macOS refused
    /// (most commonly because the user denied the audio-capture permission).
    init?(appName: String, processObjectIDs: [AudioObjectID], output: OutputDevice, volume: Float) {
        self.processObjectIDs = processObjectIDs
        self.volume = volume

        do {
            try createTap(appName: appName)
            try createAggregateDevice(appName: appName, output: output)
            let layout = try readLayout(appName: appName, output: output)
            let renderer = TapRenderer(gain: min(max(volume, 0), 1), layout: layout)
            self.renderer = renderer
            try startRendering(with: renderer)
        } catch {
            Self.log.error("Could not control \(appName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            stop()
            return nil
        }
    }

    deinit { stop() }

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
            // The aggregate runs on the output's clock and at its sample rate, and
            // with drift compensation on, Core Audio resamples the tap to match.
            // Measured on macOS 27 with a 48 kHz tap on 44.1 kHz speakers: 512 tap
            // frames arrive with every 512 output frames, and the output's rate can
            // even change mid-playback. So the renderer never sees two rates.
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

    /// Works out where the tap's audio arrives and where it should go, and checks
    /// that both sides use float samples (the renderer's only format).
    ///
    /// If the output device has a microphone (AirPods, USB headsets), the
    /// aggregate device includes its input streams ahead of the tap's, and keeps
    /// them running: neither `kAudioDevicePropertyIOProcStreamUsage` nor
    /// `kAudioSubDeviceInputChannelsKey` switches them off (both tried on
    /// macOS 27). The renderer simply never reads them.
    private func readLayout(appName: String, output: OutputDevice) throws -> RenderLayout {
        let tapFormat = tapID.read(kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
        let deviceInputs = output.id.streamFormats(scope: kAudioObjectPropertyScopeInput)
        let inputs = aggregateDeviceID.streamFormats(scope: kAudioObjectPropertyScopeInput)
        let outputs = aggregateDeviceID.streamFormats(scope: kAudioObjectPropertyScopeOutput)
        let preferredStereo = output.id.readArray(
            kAudioDevicePropertyPreferredChannelsForStereo,
            scope: kAudioObjectPropertyScopeOutput,
            defaultValue: UInt32(0)
        )

        // Note: the tap's input stream reports the tap's own rate (e.g. 48 kHz) even
        // though the data it delivers has already been resampled to the output's.
        Self.log.info("""
            \(appName, privacy: .public): tap \(tapFormat?.summary ?? "unknown", privacy: .public); \
            inputs [\(inputs.map(\.summary).joined(separator: " | "), privacy: .public)] \
            (first \(deviceInputs.count) belong to the device); \
            outputs [\(outputs.map(\.summary).joined(separator: " | "), privacy: .public)]; \
            stereo pair \(preferredStereo, privacy: .public)
            """)

        guard let layout = RenderLayout(
            deviceInputStreams: deviceInputs.count,
            aggregateInputStreams: inputs.count,
            outputChannels: outputs.reduce(0) { $0 + Int($1.mChannelsPerFrame) },
            preferredStereo: preferredStereo
        ) else {
            throw TapError(step: "find the tap's audio (\(inputs.count) inputs, \(outputs.count) outputs)", status: noErr)
        }

        let tapStreams = inputs[layout.tapBuffers]
        guard tapStreams.allSatisfy(\.isFloat32), outputs.allSatisfy(\.isFloat32) else {
            throw TapError(step: "use this audio format (\(outputs.first?.summary ?? "no output"))", status: noErr)
        }
        return layout
    }

    private func startRendering(with renderer: TapRenderer) throws {
        // Capture only the renderer, never `self`, on the audio thread.
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
        var errorDescription: String? {
            status == noErr ? "Failed to \(step)" : "Failed to \(step) (OSStatus \(status))"
        }
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw TapError(step: step, status: status) }
    }
}
