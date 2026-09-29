import SwiftUI
import RecorderCore

struct ClaudeBinaryView: View {
    let settings: SettingsStore
    let onDone: () -> Void
    @State private var detected: String = "Searching…"
    @State private var custom: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Code binary").font(.title2).bold()
            Text("Onyx spawns `claude -p` to generate meeting notes. Locating your installation:")
            Text(detected).font(.system(.body, design: .monospaced))
            HStack {
                TextField("Or paste a path…", text: $custom)
                Button("Use") {
                    settings.claudeBinaryPath = custom
                    detected = "Using: \(custom)"
                }
            }
            HStack {
                Spacer()
                Button("Continue") { onDone() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(30)
        .onAppear { detectBinary() }
    }

    private func detectBinary() {
        Task {
            if let found = await ClaudeBinaryLocator().locate() {
                detected = "Found: \(found.path)"
                settings.claudeBinaryPath = found.path
            } else {
                detected = "Claude not found — auto notes disabled. Set manually later in Settings."
            }
        }
    }
}
