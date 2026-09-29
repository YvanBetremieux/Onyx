import SwiftUI
import Combine

struct SearchField: View {
    @Binding var text: String
    var onChange: (String) -> Void = { _ in }
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Rechercher meetings, transcripts…", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .font(.system(size: 12))
                // Single-param onChange: the two-param variant is macOS 14+,
                // the project targets macOS 13.
                .onChange(of: text) { new in onChange(new) }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.primary.opacity(focused ? 0 : 0.045),
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor, lineWidth: focused ? 2 : 0)
                .padding(-2)
        )
        .padding(.horizontal, 4).padding(.top, 4).padding(.bottom, 12)
    }
}
