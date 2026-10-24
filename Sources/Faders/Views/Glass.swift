import SwiftUI

// Liquid Glass on macOS 26 Tahoe and macOS 27 Golden Gate (the glass APIs
// arrived in 26), with a frosted fallback on macOS 14–15.
// Keeping the version check in one place means the rest of the UI never has
// to think about it.

extension View {
    /// Places the view on a rounded glass "platter", like a Control Center module.
    func glassPlatter(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassPlatter(cornerRadius: cornerRadius))
    }
}

private struct GlassPlatter: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(.quinary, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

/// Groups glass platters so macOS 26+ renders them together (faster, and they
/// blend smoothly when close). A plain stack on older systems.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                VStack(spacing: spacing) { content }
            }
        } else {
            VStack(spacing: spacing) { content }
        }
    }
}
