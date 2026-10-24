import AppKit
import CoreAudio
import Observation

/// The brain of the app: knows which apps are playing, what volume each one
/// should have, and keeps the audio taps in sync with the sliders.
///
/// Everything here runs on the main thread. The only code that runs on the
/// audio thread lives in `AppVolumeTap`.
///
/// **About the purple dot.** While Faders controls an app (a "tap" is active),
/// macOS shows a purple privacy dot in the menu bar. To keep it off as much as
/// possible we only hold a tap while the app is actually playing sound:
///
///   • an app with a custom level starts playing → tap it right away
///   • it goes quiet for a few seconds          → let go of it (dot turns off)
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
    private(set) var permissionProblem = false

    /// True if any app is set to something other than 100% (enables "Reset All").
    var hasCustomLevels: Bool { settings.values.contains { $0.isCustom } }

    // MARK: Tuning

    /// How long an app must be silent before we let go of it.
    private let releaseAfterSilence: TimeInterval = 3

    // MARK: Private state

    /// Per-app settings, remembered between launches (keyed by `AudioApp.id`).
    private var settings: [String: AppSetting] = AppSetting.loadAll()

    /// Active taps, keyed by `AudioApp.id`.
    @ObservationIgnored private var taps: [String: AppVolumeTap] = [:]

    /// When we last heard each app play (or the user touched its slider).
    @ObservationIgnored private var lastActive: [String: Date] = [:]

    /// Apps we failed to control; we don't retry them every second.
    @ObservationIgnored private var failedAppIDs: Set<String> = []

    @ObservationIgnored private var timers: [Timer] = []

    init() {
        refresh()

        // Full refresh once a second: output device, app list, tap housekeeping.
        timers.append(Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })

        // Quick check a few times a second: did a turned-down app start playing?
        // This is what keeps the "released while silent" approach from letting
        // much audio through at full volume when playback resumes.
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.catchResumedApps() }
        })
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

    /// Puts every app back to 100% and removes all taps.
    func resetAll() {
        settings.removeAll()
        AppSetting.saveAll(settings)
        failedAppIDs.removeAll()
        permissionProblem = false
        releaseAllTaps()
    }

    private func userChangedSetting(of app: AudioApp) {
        AppSetting.saveAll(settings)
        failedAppIDs.remove(app.id)    // the user is trying again
        lastActive[app.id] = Date()    // don't release it while they're dragging
        applySetting(to: app)
    }

    // MARK: - Keeping everything in sync

    private func refresh() {
        // 1. Output device. If it changed (e.g. AirPods connected), every tap is
        //    still pointing at the old one. Release them; step 3 re-creates the
        //    ones still needed against the new device.
        let newOutput = OutputDevice.current()
        if newOutput != output {
            output = newOutput
            releaseAllTaps()
        }
        outputVolume = output?.volume ?? 0
        outputMuted = output?.isMuted ?? false

        // 2. Apps. Show apps that are playing, plus apps with a custom level so
        //    you can still adjust them while they're paused.
        let now = Date()
        let scanned = AudioAppScanner.scan()
        for app in scanned where app.isPlaying { lastActive[app.id] = now }

        let visible = scanned.filter { $0.isPlaying || settings[$0.id]?.isCustom == true || taps[$0.id] != nil }
        if visible != apps { apps = visible }

        // 3. Taps.
        let scannedByID = Dictionary(scanned.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for (id, tap) in taps {
            guard let app = scannedByID[id], app.processObjectIDs == tap.processObjectIDs else {
                // The app quit, or started using different helper processes.
                releaseTap(for: id)
                continue
            }
            let silentFor = now.timeIntervalSince(lastActive[id] ?? .distantPast)
            if !app.isPlaying && silentFor > releaseAfterSilence {
                releaseTap(for: id)   // quiet for a while → let the purple dot turn off
            }
        }

        for app in scanned where app.isPlaying {
            applySetting(to: app)     // playing with a custom level → make sure it's tapped
        }
    }

    /// Runs several times a second, but only looks at apps that have a custom
    /// level and no tap right now — a cheap check.
    private func catchResumedApps() {
        for app in apps where taps[app.id] == nil && settings[app.id]?.isCustom == true {
            if AudioAppScanner.isPlaying(app.processObjectIDs) {
                lastActive[app.id] = Date()
                applySetting(to: app)
            }
        }
    }

    /// Makes the audio match the app's setting: updates or creates its tap.
    private func applySetting(to app: AudioApp) {
        let setting = settings[app.id] ?? AppSetting()

        if let tap = taps[app.id] {
            if setting.isCustom {
                tap.volume = setting.effectiveVolume   // already controlling it: just change the level
            } else {
                releaseTap(for: app.id)                // back to 100%: nothing to do, let go
            }
            return
        }

        guard setting.isCustom, let output, !failedAppIDs.contains(app.id) else { return }

        let tap = AppVolumeTap(
            appName: app.name,
            processObjectIDs: app.processObjectIDs,
            output: output,
            volume: setting.effectiveVolume
        )
        taps[app.id] = tap
        if tap == nil { failedAppIDs.insert(app.id) }
        permissionProblem = !failedAppIDs.isEmpty
    }

    private func releaseTap(for id: String) {
        taps[id]?.stop()
        taps[id] = nil
    }

    private func releaseAllTaps() {
        taps.values.forEach { $0.stop() }
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
