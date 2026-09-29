import SwiftUI
import RecorderCore

struct SearchResultsList: View {
    let hits: [SearchHit]
    @Binding var selectedMeetingId: String?
    let onSelect: (SearchHit) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(hits.isEmpty ? "Aucun résultat" : "\(hits.count) résultats")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                if hits.isEmpty {
                    // Distinguishable from "browse mode with no meetings": the
                    // sidebar only shows this list when the query is non-empty.
                    Text("Aucun passage de transcript ne correspond à cette recherche.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.top, 4)
                } else {
                    // `meetingId` is NOT unique: FTS returns one row per matching
                    // segment, so a single meeting can appear several times.
                    // Identify by position instead — using meetingId here makes
                    // SwiftUI collapse/duplicate rows.
                    ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                        SearchResultRow(hit: hit,
                                        selected: hit.meetingId == selectedMeetingId,
                                        onSelect: { onSelect(hit) })
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }
}
