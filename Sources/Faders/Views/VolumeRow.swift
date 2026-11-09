import SwiftUI

/// One line in the mixer: icon, name, percentage, slider and mute button.
/// Used for both the output device and each app.
struct VolumeRow<Icon: View, Title: View>: View {
    /// What the row controls, for VoiceOver ("Spotify volume").
    let name: String
    @Binding var volume: Float
    let isMuted: Bool
    let onToggleMute: () -> Void
    /// Told when a drag on the slider, or a swipe over the row, starts (true)
    /// and ends (false).
    var onEditingChanged: (Bool) -> Void = { _ in }
    @ViewBuilder var icon: Icon
    /// Usually just the name; the output row puts its device menu here.
    @ViewBuilder var title: Title

    private var percent: Int { Int((volume * 100).rounded()) }

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 32, height: 32)
                .opacity(isMuted ? 0.45 : 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    title
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
                    .accessibilityLabel("\(name) volume")
                    .accessibilityValue(isMuted ? "Muted" : "\(percent) percent")
            }

            MuteButton(isMuted: isMuted, volume: volume, action: onToggleMute)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .rowBackground()
        // A two-finger sideways swipe anywhere on the row moves its slider.
        .scrollToAdjust($volume, isEnabled: !isMuted, onEditingChanged: onEditingChanged)
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

extension VolumeRow where Title == Text {
    /// A row whose title is just its name.
    init(
        name: String,
        volume: Binding<Float>,
        isMuted: Bool,
        onToggleMute: @escaping () -> Void,
        onEditingChanged: @escaping (Bool) -> Void = { _ in },
        @ViewBuilder icon: () -> Icon
    ) {
        self.init(
            name: name, volume: volume, isMuted: isMuted, onToggleMute: onToggleMute,
            onEditingChanged: onEditingChanged, icon: icon, title: { Text(name) }
        )
    }
}

/// Round speaker button whose waves follow the volume, like the menu bar icon.
private struct MuteButton: View {
    let isMuted: Bool
    let volume: Float
    let action: () -> Void

    /// One, two or three waves, swapped without an animation. On macOS 27 both
    /// `Image(systemName:variableValue:)` and `.contentTransition(.symbolEffect(.replace))`
    /// make the system allocate about 130 MB of graphics memory for several
    /// seconds each time the symbol redraws (measured: 37 MB → 170 MB on a
    /// single volume change; 45 MB at most without them). Steps also mean the
    /// icon only redraws when the level crosses one.
    private var symbol: String {
        if isMuted || volume == 0 { return "speaker.slash.fill" }
        switch volume {
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isMuted ? .primary : .secondary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
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
