import SwiftUI

/// Overlapping circular avatars built from participant initials.
///
/// The stack degrades gracefully: zero participants renders nothing, and more
/// than `maxVisible` collapses the tail into a `+N` chip so the header never
/// grows without bound.
struct AvatarStack: View {
    let initials: [String]
    var maxVisible: Int = 4
    var diameter: CGFloat = 20

    init(initials: [String], maxVisible: Int = 4, diameter: CGFloat = 20) {
        self.initials = initials
        self.maxVisible = maxVisible
        self.diameter = diameter
    }

    /// Convenience: build straight from raw speaker / participant names.
    init(names: [String], maxVisible: Int = 4, diameter: CGFloat = 20) {
        self.init(initials: Self.initials(forNames: names),
                  maxVisible: maxVisible, diameter: diameter)
    }

    // MARK: - Initials extraction

    private static let separators = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "._-,/|@+()[]<>"))

    /// One or two grapheme clusters for `name`, or `nil` when the name carries
    /// no usable character at all (empty, whitespace, punctuation only).
    ///
    /// Slicing is done on `Character` (grapheme clusters) so multi-scalar emoji
    /// and combining marks survive intact.
    static func initials(for name: String) -> String? {
        let words = name.components(separatedBy: separators).filter { !$0.isEmpty }
        guard let first = words.first?.first else { return nil }
        guard words.count > 1, let last = words.last?.first else {
            return String(first).uppercased()
        }
        return (String(first) + String(last)).uppercased()
    }

    static func initials(forNames names: [String]) -> [String] {
        names.compactMap { initials(for: $0) }
    }

    // MARK: - Overflow

    struct Display: Equatable {
        var visible: [String]
        /// Number of participants folded into the `+N` chip, `nil` if none.
        var overflow: Int?
    }

    static func display(initials: [String], maxVisible: Int) -> Display {
        if initials.isEmpty { return Display(visible: [], overflow: nil) }
        if initials.count <= maxVisible && maxVisible > 0 {
            return Display(visible: initials, overflow: nil)
        }
        let keep = max(0, maxVisible - 1)
        return Display(visible: Array(initials.prefix(keep)),
                       overflow: initials.count - keep)
    }

    // MARK: - Palette

    /// Muted duotone pairs. Text on top is always white, and every gradient
    /// here is dark enough for that to stay legible in light *and* dark mode.
    private static let gradients: [[Color]] = [
        [Color(red: 0.85, green: 0.46, blue: 0.34), Color(red: 0.72, green: 0.35, blue: 0.24)],
        [Color(red: 0.29, green: 0.49, blue: 0.62), Color(red: 0.17, green: 0.35, blue: 0.49)],
        [Color(red: 0.42, green: 0.55, blue: 0.23), Color(red: 0.30, green: 0.42, blue: 0.14)],
        [Color(red: 0.54, green: 0.42, blue: 0.66), Color(red: 0.42, green: 0.29, blue: 0.54)],
    ]

    // MARK: - Body

    var body: some View {
        let d = Self.display(initials: initials, maxVisible: maxVisible)
        HStack(spacing: -(diameter * 0.3)) {
            ForEach(Array(d.visible.enumerated()), id: \.offset) { idx, text in
                bubble(text, gradient: Self.gradients[idx % Self.gradients.count])
                    .zIndex(Double(-idx))
            }
            if let n = d.overflow {
                bubble("+\(n)", gradient: nil)
                    .zIndex(Double(-d.visible.count))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(d))
    }

    private func accessibilityText(_ d: Display) -> String {
        if d.visible.isEmpty && d.overflow == nil { return "Aucun participant" }
        let total = d.visible.count + (d.overflow ?? 0)
        return "\(total) participant\(total > 1 ? "s" : ""): " + d.visible.joined(separator: ", ")
    }

    @ViewBuilder
    private func bubble(_ text: String, gradient: [Color]?) -> some View {
        Text(text)
            .font(.system(size: diameter * 0.475, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(gradient == nil ? Color.primary : Color.white)
            .frame(width: diameter, height: diameter)
            .background {
                if let g = gradient {
                    Circle().fill(LinearGradient(colors: g,
                                                 startPoint: .topLeading,
                                                 endPoint: .bottomTrailing))
                } else {
                    Circle().fill(Color.primary.opacity(0.12))
                }
            }
            // Semantic window background so the cut-out ring reads correctly in
            // both appearances (a hardcoded white ring is invisible in dark).
            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
    }
}
