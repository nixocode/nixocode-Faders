import SwiftUI

// The panel itself is the only glass: macOS draws it, and it follows the
// user's Liquid Glass look (clear to tinted), Reduce Transparency and the
// window corner radius on its own. Rows sit on it as quiet fills, as Apple's
// guidelines ask: Liquid Glass is for controls and navigation, not content,
// and glass on glass turns muddy.

extension View {
    /// A subtle rounded fill behind a row.
    func rowBackground() -> some View {
        modifier(RowBackground())
    }
}

private struct RowBackground: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(.fill.quaternary, in: shape)
            // Increase Contrast: outline the rows so they don't rely on a faint fill.
            .overlay {
                if contrast == .increased {
                    shape.stroke(.separator, lineWidth: 1)
                }
            }
    }

    /// On macOS 26+ the corners follow the panel's (concentric), whatever
    /// radius the system gives it; the minimum keeps them round when the row
    /// sits far from the panel's corner.
    private var shape: AnyShape {
        if #available(macOS 26.0, *) {
            AnyShape(ConcentricRectangle(corners: .concentric(minimum: .fixed(12)), isUniform: true))
        } else {
            AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
