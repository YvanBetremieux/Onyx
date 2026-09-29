import SwiftUI

/// Subtle rounded highlight behind a control while the mouse is over it.
/// The custom `.plain`-style buttons of the viewer give no feedback at all by
/// default (unlike bordered system buttons) — this is the shared remedy, so
/// every control hovers the same way.
struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = 6
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(hovering ? AnyShapeStyle(.quaternary.opacity(0.8))
                                   : AnyShapeStyle(.clear))
            )
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat = 6) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius))
    }
}
