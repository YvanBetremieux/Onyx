import SwiftUI
import RecorderCore

/// One FTS hit: meeting title + date, the highlighted snippet, and the speaker /
/// approximate timestamp of the matching segment.
struct SearchResultRow: View {
    let hit: SearchHit
    let selected: Bool
    let onSelect: () -> Void

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "d MMM · HH:mm"; return f
    }()

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(hit.title ?? "Untitled")
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text(Self.dayFmt.string(from: hit.startedAt))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                // `hit.snippet` already carries the match highlighting baked in
                // by MeetingIndexer.parseHighlightedSnippet — render as-is.
                Text(hit.snippet)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                HStack(spacing: 8) {
                    Text(hit.speaker)
                        .font(.system(size: 10.5, design: .monospaced))
                    if let t = hit.approximateTimestamp {
                        Text("·").foregroundStyle(.tertiary)
                        // `TurnStyle.mmss`, not a local formatter: the previous
                        // one did `Int(t)` on a value that comes straight from an
                        // FTS row's `start_ms`, and `Int(Double.nan)` traps
                        // (negatives formatted as "-1:-5"). `TurnStyle.mmss`
                        // clamps and is covered by TranscriptTurnTests.
                        Text(TurnStyle.mmss(t))
                            .font(.system(size: 10.5, design: .monospaced))
                    }
                }
                .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(selected ? Color.accentColor.opacity(0.10) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
