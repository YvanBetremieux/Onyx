import SwiftUI

/// Full-height strip on the right edge of the main panel, shown ONLY while
/// the transcript panel is hidden — click anywhere on it to bring the panel
/// back. Closing goes through the button in the transcript panel's own
/// header (`TranscriptPanel`), so nothing extra clutters the edge while the
/// panel is open.
struct PanelEdgeToggle: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ChevronTriple(direction: .left)
                .foregroundStyle(hovering ? AnyShapeStyle(.primary)
                                          : AnyShapeStyle(.secondary))
                .frame(width: 28)
                .frame(maxHeight: .infinity)
                .background(hovering
                            ? AnyShapeStyle(.quaternary.opacity(0.7))
                            : AnyShapeStyle(Color(nsColor: .windowBackgroundColor).opacity(0.5)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .overlay(Rectangle().fill(.separator).frame(width: 0.5), alignment: .leading)
        .help("Afficher le panneau transcript")
        .accessibilityLabel("Afficher le panneau transcript")
    }
}

/// Three nested chevrons (⋘ / ⋙) — SF Symbols stops at `chevron.left.2`,
/// so the third one is composed by hand. Shared by the reopen strip and the
/// transcript header's collapse button so both read as the same control.
struct ChevronTriple: View {
    enum Direction { case left, right }
    let direction: Direction

    var body: some View {
        HStack(spacing: -4.5) {
            ForEach(0..<3, id: \.self) { _ in
                Image(systemName: direction == .left ? "chevron.left" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
        }
    }
}
