import AppKit
import CoreAudio

/// One app (as the user sees it) that uses audio.
///
/// A single app can play sound from several processes — Chrome, Slack and other
/// Electron apps use "helper" processes — so we group them into one row.
struct AudioApp: Identifiable, Equatable {
    /// Stable key used to remember this app's volume (its bundle ID when known).
    let id: String
    let name: String
    let icon: NSImage
    /// The Core Audio process objects that belong to this app.
    let processObjectIDs: [AudioObjectID]
    /// True while at least one of its processes is actually outputting sound.
    let isPlaying: Bool

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id && lhs.processObjectIDs == rhs.processObjectIDs && lhs.isPlaying == rhs.isPlaying
    }
}

/// Finds every app that is talking to Core Audio, grouped by app.
enum AudioAppScanner {

    static func scan() -> [AudioApp] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let regularApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }

        // Core Audio keeps one "process object" for every process that has used audio.
        let processObjects = AudioObjectID.system.readArray(
            kAudioHardwarePropertyProcessObjectList,
            defaultValue: AudioObjectID.unknown
        )

        // Group process objects by the app they belong to.
        var groups: [String: (owner: Owner, objects: [AudioObjectID], playing: Bool)] = [:]

        for object in processObjects {
            guard let pid = object.read(kAudioProcessPropertyPID, defaultValue: pid_t(-1)), pid > 0, pid != ownPID
            else { continue }

            let bundleID = object.readString(kAudioProcessPropertyBundleID)
            let isPlaying = (object.read(kAudioProcessPropertyIsRunningOutput, defaultValue: UInt32(0)) ?? 0) != 0
            let owner = Owner.resolve(pid: pid, bundleID: bundleID, regularApps: regularApps)

            if owner.isSystemService { continue }

            var group = groups[owner.key] ?? (owner, [], false)
            group.objects.append(object)
            group.playing = group.playing || isPlaying
            groups[owner.key] = group
        }

        return groups.values
            .map { group in
                AudioApp(
                    id: group.owner.key,
                    name: group.owner.name,
                    icon: group.owner.icon,
                    processObjectIDs: group.objects.sorted(),
                    isPlaying: group.playing
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Working out which app a process belongs to

    private struct Owner {
        let key: String
        let name: String
        let icon: NSImage
        /// True for Apple's invisible background services (Siri's CoreSpeech,
        /// dictation, notification sounds…). They hold audio connections open
        /// but aren't things you'd want a slider for, so the mixer hides them.
        var isSystemService = false

        static func resolve(pid: pid_t, bundleID: String?, regularApps: [NSRunningApplication]) -> Owner {
            // 1. The process *is* a normal app (Spotify, Music, Zoom…).
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                return Owner(app: app, fallbackKey: bundleID ?? "pid-\(pid)")
            }

            // 2. It's a helper whose bundle ID starts with its parent's,
            //    e.g. "com.google.Chrome.helper" → "com.google.Chrome".
            if let bundleID,
               let parent = regularApps
                   .filter({ app in app.bundleIdentifier.map { bundleID.hasPrefix($0 + ".") } ?? false })
                   .max(by: { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }) {
                return Owner(app: parent, fallbackKey: bundleID)
            }

            // 3. Anything else: a background service or a command-line tool.
            let app = NSRunningApplication(processIdentifier: pid)
            let name = app?.localizedName ?? bundleID?.components(separatedBy: ".").last ?? "Process \(pid)"
            let icon = app?.icon ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
            var owner = Owner(key: bundleID ?? "pid-\(pid)", name: name, icon: icon)
            owner.isSystemService = isAppleBackgroundService(bundleID)
            return owner
        }

        /// Apple's own background processes have bundle IDs starting with
        /// "com.apple.". WebKit is the exception: it plays the sound of web pages
        /// in Safari and other apps, so it stays visible.
        private static func isAppleBackgroundService(_ bundleID: String?) -> Bool {
            guard let bundleID, bundleID.hasPrefix("com.apple.") else { return false }
            return !bundleID.hasPrefix("com.apple.WebKit")
        }

        private init(key: String, name: String, icon: NSImage) {
            self.key = key
            self.name = name
            self.icon = icon
        }

        private init(app: NSRunningApplication, fallbackKey: String) {
            self.init(
                key: app.bundleIdentifier ?? fallbackKey,
                name: app.localizedName ?? fallbackKey,
                icon: app.icon ?? NSImage()
            )
        }
    }
}
