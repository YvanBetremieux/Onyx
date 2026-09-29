import SwiftUI
import AppKit
import RecorderCore

struct MenuBarView: View {
    @ObservedObject var app: AppState

    var body: some View {
        Group {
            // Visible seulement en cas de problème : rien ne s'affiche quand
            // tout va bien.
            if app.claudeAuthStatus.isDisconnected {
                Button("⚠ Claude déconnecté — se reconnecter…") {
                    app.showSettings()
                }
                Divider()
            }
            switch app.uiState {
            case .idle:
                Button("Start recording") { app.toggleRecording() }
            case .recording:
                Text("Recording \(app.currentSlug ?? "")")
                Button("Stop recording") { app.toggleRecording() }
            case .transcribing:
                Text("Transcribing…")
                Button("Start new recording") { app.toggleRecording() }
            }
            Divider()
            // No key equivalents on any menu item: Onyx is click-only.
            Button("Open viewer…") { app.viewerController.show() }
            if app.uiState == .recording {
                // Routed through AppState, not straight to the viewer: only
                // AppState can name the meeting being recorded, and the viewer
                // must never guess (it would target the last-selected meeting
                // and overwrite its live notes).
                Button("Open live notes") { app.openLiveNotes() }
            }
            Divider()
            Button("Open meetings folder") {
                NSWorkspace.shared.open(app.settings.meetingsFolder)
            }
            Button("Settings…") { app.showSettings() }
            Button("Rescan meetings") {
                let storage = app.storage
                let indexer = app.indexer
                Task { try? await RescanRunner(storage: storage, indexer: indexer).rescan() }
            }
            Divider()

            Menu("Recent Meetings") {
                let recents = (try? app.indexer.recentMeetings(limit: 5)) ?? []
                if recents.isEmpty {
                    Text("No recordings yet").disabled(true)
                } else {
                    ForEach(recents, id: \.id) { m in
                        Menu(menuTitle(m)) {
                            Button("Open folder") {
                                NSWorkspace.shared.open(m.folderPath)
                            }
                            Button("Open transcript.md") {
                                let tr = m.folderPath.appendingPathComponent("transcripts")
                                    .appendingPathComponent("transcript.md")
                                NSWorkspace.shared.open(tr)
                            }
                            Menu("Regenerate notes as") {
                                // `generatable`, not `allCases`: `.live` is the
                                // user's own live.md and must never be a
                                // regeneration target.
                                ForEach(NoteLevel.generatable, id: \.self) { level in
                                    Button(level.rawValue.capitalized) {
                                        app.regenerateNotes(for: m.id, level: level)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Divider()
            Button("Quit Onyx") { NSApplication.shared.terminate(nil) }
        }
    }

    private func menuTitle(_ m: MeetingListing) -> String {
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
        let time = fmt.string(from: m.startedAt)
        let title = m.title?.isEmpty == false ? m.title! : "Untitled"
        return "\(time) — \(title)"
    }
}
