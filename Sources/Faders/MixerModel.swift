import AppKit
import CoreAudio
import Observation

/// The brain of the app: knows which apps are playing, what volume each one
/// should have, and keeps the audio taps in sync with the sliders.
///
/// Everything here runs on the main thread. The only code that runs on the
/// audio thread lives in `AppVolumeTap`.
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

    // MARK: Private state

    /// Per-app settings, remembered between launches (keyed by `AudioApp.id`).
    private var settings: [String: AppSetting] = AppSetting.loadAll()

    /// Active taps, keyed by `AudioApp.id`. An app only gets one when its
    /// volume is below 100% or it's muted.
    @ObservationIgnored private var taps: [String: AppVolumeTap] = [:]

    /// Apps we failed to control; we don't retry them every second.
    @ObservationIgnored private var failedAppIDs: Set<String> = []

    @ObservationIgnored private var refreshTimer: Timer?

    init() {
        refresh()

        // Poll gently. Simpler and more robust than listening to every
        // process's properties, and invisible in Activity Monitor.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - Reading per-app settings

    func volume(for app: AudioApp) -> Float { settings[app.id]?.volume ?? 1 }
    func isMuted(_ app: AudioApp) -> Bool { settings[app.id]?.isMuted ?? false }

    // MARK: - User actions

    func setVolume(_ volume: Float, for app: AudioApp) {
        settings[app.id, default: AppSetting()].volume = volume
        // Moving the slider up un-mutes, just like on Windows.
        if volume > 0 { settings[app.id]?.isMuted = false }
        AppSetting.saveAll(settings)
        failedAppIDs.remove(app.id)   // the user is trying again
        applySetting(to: app)
    }

    func toggleMute(_ app: AudioApp) {
        settings[app.id, default: AppSetting()].isMuted.toggle()
        AppSetting.saveAll(settings)
        failedAppIDs.remove(app.id)
        applySetting(to: app)
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
        taps.values.forEach { $0.stop() }
        taps.removeAll()
    }

    // MARK: - Keeping everything in sync

    private func refresh() {
        // 1. Output device. If it changed (e.g. headphones plugged in), every tap
        //    is still pointing at the old one, so rebuild them.
        let newOutput = OutputDevice.current()
        if newOutput != output {
            output = newOutput
            rebuildAllTaps()
        }
        outputVolume = output?.volume ?? 0
        outputMuted = output?.isMuted ?? false

        // 2. Apps. Show apps that are playing, plus any app we're currently
        //    controlling (so its row doesn't vanish when a song pauses).
        let scanned = AudioAppScanner.scan()
        let visible = scanned.filter { $0.isPlaying || taps[$0.id] != nil }
        if visible != apps { apps = visible }

        // Apply remembered volumes to apps that just started playing.
        for app in visible where taps[app.id] == nil && !failedAppIDs.contains(app.id) {
            applySetting(to: app)
        }

        // 3. Taps. Drop taps for apps that quit; refresh taps whose app
        //    started using new helper processes.
        let scannedByID = Dictionary(scanned.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, tap) in taps {
            guard let app = scannedByID[id] else {
                tap.stop()
                taps[id] = nil
                continue
            }
            if app.processObjectIDs != tap.processObjectIDs {
                tap.stop()
                taps[id] = nil
                applySetting(to: app)
            }
        }
    }

    /// Makes the audio match the app's setting: creates, updates or removes its tap.
    private func applySetting(to app: AudioApp) {
        let setting = settings[app.id] ?? AppSetting()
        let effectiveVolume = setting.isMuted ? 0 : setting.volume

        if let tap = taps[app.id] {
            // Already controlling this app: just change the level.
            tap.volume = effectiveVolume
        } else if effectiveVolume < 1, let output {
            // First time this app is turned down: start controlling it.
            let tap = AppVolumeTap(
                appName: app.name,
                processObjectIDs: app.processObjectIDs,
                output: output,
                volume: effectiveVolume
            )
            taps[app.id] = tap
            if tap == nil { failedAppIDs.insert(app.id) }
            permissionProblem = !failedAppIDs.isEmpty
        }
    }

    private func rebuildAllTaps() {
        taps.values.forEach { $0.stop() }
        taps.removeAll()
        for app in apps { applySetting(to: app) }
    }
}

// MARK: - Remembered settings

/// What the user chose for one app. Saved in UserDefaults so Spotify stays at
/// 40% tomorrow too.
struct AppSetting: Codable {
    var volume: Float = 1
    var isMuted = false

    private static let defaultsKey = "appSettings"

    static func loadAll() -> [String: AppSetting] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode([String: AppSetting].self, from: data)
        else { return [:] }
        return settings
    }

    static func saveAll(_ settings: [String: AppSetting]) {
        // Only store apps that differ from the default (100%, not muted).
        let changed = settings.filter { $0.value.volume < 1 || $0.value.isMuted }
        if let data = try? JSONEncoder().encode(changed) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
