import AppKit
import CoreAudio
import Observation
import ServiceManagement
import os

/// The brain of the app: knows which apps are playing, what volume each one
/// should have, and keeps the audio taps in sync with the sliders.
///
/// Everything here runs on the main thread. The only code that runs on the
/// audio thread lives in `AppVolumeTap`.
///
/// **About the purple dot.** While Faders reads an app's audio tap, macOS shows a
/// purple privacy dot in the menu bar. What we measured on macOS 27 (Oct 2026):
///
///   • The dot follows *reading* the tap. A tap that exists but isn't being read
///     shows no dot.
///   • A tap made "muted when tapped" lets the app play at full volume whenever
///     it isn't read. A "muted" tap keeps the app silent.
///   • Creating a tap and its aggregate device takes ~50 ms on built-in speakers
///     and ~400 ms on AirPods. Faders 1.1 destroyed taps after 3 s of silence and
///     re-created them on resume, so that much audio played at full volume.
///
/// So every app with a custom level keeps a muted tap for as long as it runs, and
/// we only *read* it while the app is playing (and for a few seconds after):
///
///   • idle                      → muted tap, not read: no dot, no sound
///   • starts playing            → start reading: the first moments are silent
///                                 instead of loud (~150 ms on Bluetooth)
///   • quiet for a few seconds   → stop reading: the dot turns off
///   • turned all the way down   → never read at all
///
/// **If we're not allowed to listen.** Without the audio-recording permission,
/// macOS reports no error: every call succeeds and the tap simply delivers
/// silence. A muted tap would then keep its app quiet for good. So until some
/// tap has delivered real sound, we check: if an app plays for several seconds
/// and its tap hears nothing, we let the app go (it plays normally again) and
/// show the permission hint. See `checkAccess`.
@MainActor
@Observable
final class MixerModel {

    // MARK: State the UI shows

    /// The current speakers/headphones, or nil if there are none.
    private(set) var output: OutputDevice?
    private(set) var outputVolume: Float = 0
    private(set) var outputMuted = false

    /// Apps listed in the mixer.
    private(set) var apps: [AudioApp] = []

    /// True when macOS refused to let us control an app — almost always because
    /// the audio-recording permission is off. The UI shows a hint.
    var permissionProblem: Bool { !failedAppIDs.isEmpty }

    /// True if any app is set to something other than 100% (enables "Reset All").
    var hasCustomLevels: Bool { settings.values.contains { $0.isCustom } }

    /// Whether Faders starts when you log in (System Settings → General → Login Items).
    private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled

    /// Set by the panel while it's on screen. Rows then stay put when their app
    /// goes quiet (see `refresh`), and drop out once the panel closes.
    @ObservationIgnored var isPanelOpen = false {
        didSet {
            if isPanelOpen {
                readOpensAtLogin()   // it may have changed in System Settings
            } else {
                refresh()
            }
        }
    }

    // MARK: Tuning

    /// How long we keep reading a tap after its app goes quiet. Long enough that
    /// skipping a track doesn't flicker the purple dot.
    private let stopReadingAfterSilence: TimeInterval = 3

    /// How long an app must play into a silent tap before we decide macOS isn't
    /// letting us hear it. Generous, so a quiet intro or a slow click on the
    /// permission prompt isn't mistaken for a refusal.
    private let silenceMeansNoAccess: TimeInterval = 8

    // MARK: Private state

    /// Per-app settings, remembered between launches (keyed by `AudioApp.id`).
    private var settings: [String: AppSetting] = AppSetting.loadAll()

    /// Taps, keyed by `AudioApp.id`: one for every running app with a custom level.
    @ObservationIgnored private var taps: [String: AppVolumeTap] = [:]

    /// When we last heard each app play.
    @ObservationIgnored private var lastPlayed: [String: Date] = [:]

    /// Apps we failed to control; we don't retry them until the user does.
    private var failedAppIDs: Set<String> = []

    /// True once any tap has delivered real sound: proof that macOS lets us
    /// hear app audio, so silence from then on is just silence.
    @ObservationIgnored private var hasAudioAccess = false

    /// Apps whose tap we're currently checking for sound (see `checkAccess`).
    @ObservationIgnored private var accessChecks: Set<String> = []

    private static let log = Logger(subsystem: "Faders", category: "Mixer")

    /// Tells us the moment an app starts or stops playing (see `ProcessMonitor`).
    @ObservationIgnored private var processMonitor: ProcessMonitor?

    /// Tells us when the default output device changes (AirPods connected…).
    @ObservationIgnored private var outputDeviceListener: PropertyListener?

    /// Tell us when the current device's volume or mute changes — from the volume
    /// keys, Control Center, or another app. Replaced whenever the device changes.
    @ObservationIgnored private var outputLevelListeners: [PropertyListener] = []

    /// True while the user drags the output slider. The device reports every
    /// change we make back to us; applying those echoes mid-drag would make the
    /// knob stutter, so we hold them until the drag ends.
    @ObservationIgnored private var isAdjustingOutputVolume = false

    init() {
        outputDeviceListener = PropertyListener(.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            self?.outputDeviceChanged()
        }
        processMonitor = ProcessMonitor { [weak self] in self?.refresh() }
        outputDeviceChanged()   // also does the first refresh
    }

    // MARK: - Reading per-app settings

    func volume(for app: AudioApp) -> Float { settings[app.id]?.volume ?? 1 }
    func isMuted(_ app: AudioApp) -> Bool { settings[app.id]?.isMuted ?? false }

    // MARK: - User actions

    func setVolume(_ volume: Float, for app: AudioApp) {
        settings[app.id, default: AppSetting()].volume = volume
        // Moving the slider up un-mutes, just like on Windows.
        if volume > 0 { settings[app.id]?.isMuted = false }
        userChangedSetting(of: app)
    }

    func toggleMute(_ app: AudioApp) {
        settings[app.id, default: AppSetting()].isMuted.toggle()
        userChangedSetting(of: app)
    }

    func setOutputVolume(_ volume: Float) {
        output?.volume = volume
        outputVolume = volume
        if volume > 0, outputMuted { setOutputMuted(false) }
    }

    func setOutputMuted(_ muted: Bool) {
        output?.isMuted = muted
        outputMuted = muted
    }

    /// Called when a drag on the output slider starts and ends.
    func setAdjustingOutputVolume(_ adjusting: Bool) {
        isAdjustingOutputVolume = adjusting
        if !adjusting { readOutputLevels() }   // settle on what the device actually chose
    }

    func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Self.log.error("Open at Login: \(error.localizedDescription, privacy: .public)")
        }
        // macOS may want the user to approve the login item first.
        if enabled, SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        readOpensAtLogin()   // show the real state, whatever happened
    }

    private func readOpensAtLogin() {
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Puts every app back to 100% and removes all taps.
    func resetAll() {
        settings.removeAll()
        AppSetting.saveAll(settings)
        failedAppIDs.removeAll()
        releaseAllTaps()
    }

    private func userChangedSetting(of app: AudioApp) {
        AppSetting.saveAll(settings)
        failedAppIDs.remove(app.id)    // the user is trying again
        syncTap(for: app)
    }

    // MARK: - Keeping everything in sync

    /// The default output device changed (or we just launched).
    private func outputDeviceChanged() {
        let newOutput = OutputDevice.current()
        guard newOutput != output || outputLevelListeners.isEmpty else { return }
        output = newOutput

        // Listen to the new device's volume and mute (the old listeners go away
        // with the array they're replaced in).
        outputLevelListeners = newOutput?.observeLevels { [weak self] in self?.readOutputLevels() } ?? []
        readOutputLevels()

        refresh()   // moves every tap over to the new device
    }

    private func readOutputLevels() {
        if !isAdjustingOutputVolume { outputVolume = output?.volume ?? 0 }
        outputMuted = output?.isMuted ?? false
    }

    private func refresh() {
        // Show apps that are playing, plus apps with a custom level so you can
        // still adjust them while they're paused. While the panel is open, rows
        // also stay when their app goes quiet (a pause, the gap between two
        // songs): a row shouldn't vanish from under the pointer, and the panel
        // can't animate its height, so it would jump.
        let now = Date()
        let scanned = AudioAppScanner.scan()
        for app in scanned where app.isPlaying { lastPlayed[app.id] = now }

        let listed = Set(apps.map(\.id))
        let visible = scanned.filter {
            $0.isPlaying || settings[$0.id]?.isCustom == true || (isPanelOpen && listed.contains($0.id))
        }
        if visible != apps { apps = visible }

        // Apps that quit take their taps with them.
        let running = Set(scanned.map(\.id))
        for id in taps.keys where !running.contains(id) { releaseTap(for: id) }

        for app in scanned { syncTap(for: app) }
    }

    /// Makes an app's tap match its setting and whether it's playing.
    private func syncTap(for app: AudioApp) {
        let setting = settings[app.id] ?? AppSetting()
        guard setting.isCustom, let output else {
            releaseTap(for: app.id)   // back to 100% (or no output): leave the app alone
            return
        }

        // A tap covers a fixed set of processes on one device. If the app started
        // a new helper or the output changed, build a new tap *before* letting go
        // of the old one, so the app never slips out at full volume in between.
        var replacedTap: AppVolumeTap?
        if let tap = taps[app.id], tap.processObjectIDs == app.processObjectIDs, tap.outputUID == output.uid {
            // Up to date.
        } else {
            guard !failedAppIDs.contains(app.id) else { return }
            guard let newTap = AppVolumeTap(
                appName: app.name,
                processObjectIDs: app.processObjectIDs,
                output: output,
                volume: setting.effectiveVolume
            ) else {
                giveUp(on: app.id)
                return
            }
            replacedTap = taps[app.id]
            taps[app.id] = newTap
        }
        guard let tap = taps[app.id] else { return }
        defer { replacedTap?.destroy() }

        tap.volume = setting.effectiveVolume

        // Read the tap only while there's something to hear.
        let silentFor = Date().timeIntervalSince(lastPlayed[app.id] ?? .distantPast)
        let shouldRead = setting.effectiveVolume > 0 && silentFor < stopReadingAfterSilence
        if shouldRead {
            do {
                try tap.startIO()
            } catch {
                Self.log.error("Could not start \(app.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                giveUp(on: app.id)   // better to hear the app at 100% than not at all
                return
            }
            if app.isPlaying { checkAccess(app, tap: tap) }
        } else {
            tap.stopIO()
        }

        if shouldRead && !app.isPlaying {
            // Nothing will tell us when the silence has lasted long enough, so
            // come back then. (The main queue keeps running during slider drags,
            // unlike a default-mode Timer.)
            DispatchQueue.main.asyncAfter(deadline: .now() + stopReadingAfterSilence - silentFor + 0.1) { [weak self] in
                self?.refresh()
            }
        }
    }

    /// Makes sure the tap actually hears the app (see "If we're not allowed to
    /// listen" above). Runs until the first sound arrives, then never again.
    private func checkAccess(_ app: AudioApp, tap: AppVolumeTap) {
        guard !hasAudioAccess, !accessChecks.contains(app.id) else { return }
        accessChecks.insert(app.id)

        DispatchQueue.main.asyncAfter(deadline: .now() + silenceMeansNoAccess) { [weak self, weak tap] in
            guard let self else { return }
            self.accessChecks.remove(app.id)
            guard let tap, self.taps[app.id] === tap else { return }   // replaced or released meanwhile

            if tap.hasHeardSound {
                self.hasAudioAccess = true
            } else if tap.isRunning, AudioAppScanner.isPlaying(tap.processObjectIDs) {
                Self.log.error("\(app.name, privacy: .public) played for \(Int(self.silenceMeansNoAccess)) s and Faders heard only silence: no permission to hear app audio?")
                self.giveUp(on: app.id)   // the app plays normally again; the panel shows the hint
            }
            // Otherwise the app stopped playing before we could tell; we check
            // again the next time it plays.
        }
    }

    /// Stops trying to control an app until the user touches its slider again.
    private func giveUp(on id: String) {
        releaseTap(for: id)
        failedAppIDs.insert(id)
    }

    private func releaseTap(for id: String) {
        taps[id]?.destroy()
        taps[id] = nil
    }

    private func releaseAllTaps() {
        taps.values.forEach { $0.destroy() }
        taps.removeAll()
    }
}

// MARK: - Remembered settings

/// What the user chose for one app. Saved in UserDefaults so Spotify stays at
/// 40% tomorrow too.
struct AppSetting: Codable {
    var volume: Float = 1
    var isMuted = false

    /// The level actually applied to the audio.
    var effectiveVolume: Float { isMuted ? 0 : volume }

    /// Anything other than "100%, not muted" needs a tap to take effect.
    var isCustom: Bool { effectiveVolume < 1 }

    private static let defaultsKey = "appSettings"

    static func loadAll() -> [String: AppSetting] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode([String: AppSetting].self, from: data)
        else { return [:] }
        return settings
    }

    static func saveAll(_ settings: [String: AppSetting]) {
        let custom = settings.filter { $0.value.isCustom }
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
