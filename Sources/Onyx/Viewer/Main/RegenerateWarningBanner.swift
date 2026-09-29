import SwiftUI

/// Ochre warning shown when the active note has been hand-edited since it was
/// generated: regenerating would throw those edits away.
struct RegenerateWarningBanner: View {
    let onDismiss: () -> Void
    let onRegenerate: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// Ochre lightened for dark mode — the light-mode tone reads as mud on a
    /// dark background.
    private var ochre: Color {
        colorScheme == .dark
            ? Color(red: 0.93, green: 0.72, blue: 0.32)
            : Color(red: 0.78, green: 0.54, blue: 0.18)
    }

    private var tintStrength: (Double, Double) {
        colorScheme == .dark ? (0.18, 0.10) : (0.12, 0.06)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ochre)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Cette note a été éditée depuis sa génération.")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Régénérer va écraser tes modifications.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Ignorer", action: onDismiss)
                .buttonStyle(.borderless)
                .font(.system(size: 12))
            Button("Régénérer quand même", action: onRegenerate)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            LinearGradient(colors: [ochre.opacity(tintStrength.0),
                                    ochre.opacity(tintStrength.1)],
                           startPoint: .top, endPoint: .bottom)
        )
        .overlay(Rectangle().fill(.separator).frame(height: 0.5), alignment: .bottom)
        .accessibilityElement(children: .contain)
    }
}
