import SwiftUI
import RecorderCore

/// Chrome rules for `NotesPanel`, extracted from the view so they are testable —
/// and so the `.live` invariant is enforced in one auditable place rather than
/// inside a `body`.
enum NotesPanelRules {
    struct Tab: Equatable {
        let level: NoteLevel
        let title: String
        let icon: String
    }

    /// All four levels, in reading order. `.live` is deliberately included: this
    /// panel is *where the user reads and edits their own notes*. It is only the
    /// **generation** affordances that must exclude it — see `canRegenerate`.
    static let tabs: [Tab] = [
        Tab(level: .live, title: "Direct", icon: "pencil"),
        Tab(level: .brief, title: "Brief", icon: "doc.plaintext"),
        Tab(level: .synthese, title: "Synthèse", icon: "text.alignleft"),
        Tab(level: .detaillee, title: "Détaillée", icon: "book.closed"),
    ]

    /// Never offer to regenerate `notes/live.md`: it holds the user's own
    /// writing and generating over it destroys it. Mirrors
    /// `NoteLevel.generatable` (asserted by the tests).
    static func canRegenerate(_ level: NoteLevel) -> Bool { level != .live }

    /// The "this note was hand-edited since it was generated" banner.
    ///
    /// Suppressed for `.live` even if the flag is somehow armed: those notes are
    /// *always* user-authored, so the warning would be permanently on screen and
    /// its "Régénérer quand même" button would be actively destructive.
    static func showsRegenerateBanner(level: NoteLevel,
                                      notesEdited: Bool,
                                      dismissed: Bool) -> Bool {
        canRegenerate(level) && notesEdited && !dismissed
    }

    /// Whether the empty state should offer an inline "Générer maintenant".
    ///
    /// Narrower than `placeholder`, which always has something to say. The button
    /// must only appear when pressing it could actually succeed:
    ///  - never for `.live` (the user's own file — see `canRegenerate`);
    ///  - never when the note already has content (that is the header's
    ///    "Régénérer notes", which carries the overwrite warning);
    ///  - never while the pipeline is running or after it failed, because
    ///    `ClaudeNoteGenerator` needs `transcripts/transcript.md` and would throw
    ///    `transcriptMissing`.
    static func showsGenerateAction(level: NoteLevel,
                                    transcriptState: String?,
                                    noteIsEmpty: Bool) -> Bool {
        canRegenerate(level) && noteIsEmpty && transcriptState == "done"
    }

    /// What an *empty* note body should say. A meeting still being processed and
    /// a meeting that simply has no note yet are different situations, and blank
    /// space for either reads as a bug.
    static func placeholder(for level: NoteLevel, transcriptState: String?) -> String {
        guard canRegenerate(level) else {
            return "Tes notes du meeting. Tape ici pendant l'appel — "
                 + "elles sont sauvegardées automatiquement."
        }
        switch transcriptState {
        case "done":
            return "Pas encore de note à ce niveau. "
                 + "Utilise « Régénérer notes » pour la produire."
        case "failed":
            return "Le traitement de ce meeting a échoué : aucune note n'a pu être générée."
        default:
            // nil (row indexed before the state column existed) or "in_progress".
            return "Transcription en cours… les notes seront générées à la fin du traitement."
        }
    }
}

/// The notes half of the main panel: tab strip over the four note levels, the
/// hand-edit warning, and the Markdown editor for the active level.
struct NotesPanel: View {
    @ObservedObject var store: ViewerStore
    /// Pipeline state of the selected meeting, for the empty-state copy.
    var transcriptState: String?
    @State private var bannerDismissed = false
    /// Brief ✓ feedback after "copy all Markdown" — a clipboard write has no
    /// visible effect of its own, so the button must acknowledge the click.
    @State private var justCopied = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(NotesPanelRules.tabs, id: \.level) { t in
                    tab(t)
                }
                Spacer(minLength: 8)
                copyButton
                previewToggle
                editStatus
            }
            .padding(.horizontal, 20).padding(.top, 14)
            .overlay(Rectangle().fill(.separator).frame(height: 0.5), alignment: .bottom)

            if NotesPanelRules.showsRegenerateBanner(
                level: store.activeNoteLevel,
                notesEdited: store.notesEditedSinceGeneration,
                dismissed: bannerDismissed) {
                RegenerateWarningBanner(
                    onDismiss: { bannerDismissed = true },
                    onRegenerate: {
                        bannerDismissed = true
                        Task { await store.regenerateActiveNote() }
                    }
                )
            }

            editor
            generateAction
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        // Single-param onChange: the two-parameter variant is macOS 14+.
        .onChange(of: store.activeNoteLevel) { _ in bannerDismissed = false }
        .onChange(of: store.selectedMeetingId) { _ in bannerDismissed = false }
    }

    /// `.live` and the generated levels are two different storage channels, so
    /// they get two different bindings. Note that the binding setter only mirrors
    /// the value into the store; the *save* is driven by `onEdit`, which
    /// `NotesEditor` calls solely for edits originating in the text view. Wiring
    /// the save into both would schedule the debounced write twice per keystroke.
    /// Markdown source ⇄ rendered preview. A two-icon segmented control, so
    /// the current mode is always visible (a single morphing icon reads as
    /// "what will happen", which is ambiguous for a mode).
    /// The active tab's full Markdown, whatever channel it lives in.
    private var activeMarkdown: String {
        store.activeNoteLevel == .live ? store.currentLiveNotes : store.currentNotes
    }

    /// Copies the whole active note to the clipboard. Hidden with no selection,
    /// disabled on an empty note (copying nothing reads as a broken button).
    @ViewBuilder private var copyButton: some View {
        if store.selectedMeetingId != nil {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(activeMarkdown, forType: .string)
                justCopied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    justCopied = false
                }
            } label: {
                Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(justCopied ? Color.green : Color.secondary)
                    .frame(width: 26, height: 18)
                    .hoverHighlight(cornerRadius: 4)
            }
            .buttonStyle(.plain)
            .disabled(activeMarkdown.isEmpty)
            .opacity(activeMarkdown.isEmpty ? 0.4 : 1)
            .help("Copier tout le Markdown")
            .accessibilityLabel("Copier tout le Markdown")
            .padding(.trailing, 4)
        }
    }

    @ViewBuilder private var previewToggle: some View {
        if store.selectedMeetingId != nil {
            HStack(spacing: 0) {
                modeButton(icon: "pencil", active: !store.notesPreviewMode,
                           help: "Éditer le Markdown") { store.notesPreviewMode = false }
                modeButton(icon: "eye", active: store.notesPreviewMode,
                           help: "Aperçu rendu (lecture seule)") { store.notesPreviewMode = true }
            }
            .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.5)))
            .padding(.trailing, 10)
        }
    }

    @ViewBuilder private func modeButton(icon: String, active: Bool,
                                         help: String,
                                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(active ? Color.primary : Color.secondary)
                .frame(width: 26, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(active ? AnyShapeStyle(.background) : AnyShapeStyle(.clear))
                        .padding(1)
                )
                .hoverHighlight(cornerRadius: 4)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    @ViewBuilder private var editor: some View {
        let placeholder = NotesPanelRules.placeholder(for: store.activeNoteLevel,
                                                      transcriptState: transcriptState)
        if store.notesPreviewMode {
            MarkdownPreview(
                markdown: store.activeNoteLevel == .live ? store.currentLiveNotes
                                                         : store.currentNotes,
                placeholder: placeholder)
        } else if store.activeNoteLevel == .live {
            NotesEditor(
                text: Binding(get: { store.currentLiveNotes },
                              set: { store.currentLiveNotes = $0 }),
                placeholder: placeholder,
                onEdit: { store.onLiveNotesEdited($0) }
            )
        } else {
            NotesEditor(
                text: Binding(get: { store.currentNotes },
                              set: { store.currentNotes = $0 }),
                placeholder: placeholder,
                onEdit: { store.onNotesEdited($0) }
            )
        }
    }

    /// Status bar under the editor: in-progress spinner, generation error, or the
    /// inline "generate this note now" for the empty state (Task 40).
    ///
    /// A bar under the editor rather than a view that *replaces* it (which is
    /// what the plan's literal code does): the note stays editable by hand while
    /// Claude has produced nothing, and swapping the editor out on every
    /// keystroke that empties it would tear down and rebuild the `TextEditor`,
    /// losing the insertion point.
    ///
    /// Ordering matters: progress wins over a stale error, and the error wins
    /// over the generate button — offering "Générer maintenant" right under the
    /// message explaining why the last attempt failed would be an invitation to
    /// hit the same wall again.
    @ViewBuilder private var generateAction: some View {
        if store.isGeneratingNote {
            statusBar {
                ProgressView().controlSize(.small)
                Text("Génération en cours… (peut prendre une à deux minutes)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        } else if let err = store.generationError {
            statusBar {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(err)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("OK") { store.generationError = nil }
                    .controlSize(.small)
            }
        } else if NotesPanelRules.showsGenerateAction(
            level: store.activeNoteLevel,
            transcriptState: transcriptState,
            noteIsEmpty: store.currentNotes.isEmpty) {
            statusBar {
                Button("Générer maintenant") {
                    Task { await store.regenerateActiveNote() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder private func statusBar<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 8, content: content)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .overlay(Rectangle().fill(.separator).frame(height: 0.5), alignment: .top)
    }

    @ViewBuilder private func tab(_ t: NotesPanelRules.Tab) -> some View {
        let active = store.activeNoteLevel == t.level
        Button(action: { store.setActiveNoteLevel(t.level) }) {
            HStack(spacing: 6) {
                // A generation running on this level replaces the icon with a
                // spinner — that's what makes a *backgrounded* generation (the
                // user switched tab to launch another one) visible at all.
                if store.isGenerating(level: t.level) {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                } else {
                    Image(systemName: t.icon).font(.system(size: 11))
                }
                Text(t.title).font(.system(size: 12.5, weight: active ? .semibold : .medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 8).padding(.bottom, 2)
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .hoverHighlight()
            .overlay(
                Rectangle().fill(active ? Color.accentColor : .clear).frame(height: 2),
                alignment: .bottom
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Notes \(t.title)")
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    /// Auto-save indicator. Meaningless with nothing selected, so it hides.
    @ViewBuilder private var editStatus: some View {
        if store.selectedMeetingId != nil {
            Text("Enregistré")
                .font(.system(size: 10.5, design: .monospaced))
                // The plan's fixed dark green disappears against a dark
                // background; lighten it for dark mode.
                .foregroundStyle(colorScheme == .dark
                                 ? Color(red: 0.45, green: 0.80, blue: 0.52)
                                 : Color(red: 0.12, green: 0.48, blue: 0.20))
        }
    }
}
