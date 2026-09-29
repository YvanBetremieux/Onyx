import SwiftUI
import RecorderCore

/// Row identity + playhead hit-testing + empty-state copy for `TranscriptPanel`.
enum TranscriptPanelRules {
    /// A transcript row. Identity is **positional**: mic and system streams are
    /// merged, so two turns can legitimately share `start`, `speaker` *and*
    /// `text`, and any content-derived id would collapse them in `ForEach`.
    struct Row: Identifiable {
        let id: Int
        let segment: TranscriptSegment
    }

    static func rows(_ segments: [TranscriptSegment]) -> [Row] {
        segments.enumerated().map { Row(id: $0.offset, segment: $0.element) }
    }

    /// Half-open `[start, end)` so a playhead sitting exactly on a boundary
    /// lights up one turn, never two.
    static func isActive(_ seg: TranscriptSegment, playhead: TimeInterval) -> Bool {
        playhead >= seg.start && playhead < seg.end
    }

    static func activeIndex(in segments: [TranscriptSegment],
                            playhead: TimeInterval) -> Int? {
        segments.firstIndex { isActive($0, playhead: playhead) }
    }

    /// Copy for an empty transcript, or `nil` when there is something to show.
    static func emptyMessage(segmentCount: Int, transcriptState: String?) -> String? {
        guard segmentCount == 0 else { return nil }
        switch transcriptState {
        case "done":
            return "Aucune parole détectée dans cet enregistrement."
        case "failed":
            return "Le traitement de ce meeting a échoué : pas de transcript."
        default:
            return "Transcription en cours…"
        }
    }
}

/// The transcript half of the main panel. Read-only: see `TurnView`.
struct TranscriptPanel: View {
    @ObservedObject var store: ViewerStore
    /// Observed here rather than passed down as a plain `TimeInterval` so this
    /// panel is the *only* thing invalidated when the playhead moves — and only
    /// at the quantised rate (2 Hz), not the player's 10 Hz tick.
    @ObservedObject var playhead: TranscriptPlayhead
    let onSeek: (TimeInterval) -> Void
    let onHide: () -> Void
    var transcriptState: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("TRANSCRIPT")
                    .font(.system(size: 12, weight: .semibold)).kerning(0.7)
                    .foregroundStyle(.secondary)
                Spacer()
                // Same triple-chevron control as the reopen strip
                // (`PanelEdgeToggle`), so collapse and expand read as one.
                Button(action: onHide) {
                    ChevronTriple(direction: .right)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .hoverHighlight(cornerRadius: 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Masquer le panneau transcript")
                .accessibilityLabel("Masquer le panneau transcript")
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 8)
            .overlay(Rectangle().fill(.separator).frame(height: 0.5), alignment: .bottom)

            if let message = TranscriptPanelRules.emptyMessage(
                segmentCount: store.currentTranscript.count,
                transcriptState: transcriptState) {
                VStack(spacing: 10) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(message)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                turnList
            }
        }
    }

    private var turnList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(TranscriptPanelRules.rows(store.currentTranscript)) { row in
                        TurnView(segment: row.segment,
                                 isActive: TranscriptPanelRules.isActive(
                                    row.segment, playhead: playhead.seconds))
                            .contentShape(Rectangle())
                            .onTapGesture { onSeek(row.segment.start) }
                            .id(row.id)
                    }
                }
                .padding(.horizontal, 32).padding(.bottom, 40)
            }
            // Single-param onChange: the two-parameter variant is macOS 14+.
            .onChange(of: playhead.seconds) { _ in
                guard let idx = TranscriptPanelRules.activeIndex(
                        in: store.currentTranscript,
                        playhead: playhead.seconds) else { return }
                // Only follow when the *active turn* changes. Firing `scrollTo`
                // on every playhead publish re-centres the list twice a second,
                // which fights the user the moment they scroll by hand.
                guard idx != lastScrolledIndex else { return }
                lastScrolledIndex = idx
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
        }
    }

    /// Last turn we auto-scrolled to. `@State` on a value-type view, so it
    /// survives redraws.
    @State private var lastScrolledIndex: Int?
}
