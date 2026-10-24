import ServiceManagement
import SwiftUI

/// The panel that drops down from the menu bar icon.
///
///   ┌─────────────────────────────────┐
///   │ Faders                Reset All │
///   │ OUTPUT                          │
///   │ [🎧 AirPods Pro  ━━━━●━━━━  🔊] │
///   │ APPS                            │
///   │ [🎵 Spotify      ━━●━━━━━━  🔊] │
///   │ [🌐 Chrome       ━━━━━━●━━  🔊] │
///   │ ◯ Open at Login   Settings Quit │
///   └─────────────────────────────────┘
struct MixerView: View {
    @Environment(MixerModel.self) private var mixer

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            MixerSection("Output") { outputRow }
            MixerSection("Apps") { appList }
            if mixer.permissionProblem { permissionHint }
            Divider().opacity(0.4)
            footer
        }
        .padding(16)
        .frame(width: 340)
        // Size the panel to its content, so it shrinks when apps stop playing
        // (instead of leaving empty glass behind).
        .fixedSize(horizontal: false, vertical: true)
        .animation(.smooth(duration: 0.25), value: mixer.apps.map(\.id))
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("Faders")
                .font(.system(size: 15, weight: .bold, design: .rounded))
            Spacer()
            Button("Reset All", action: mixer.resetAll)
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .disabled(!mixer.hasCustomLevels)
                .help("Put every app back to 100%")
        }
    }

    @ViewBuilder
    private var outputRow: some View {
        if let output = mixer.output, output.supportsVolume {
            VolumeRow(
                title: output.name,
                volume: Binding(get: { mixer.outputVolume }, set: { mixer.setOutputVolume($0) }),
                isMuted: mixer.outputMuted,
                onToggleMute: { mixer.setOutputMuted(!mixer.outputMuted) }
            ) {
                DeviceIcon(symbolName: output.symbolName)
            }
        } else {
            EmptyMessage(
                symbol: "speaker.badge.exclamationmark",
                text: mixer.output.map { "\($0.name) has no volume control" } ?? "No output device"
            )
        }
    }

    @ViewBuilder
    private var appList: some View {
        if mixer.apps.isEmpty {
            EmptyMessage(symbol: "speaker.zzz", text: "No apps are playing sound")
        } else if mixer.apps.count <= 5 {
            appRows
        } else {
            // Lots of apps: keep the panel a sensible height and scroll.
            ScrollView { appRows }
                .scrollIndicators(.never)
                .frame(height: 360)
        }
    }

    private var appRows: some View {
        GlassGroup {
            ForEach(mixer.apps) { app in
                VolumeRow(
                    title: app.name,
                    volume: Binding(get: { mixer.volume(for: app) }, set: { mixer.setVolume($0, for: app) }),
                    isMuted: mixer.isMuted(app),
                    onToggleMute: { mixer.toggleMute(app) }
                ) {
                    Image(nsImage: app.icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
    }

    private var permissionHint: some View {
        Button {
            // Opens System Settings → Privacy & Security → Screen & System Audio Recording.
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
        } label: {
            Label("Allow Faders to control app audio in System Settings", systemImage: "lock.shield")
                .font(.system(size: 11))
                .multilineTextAlignment(.leading)
        }
        .buttonStyle(.link)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            LaunchAtLoginToggle()
            Spacer()
            Button("Sound Settings…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
            }
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

// MARK: - Small building blocks

/// A small caption ("OUTPUT", "APPS") with its content underneath.
private struct MixerSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            content
        }
    }
}

/// Round icon for the output device (AirPods, MacBook speakers…), sized like
/// an app icon so the rows line up.
private struct DeviceIcon: View {
    let symbolName: String

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(Color.accentColor.gradient, in: .circle)
    }
}

private struct EmptyMessage: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 15))
            Text(text).font(.system(size: 12))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(12)
        .glassPlatter()
    }
}

/// Uses the modern ServiceManagement API, so Faders appears in
/// System Settings → General → Login Items like any well-behaved app.
private struct LaunchAtLoginToggle: View {
    @State private var isOn = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Open at Login", isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .onChange(of: isOn) { _, enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    isOn = SMAppService.mainApp.status == .enabled   // show the real state
                }
            }
    }
}
