import AppKit
import CoreAudio
import UniformTypeIdentifiers

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
@MainActor
enum AudioAppScanner {

    /// Small copies of app icons, by `AudioApp.id` (see `smallIcon`).
    private static var iconCache: [String: NSImage] = [:]

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
            let playing = isPlaying([object])
            let owner = Owner.resolve(pid: pid, bundleID: bundleID, regularApps: regularApps)

            if owner.isSystemService { continue }

            var group = groups[owner.key] ?? (owner, [], false)
            group.objects.append(object)
            group.playing = group.playing || playing
            groups[owner.key] = group
        }

        iconCache = iconCache.filter { groups[$0.key] != nil }   // forget apps that are gone

        return groups.values
            .map { group in
                AudioApp(
                    id: group.owner.key,
                    name: group.owner.name,
                    icon: icon(for: group.owner),
                    processObjectIDs: group.objects.sorted(),
                    isPlaying: group.playing
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// App icons come at up to 1024 px, and the mixer shows them at 32 pt. Drawing
    /// each one once into a small bitmap keeps memory low and saves asking macOS
    /// for the icon again on every refresh.
    private static func icon(for owner: Owner) -> NSImage {
        if let cached = iconCache[owner.key] { return cached }
        let icon = smallIcon(owner.icon())
        iconCache[owner.key] = icon
        return icon
    }

    private static func smallIcon(_ icon: NSImage) -> NSImage {
        let size = NSSize(width: 32, height: 32)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,   // 32 pt on a Retina screen
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return icon }
        bitmap.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        icon.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        let small = NSImage(size: size)
        small.addRepresentation(bitmap)
        return small
    }

    /// True if any of these processes is outputting sound right now.
    static func isPlaying(_ processObjectIDs: [AudioObjectID]) -> Bool {
        processObjectIDs.contains { object in
            (object.read(kAudioProcessPropertyIsRunningOutput, defaultValue: UInt32(0)) ?? 0) != 0
        }
    }

    // MARK: - Working out which app a process belongs to

    private struct Owner {
        let key: String
        let name: String
        /// Only asked for when the icon isn't cached yet.
        let icon: () -> NSImage
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

            // 3. A helper that lives inside its app's bundle, whatever its bundle
            //    ID: ".../Discord.app/Contents/Frameworks/Discord Helper.app/...".
            let path = executablePath(of: pid)
            if let path,
               let bundlePath = bundle(containing: path, among: regularApps.compactMap(\.bundleURL?.path)),
               let parent = regularApps.first(where: { $0.bundleURL?.path == bundlePath }) {
                return Owner(app: parent, fallbackKey: bundleID ?? "pid-\(pid)")
            }

            let app = NSRunningApplication(processIdentifier: pid)
            let isWebKit = bundleID?.hasPrefix("com.apple.WebKit") == true

            // 4. WebKit plays the sound of web pages for Safari and every app with a
            //    web view, from one process per app named after it ("Safari Graphics
            //    and Media"). That sound belongs to the app.
            if isWebKit, let processName = app?.localizedName,
               let appName = appName(in: processName, among: regularApps.compactMap(\.localizedName)),
               let parent = regularApps.first(where: { $0.localizedName == appName }) {
                return Owner(app: parent, fallbackKey: bundleID ?? "pid-\(pid)")
            }

            // 5. Anything else: a command-line tool, a background service, or
            //    WebKit working for something that isn't an app.
            let name = app?.localizedName
                ?? path.map { URL(fileURLWithPath: $0).lastPathComponent }   // "afplay", "python3"…
                ?? bundleID?.components(separatedBy: ".").last
                ?? "Process \(pid)"
            // Every WebKit process has the same bundle ID; the name tells them apart.
            let key = isWebKit ? "\(bundleID ?? "")/\(name)" : bundleID ?? "pid-\(pid)"
            var owner = Owner(key: key, name: name) {
                app?.icon ?? NSWorkspace.shared.icon(for: .unixExecutable)
            }
            owner.isSystemService = isAppleBackgroundService(bundleID)
                || (app == nil && path.map(isSystemDaemon) == true)
            return owner
        }

        /// Daemons such as systemsoundserverd or PerfPowerServices have no bundle
        /// ID, but live in the system's own folders. (Tools you run yourself, like
        /// /usr/bin/afplay, stay visible.)
        private static func isSystemDaemon(_ path: String) -> Bool {
            ["/System/", "/usr/libexec/", "/usr/sbin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
        }

        /// Apple's own background processes have bundle IDs starting with
        /// "com.apple.". WebKit is the exception: it plays the sound of web pages
        /// in Safari and other apps, so it stays visible.
        private static func isAppleBackgroundService(_ bundleID: String?) -> Bool {
            guard let bundleID, bundleID.hasPrefix("com.apple.") else { return false }
            return !bundleID.hasPrefix("com.apple.WebKit")
        }

        private init(key: String, name: String, icon: @escaping () -> NSImage) {
            self.key = key
            self.name = name
            self.icon = icon
        }

        private init(app: NSRunningApplication, fallbackKey: String) {
            self.init(key: app.bundleIdentifier ?? fallbackKey, name: app.localizedName ?? fallbackKey) {
                app.icon ?? NSImage()
            }
        }
    }

    /// Where a process's executable lives, e.g. "/usr/bin/afplay".
    nonisolated private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))   // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The app, among `appNames`, that a process is named after: "Safari" for
    /// "Safari Graphics and Media". Whole words only, so it also works in other
    /// languages; the longest name wins.
    nonisolated static func appName(in processName: String, among appNames: [String]) -> String? {
        let padded = " \(processName) "
        return appNames
            .filter { !$0.isEmpty && padded.contains(" \($0) ") }
            .max { $0.count < $1.count }
    }

    /// The app bundle, among `bundlePaths`, that holds this executable. If
    /// bundles are nested, the innermost one wins.
    nonisolated static func bundle(containing executablePath: String, among bundlePaths: [String]) -> String? {
        bundlePaths
            .filter { executablePath.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            .max { $0.count < $1.count }
    }
}
