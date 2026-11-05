import CoreAudio

/// Tells the mixer the moment something changes about who's playing: a process
/// starts or stops using audio, or an app starts or stops making sound.
///
/// This replaces polling. A turned-down app that resumes playback is caught
/// within a millisecond or so, instead of on the next timer tick — and unlike a
/// `Timer` in the default run-loop mode, listeners keep working while you drag
/// a slider.
@MainActor
final class ProcessMonitor {
    private let onChange: @MainActor () -> Void
    private var processListListener: PropertyListener?

    /// One "is it playing?" listener per Core Audio process object.
    private var playbackListeners: [AudioObjectID: PropertyListener] = [:]

    /// Several notifications often arrive together (Chrome starting three
    /// helpers at once); this folds them into a single `onChange`.
    private var isChangePending = false

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        processListListener = PropertyListener(.system, kAudioHardwarePropertyProcessObjectList) { [weak self] in
            self?.processListChanged()
        }
        watchPlayback()
    }

    private func processListChanged() {
        watchPlayback()
        notify()
    }

    /// Keeps exactly one playback listener per current process object.
    private func watchPlayback() {
        let objects = Set(AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList, defaultValue: AudioObjectID.unknown))

        playbackListeners = playbackListeners.filter { objects.contains($0.key) }   // released → removed
        for object in objects where playbackListeners[object] == nil {
            // `IsRunning`, not `IsRunningOutput`: on macOS 27 Core Audio sends change
            // notifications for the former (and the process's device list) but
            // never for the latter. The scanner still reads `IsRunningOutput` to
            // tell playing apps from recording ones.
            playbackListeners[object] = PropertyListener(object, kAudioProcessPropertyIsRunning) { [weak self] in
                self?.notify()
            }
        }
    }

    private func notify() {
        guard !isChangePending else { return }
        isChangePending = true
        DispatchQueue.main.async { [weak self] in
            self?.isChangePending = false
            self?.onChange()
        }
    }
}
