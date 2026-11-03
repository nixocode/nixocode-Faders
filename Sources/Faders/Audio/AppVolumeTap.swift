import CoreAudio
import Foundation
import os

/// Controls the volume of one app.
///
/// macOS has no built-in per-app volume, so we do what the system allows since
/// macOS 14.2:
///
///   1. **Tap** the app's audio with a Core Audio *process tap*. The tap is created
///      "muted", so the app's sound no longer goes straight to the speakers.
///   2. Wrap the tap in a private **aggregate device** that also contains the real
///      output (your speakers/headphones).
///   3. Run a tiny **render callback** on that device that copies the tapped audio to
///      the output, multiplied by our volume (see `TapRenderer`).
///
///     App ──► Process tap ──► [ × volume ] ──► Speakers
///
/// We only create a tap once the user moves a slider away from 100%, so apps you
/// never touch are left completely alone.
///
/// **Reading vs. existing.** A new tap starts idle: the app is muted, but nothing
/// reads the tap yet. `startIO()` starts the render callback (audio flows, at our
/// volume) and `stopIO()` stops it again (the app goes back to silent). macOS's
/// purple privacy dot follows the *reading*, not the tap — see `MixerModel` for
/// how that's used and what was measured.
final class AppVolumeTap {

    let processObjectIDs: [AudioObjectID]

    /// The output device this tap plays to. A different default output means a new tap.
    let outputUID: String

    /// True while the render callback runs (and the purple dot shows).
    private(set) var isRunning = false

    /// The slider level: 0.0 = silent, 1.0 = the app's normal level.
    var volume: Float {
        didSet { renderer?.targetGain = Self.gain(forLevel: volume) }
    }

    /// True once real sound has come through the tap (see `TapRenderer.hasHeardSound`).
    var hasHeardSound: Bool { renderer?.hasHeardSound ?? false }

    /// Turns a slider level into the factor each sample is multiplied by.
    ///
    /// We hear loudness on a roughly logarithmic scale, so multiplying by the
    /// slider level directly puts nearly all the audible change at the bottom of
    /// the slider: at 50% an app still sounds about two-thirds as loud. Squaring
    /// spreads it out: 50% becomes a quarter of the signal (−12 dB), which sounds
    /// a little under half as loud, and the slider feels even all the way, like
    /// the system volume slider above it.
    static func gain(forLevel level: Float) -> Float {
        let level = min(max(level, 0), 1)
        return level * level
    }

    private var renderer: TapRenderer?
    private var tapID = AudioObjectID.unknown
    private let tapUUID = UUID()
    private var aggregateDeviceID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?

    private static let log = Logger(subsystem: "Faders", category: "AppVolumeTap")

    private let appName: String

    /// Takes over the app's audio: from now on it's muted, until `startIO()` plays
    /// it through us. Returns nil if Core Audio refused.
    init?(appName: String, processObjectIDs: [AudioObjectID], output: OutputDevice, volume: Float) {
        self.appName = appName
        self.processObjectIDs = processObjectIDs
        self.outputUID = output.uid
        self.volume = volume

        do {
            try createTap()
            try createAggregateDevice(output: output)
            try waitUntilReady(output: output)
            let layout = try readLayout(output: output)
            let renderer = TapRenderer(gain: Self.gain(forLevel: volume), layout: layout)
            self.renderer = renderer
            try createRenderCallback(with: renderer)
        } catch {
            Self.log.error("Could not control \(appName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            destroy()
            return nil
        }
    }

    deinit { destroy() }

    // MARK: - Reading the tap

    /// Starts playing the app through us, at our volume. Throws if Core Audio
    /// refuses — most commonly because the audio-capture permission was denied.
    func startIO() throws {
        guard !isRunning, let ioProcID else { return }
        try check(AudioDeviceStart(aggregateDeviceID, ioProcID), "start reading \(appName)")
        isRunning = true
    }

    /// Stops reading the tap. The app stays muted, and the purple dot goes away.
    func stopIO() {
        guard isRunning, let ioProcID else { return }
        AudioDeviceStop(aggregateDeviceID, ioProcID)
        isRunning = false
    }

    // MARK: - Setup steps

    private func createTap() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = tapUUID
        description.name = "Faders – \(appName)"
        description.isPrivate = true
        // `.muted`, not `.mutedWhenTapped`: the latter lets the app's audio through
        // at full volume whenever nobody reads the tap, which is exactly when the
        // render callback is stopped.
        description.muteBehavior = .muted

        try check(AudioHardwareCreateProcessTap(description, &tapID), "create process tap")
    }

    private func createAggregateDevice(output: OutputDevice) throws {
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

    /// Core Audio builds a new aggregate device in the background, so it may not be
    /// usable the moment `AudioHardwareCreateAggregateDevice` returns. Starting it
    /// too early can fail, or start a device whose streams don't exist yet (which
    /// would also make `readLayout` see the wrong streams). So wait — briefly,
    /// it's normally ready at once — until it's alive and both the tap's input
    /// and the output streams are there.
    private func waitUntilReady(output: OutputDevice, timeout: TimeInterval = 1) throws {
        let deviceInputs = output.id.streamFormats(scope: kAudioObjectPropertyScopeInput).count
        let start = Date()
        var alive = false, inputs = 0, outputs = 0

        repeat {
            alive = aggregateDeviceID.read(kAudioDevicePropertyDeviceIsAlive, defaultValue: UInt32(0)) == 1
            inputs = aggregateDeviceID.streamFormats(scope: kAudioObjectPropertyScopeInput).count
            outputs = aggregateDeviceID.streamFormats(scope: kAudioObjectPropertyScopeOutput).count
            if alive && inputs > deviceInputs && outputs > 0 {
                let waited = Int(Date().timeIntervalSince(start) * 1000)
                if waited > 0 { Self.log.info("Aggregate device ready after \(waited) ms") }
                return
            }
            Thread.sleep(forTimeInterval: 0.005)
        } while Date().timeIntervalSince(start) < timeout

        throw TapError(
            step: "get the aggregate device ready within \(timeout) s " +
                "(alive: \(alive), input streams: \(inputs), output streams: \(outputs))",
            status: noErr
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
    private func readLayout(output: OutputDevice) throws -> RenderLayout {
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
            \(self.appName, privacy: .public): tap \(tapFormat?.summary ?? "unknown", privacy: .public); \
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

    private func createRenderCallback(with renderer: TapRenderer) throws {
        // Capture only the renderer, never `self`, on the audio thread.
        let queue = DispatchQueue(label: "Faders.render", qos: .userInteractive)

        try check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, queue) { _, input, _, output, _ in
                renderer.render(from: input, to: output)
            },
            "create render callback"
        )
    }

    // MARK: - Teardown (reverse order of setup)

    /// Gives the app back its normal audio path (at its own full volume).
    func destroy() {
        stopIO()
        if aggregateDeviceID.isValid, let ioProcID {
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
            status == noErr ? "Failed to \(step)" : "Failed to \(step) (OSStatus \(status)\(codeSuffix))"
        }

        /// Core Audio errors are usually four letters packed into the number
        /// ('nope', '!dev', 'who?'), which is what you search the headers for.
        private var codeSuffix: String {
            let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian, Array.init)
            guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return "" }
            return " '\(String(decoding: bytes, as: UTF8.self))'"
        }
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw TapError(step: step, status: status) }
    }
}
