import SwiftUI

/// Pure geometry for a two-pane horizontal split. Extracted from the view so
/// the clamping — the only place real bugs live — is unit-testable.
struct SplitLayout: Equatable {
    var leadingWidth: CGFloat
    var trailingWidth: CGFloat

    /// Hit area of the divider handle, subtracted from the usable width.
    static let dividerWidth: CGFloat = 6

    /// Resolve pane widths. Guarantees: both widths >= 0, and
    /// `leading + trailing + dividerWidth == max(total, dividerWidth)`.
    ///
    /// When the container is too narrow to satisfy both minimums the space is
    /// shared in proportion to them instead of starving one pane to zero.
    static func resolve(total: CGFloat, ratio: Double,
                        minLeading: CGFloat, minTrailing: CGFloat) -> SplitLayout {
        let available = max(0, total - dividerWidth)
        guard available > 0 else { return SplitLayout(leadingWidth: 0, trailingWidth: 0) }

        let minL = max(0, minLeading)
        let minT = max(0, minTrailing)
        if minL + minT >= available {
            let sum = minL + minT
            let lead = sum > 0 ? available * (minL / sum) : available / 2
            return SplitLayout(leadingWidth: lead, trailingWidth: available - lead)
        }

        // NaN would poison every comparison below; ±infinity is fine, it just
        // pins to one of the two clamps.
        let r = ratio.isNaN ? 0.5 : ratio
        let raw = available * CGFloat(r)
        let lead = min(max(raw, minL), available - minT)
        return SplitLayout(leadingWidth: lead, trailingWidth: available - lead)
    }

    /// Inverse of `resolve`: the ratio that would produce `leadingWidth`,
    /// clamped to the legal range. Always finite and within `0...1`.
    static func ratio(forLeadingWidth width: CGFloat, total: CGFloat,
                      minLeading: CGFloat, minTrailing: CGFloat) -> Double {
        let available = max(0, total - dividerWidth)
        guard available > 0 else { return 0.5 }

        let minL = max(0, minLeading)
        let minT = max(0, minTrailing)
        if minL + minT >= available {
            let sum = minL + minT
            return sum > 0 ? Double(minL / sum) : 0.5
        }

        let w = width.isNaN ? available / 2 : width
        let lead = min(max(w, minL), available - minT)
        return Double(lead / available)
    }
}

/// Two-pane horizontal split with a draggable divider. `ratio` is the fraction
/// of the usable width taken by the *leading* pane, clamped to respect both
/// minimum widths.
struct ResizableSplit<Leading: View, Trailing: View>: View {
    @Binding var ratio: Double
    let minLeading: CGFloat
    let minTrailing: CGFloat
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    @State private var isDragging = false
    @State private var isHovering = false
    /// Leading width when the current drag began — the gesture is attached to
    /// the handle, so `value.location` is in the *handle's* coordinate space and
    /// cannot be used as an absolute position. Only `translation` is usable.
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let layout = SplitLayout.resolve(total: total, ratio: ratio,
                                             minLeading: minLeading,
                                             minTrailing: minTrailing)
            HStack(spacing: 0) {
                leading().frame(width: layout.leadingWidth)
                dividerHandle(total: total, layout: layout)
                trailing().frame(width: layout.trailingWidth)
            }
            .frame(width: max(total, SplitLayout.dividerWidth),
                   height: geo.size.height, alignment: .leading)
        }
    }

    private func dividerHandle(total: CGFloat, layout: SplitLayout) -> some View {
        ZStack {
            Color.clear.frame(width: SplitLayout.dividerWidth)
            Rectangle().fill(.separator).frame(width: 0.5)
            if isDragging || isHovering {
                Capsule().fill(Color.accentColor).frame(width: 3, height: 40)
            }
        }
        .frame(width: SplitLayout.dividerWidth)
        .contentShape(Rectangle())
        .onHover { inside in
            // Balanced push/pop — pushing on both enter and exit leaks cursors
            // on the stack and the resize cursor sticks forever.
            guard inside != isHovering else { return }
            isHovering = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let start = dragStartWidth ?? layout.leadingWidth
                    if dragStartWidth == nil { dragStartWidth = start }
                    isDragging = true
                    ratio = SplitLayout.ratio(forLeadingWidth: start + v.translation.width,
                                              total: total,
                                              minLeading: minLeading,
                                              minTrailing: minTrailing)
                }
                .onEnded { _ in
                    isDragging = false
                    dragStartWidth = nil
                }
        )
        .accessibilityLabel("Séparateur redimensionnable")
    }
}
