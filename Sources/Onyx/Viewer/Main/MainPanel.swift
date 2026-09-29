import SwiftUI
import RecorderCore

/// The right-hand side of the viewer: meeting header over a resizable
/// notes | transcript split, with the audio scrubber underneath.
///
/// Note what this view deliberately does *not* read: `store.audioPlayer` and
/// `store.playhead` are handed to their consumers as objects, never dereferenced
/// here. Reading `store.audioPlayer.currentTime` in this body would invalidate
/// the header, both panels and the split ten times a second.
struct MainPanel: View {
    @ObservedObject var store: ViewerStore
    let currentDuration: Int?
    let currentSourceListing: MeetingListing?

    var body: some View {
        // With nothing selected there is no header, no notes and no transcript —
        // rendering the split anyway (as the plan's literal code does) leaves
        // three empty panes and a divider. Show only the empty state.
        Group {
            if let meeting = currentSourceListing {
                content(for: meeting)
            } else {
                EmptyStateView()
            }
        }
        .frame(minWidth: 640)
    }

    @ViewBuilder private func content(for meeting: MeetingListing) -> some View {
        VStack(spacing: 0) {
            MeetingHeaderView(
                meeting: meeting,
                duration: currentDuration,
                participants: MeetingHeaderView.participantInitials(
                    from: store.currentTranscript),
                // Also disabled while a generation is running: the store ignores
                // re-entrant calls anyway, but a clickable button that does
                // nothing is exactly the bug this state exists to prevent.
                regenerateEnabled: MeetingHeaderView.regenerateEnabled(
                    for: store.activeNoteLevel) && !store.isGeneratingNote,
                onRegenerate: { Task { await store.regenerateActiveNote() } },
                onRename: { store.renameSelectedMeeting($0) },
                mergedParts: store.currentMergedParts
            )
            .overlay(Rectangle().fill(.separator).frame(height: 0.5), alignment: .bottom)

            // Hidden panel → a clickable strip on the right edge to bring it
            // back. Open panel → no strip at all; collapsing goes through the
            // button in the transcript header.
            HStack(spacing: 0) {
                if store.transcriptPanelHidden {
                    NotesPanel(store: store, transcriptState: meeting.transcriptState)
                    PanelEdgeToggle(action: { store.toggleTranscriptPanel() })
                } else {
                    ResizableSplit(
                        ratio: Binding(get: { store.notesToTranscriptRatio },
                                       set: { store.setSplitRatio($0) }),
                        minLeading: 320, minTrailing: 280,
                        leading: {
                            NotesPanel(store: store,
                                       transcriptState: meeting.transcriptState)
                        },
                        trailing: {
                            TranscriptPanel(
                                store: store,
                                playhead: store.playhead,
                                onSeek: { store.seek(to: $0) },
                                onHide: { store.transcriptPanelHidden = true },
                                transcriptState: meeting.transcriptState
                            )
                            .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
                        }
                    )
                }
            }

            // Always mounted, even for a meeting with no audio: it then shows an
            // inert transport and an empty track, which is honest and keeps the
            // panel's height from jumping between meetings.
            AudioScrubberBar(player: store.audioPlayer, peaks: store.currentWaveform)
        }
    }
}

/// Shown when no meeting is selected — including on a first run with an empty
/// library, where the sidebar itself is empty too.
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Sélectionne un meeting dans la sidebar")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
    }
}
