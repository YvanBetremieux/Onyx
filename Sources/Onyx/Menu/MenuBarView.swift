import SwiftUI
import AppKit
import RecorderCore

struct MenuBarView: View {
    @ObservedObject var app: AppState

    var body: some View {
        Group {
            switch app.uiState {
            case .idle:
                Button("Start recording  ⌘⇧R") { app.toggleRecording() }
            case .recording:
                Text("Recording \(app.currentSlug ?? "")")
                Button("Stop recording  ⌘⇧R") { app.toggleRecording() }
            case .transcribing:
                Text("Transcribing…")
                Button("Start new recording  ⌘⇧R") { app.toggleRecording() }
            }
            Divider()
            Button("Open meetings folder") {
                NSWorkspace.shared.open(app.settings.meetingsFolder)
            }
            Button("Settings…") { openSettingsWindow() }
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
                                ForEach(NoteLevel.allCases, id: \.self) { level in
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

@MainActor func openSettingsWindow() {
    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
}
