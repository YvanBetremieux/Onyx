import SwiftUI
import AppKit
import RecorderCore

struct MeetingsSidebar: View {
    @ObservedObject var store: ViewerStore
    /// Meeting awaiting the user's confirmation in the delete alert.
    @State private var meetingPendingDeletion: MeetingListing?
    /// True while the batch-delete confirmation is up (selection mode).
    @State private var confirmingBatchDeletion = false
    /// True while the merge confirmation is up (selection mode).
    @State private var confirmingMerge = false

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: Binding(
                get: { store.searchQuery },
                set: { store.onSearchQueryChanged($0) }
            ))
            // An empty (or whitespace-only) query means browse mode: the FTS
            // search returns [] for such a query, so falling through to the
            // results list would show a permanently empty sidebar.
            if store.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                browseList
            } else {
                SearchResultsList(
                    hits: store.searchResults,
                    selectedMeetingId: $store.selectedMeetingId,
                    // Not `selectMeeting(hit.meetingId)`: the row shows the
                    // passage's timestamp, so selecting it must also jump the
                    // playhead there (previously deferred — there was no player).
                    onSelect: { store.selectSearchHit($0) }
                )
            }
            Divider()
            if store.isSelecting {
                selectionFooter
            } else {
                normalFooter
            }
        }
        .background(SidebarBackground())
        .frame(minWidth: 240, idealWidth: 260, maxWidth: 340)
        .alert("Supprimer ce meeting ?",
               isPresented: Binding(
                   get: { meetingPendingDeletion != nil },
                   set: { if !$0 { meetingPendingDeletion = nil } }
               ),
               presenting: meetingPendingDeletion) { m in
            Button("Supprimer", role: .destructive) {
                store.deleteMeeting(m.id)
                meetingPendingDeletion = nil
            }
            Button("Annuler", role: .cancel) { meetingPendingDeletion = nil }
        } message: { m in
            Text("« \(m.title ?? "Sans titre") » sera déplacé dans la Corbeille "
                 + "(audio, transcript et notes).")
        }
        .alert("Supprimer \(store.deletableCheckedIds.count) meeting"
               + (store.deletableCheckedIds.count > 1 ? "s ?" : " ?"),
               isPresented: $confirmingBatchDeletion) {
            Button("Supprimer", role: .destructive) {
                store.deleteCheckedMeetings()
            }
            Button("Annuler", role: .cancel) { }
        } message: {
            Text("Les dossiers sélectionnés seront déplacés dans la Corbeille "
                 + "(audio, transcript et notes).")
        }
        .alert("Fusionner \(store.mergeableCheckedIds.count) meetings ?",
               isPresented: $confirmingMerge) {
            Button("Fusionner") {
                Task { await store.mergeCheckedMeetings() }
            }
            Button("Annuler", role: .cancel) { }
        } message: {
            Text(mergeConfirmationMessage)
        }
    }

    /// Spells out what the merge will do, in the order the parts will end up in.
    /// The order is the one thing the user cannot infer from a count, and it is
    /// not the order they ticked the boxes in — it is chronological.
    private var mergeConfirmationMessage: String {
        let ids = store.mergeableCheckedIds
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "fr_FR")
        fmt.dateFormat = "d MMM HH'h'mm"
        let lines = ids.enumerated().map { i, id -> String in
            let m = store.meetings.first { $0.id == id }
            let when = m.map { fmt.string(from: $0.startedAt) } ?? id
            let title = m?.title?.trimmingCharacters(in: .whitespaces)
            return "\(i + 1). \(when)" + (title?.isEmpty == false ? " — \(title!)" : "")
        }
        let target = ids.first.flatMap { id in store.meetings.first { $0.id == id } }
        let targetName = target?.title?.isEmpty == false
            ? "« \(target!.title!) »" : "le plus ancien"
        return """
            Les transcriptions seront mises bout à bout dans cet ordre :
            \(lines.joined(separator: "\n"))

            Tout est regroupé dans \(targetName) ; les notes sont régénérées sur \
            l'ensemble. Les autres meetings disparaissent de la liste (leurs dossiers \
            sont conservés, l'audio reste jouable d'un seul tenant).
            """
    }

    /// Default footer: start-recording, live status, meeting count, and the
    /// entry point into checkbox selection mode.
    @ViewBuilder private var normalFooter: some View {
        HStack(spacing: 8) {
            // Ad-hoc session: record + live notes without any Meet/Huddle
            // or calendar event (informal, around-a-table note-taking).
            Button(action: { store.onStartRecording?() }) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(store.isRecordingActive
                                     ? AnyShapeStyle(.tertiary)
                                     : AnyShapeStyle(Color.accentColor))
                    .padding(3)
                    .hoverHighlight(cornerRadius: 14)
            }
            .buttonStyle(.plain)
            .disabled(store.isRecordingActive)
            .help("Démarrer un enregistrement (prise de notes libre)")
            .accessibilityLabel("Démarrer un enregistrement")
            Button(action: { store.beginSelecting() }) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .hoverHighlight(cornerRadius: 12)
            }
            .buttonStyle(.plain)
            .disabled(store.meetings.isEmpty)
            .help("Sélectionner plusieurs meetings (pour les supprimer)")
            .accessibilityLabel("Sélectionner plusieurs meetings")
            footerStatus
            Spacer()
            Text("\(store.meetings.count) meetings")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// Selection-mode footer. Both action buttons carry their count so the batch
    /// size is visible *before* the confirmation, not only inside it.
    @ViewBuilder private var selectionFooter: some View {
        let count = store.deletableCheckedIds.count
        let mergeable = store.mergeableCheckedIds.count
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Button("Tout") { store.checkAllDeletable() }
                Button("Aucun") { store.uncheckAll() }
                    .disabled(count == 0)
                Spacer()
                Text(count == 0 ? "Aucun sélectionné"
                     : "\(count) sélectionné\(count > 1 ? "s" : "")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
            if let err = store.mergeError {
                Text(err)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button {
                    confirmingMerge = true
                } label: {
                    if store.isMerging {
                        // The notes regeneration is a `claude -p` call per level:
                        // tens of seconds during which pressing again must be
                        // impossible, not merely harmless.
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small)
                            Text("Fusion…")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Text(mergeable > 1 ? "Fusionner (\(mergeable))" : "Fusionner")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(!store.canMergeChecked || store.isMerging)
                .help("Concatène les meetings sélectionnés en un seul, dans l'ordre "
                      + "chronologique, et régénère les notes")
                Button(role: .destructive) {
                    confirmingBatchDeletion = true
                } label: {
                    Text(count > 0 ? "Supprimer (\(count))" : "Supprimer")
                        .frame(maxWidth: .infinity)
                }
                .disabled(count == 0 || store.isMerging)
            }
            .controlSize(.small)
            Button("Annuler") { store.endSelecting() }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .disabled(store.isMerging)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// Live footer: red while recording, orange while a pipeline runs, green
    /// otherwise — the old footer was a hardcoded green "Idle".
    @ViewBuilder private var footerStatus: some View {
        let (color, label): (Color, String) = {
            if store.isRecordingActive { return (.red, "Enregistrement") }
            if store.pipelineStates.values.contains(where: { $0 != .failed }) {
                return (.orange, "Traitement…")
            }
            return (.green, "Idle")
        }()
        Circle().fill(color).frame(width: 6, height: 6)
        Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
    }

    @ViewBuilder private var browseList: some View {
        let groups = MeetingGroups.group(store.meetings)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups, id: \.title) { g in
                    DateGroupSection(title: g.title, count: g.items.count) {
                        ForEach(g.items, id: \.id) { m in
                            MeetingRow(meeting: m,
                                       selected: m.id == store.selectedMeetingId,
                                       status: store.rowStatus(for: m),
                                       onStop: store.pipelineStates[m.id] == .recording
                                           ? { store.onStopRecording?() } : nil,
                                       check: store.isSelecting
                                           ? MeetingRow.Check(
                                               isChecked: store.isChecked(m.id),
                                               enabled: store.canDeleteMeeting(m.id))
                                           : nil,
                                       // In selection mode a click ticks the box
                                       // instead of opening the meeting: opening
                                       // one would scroll the panel away from the
                                       // list being curated.
                                       onSelect: {
                                           if store.isSelecting {
                                               store.toggleChecked(m.id)
                                           } else {
                                               store.selectMeeting(m.id)
                                           }
                                       })
                            .contextMenu {
                                Button("Supprimer…", role: .destructive) {
                                    meetingPendingDeletion = m
                                }
                                // Disabled (not hidden) while recording or
                                // processing, so the affordance is discoverable
                                // and its unavailability self-explanatory.
                                .disabled(!store.canDeleteMeeting(m.id))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

/// Translucent material behind the sidebar, matching macOS sidebars.
private struct SidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
