import SwiftUI

/// One line in the mixer: icon, name, percentage, slider and mute button.
/// Used for both the output device and each app.
struct VolumeRow<Icon: View>: View {
    let title: String
    @Binding var volume: Float
    let isMuted: Bool
    let onToggleMute: () -> Void
    @ViewBuilder var icon: Icon

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 32, height: 32)
                .opacity(isMuted ? 0.45 : 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(isMuted ? "Muted" : "\(Int((volume * 100).rounded()))%")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }

                Slider(value: $volume, in: 0...1)
                    .controlSize(.small)
                    .disabled(isMuted)
                    .accessibilityLabel("\(title) volume")
            }

            MuteButton(isMuted: isMuted, volume: volume, action: onToggleMute)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .glassPlatter(cornerRadius: 18)
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
                .foregroundStyle(isMuted ? Color.red : Color.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        // Quiet by default; turns red when muted so it's obvious at a glance.
        .background(isMuted ? AnyShapeStyle(Color.red.opacity(0.15)) : AnyShapeStyle(HierarchicalShapeStyle.quinary), in: Circle())
        .help(isMuted ? "Unmute" : "Mute")
        .accessibilityLabel(isMuted ? "Unmute" : "Mute")
    }
}
