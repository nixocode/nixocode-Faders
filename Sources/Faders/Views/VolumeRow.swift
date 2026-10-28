import SwiftUI

/// One line in the mixer: icon, name, percentage, slider and mute button.
/// Used for both the output device and each app.
struct VolumeRow<Icon: View>: View {
    let title: String
    @Binding var volume: Float
    let isMuted: Bool
    let onToggleMute: () -> Void
    /// Told when a drag on the slider starts (true) and ends (false).
    var onEditingChanged: (Bool) -> Void = { _ in }
    @ViewBuilder var icon: Icon

    private var percent: Int { Int((volume * 100).rounded()) }

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 32, height: 32)
                .opacity(isMuted ? 0.45 : 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(isMuted ? "Muted" : "\(percent)%")
                        .font(.subheadline.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }

                Slider(value: $volume, in: 0...1, onEditingChanged: onEditingChanged)
                    .controlSize(.small)
                    .disabled(isMuted)
                    .accessibilityLabel("\(title) volume")
                    .accessibilityValue(isMuted ? "Muted" : "\(percent) percent")
            }

            MuteButton(isMuted: isMuted, volume: volume, action: onToggleMute)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .rowBackground()
        // The keyboard reaches whole rows with Tab, even with macOS's "Keyboard
        // navigation" off (the default), which otherwise keeps sliders and
        // buttons out of reach. ← → change the level and M mutes.
        .focusable()
        .onKeyPress(.leftArrow) { nudge(by: -0.05) }
        .onKeyPress(.rightArrow) { nudge(by: 0.05) }
        .onKeyPress("m") {
            onToggleMute()
            return .handled
        }
    }

    private func nudge(by step: Float) -> KeyPress.Result {
        guard !isMuted else { return .ignored }
        volume = min(max(volume + step, 0), 1)
        return .handled
    }
}

/// Round speaker button whose waves follow the volume, like the menu bar icon.
private struct MuteButton: View {
    let isMuted: Bool
    let volume: Float
    let action: () -> Void

    private var symbol: String {
        if isMuted || volume == 0 { return "speaker.slash.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol, variableValue: Double(volume))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isMuted ? .primary : .secondary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        // Quiet by default, a shade stronger when muted, like a toggle that's on.
        // (Not red: on macOS red means an error or a destructive action.)
        .background(isMuted ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.fill.tertiary), in: Circle())
        .help(isMuted ? "Unmute (M)" : "Mute (M)")
        // A toggle to VoiceOver ("Mute, on"), not a button whose name flips.
        .accessibilityLabel("Mute")
        .accessibilityValue(isMuted ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}
