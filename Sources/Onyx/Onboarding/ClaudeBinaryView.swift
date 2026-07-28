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
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .onAppear { detectBinary() }
    }

    private func detectBinary() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [URL] = [
            home.appendingPathComponent(".claude/local/claude"),
            home.appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c.path) {
            detected = "Found: \(c.path)"
            settings.claudeBinaryPath = c.path
            return
        }
        // Login-shell PATH lookup as fallback.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-lc", "which claude"]
        let out = Pipe(); proc.standardOutput = out; proc.standardError = Pipe()
        do {
            try proc.run(); proc.waitUntilExit()
        } catch {
            detected = "Claude not found — auto notes disabled. Set manually later in Settings."
            return
        }
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if proc.terminationStatus == 0, !s.isEmpty {
            detected = "Found via shell: \(s)"
            settings.claudeBinaryPath = s
        } else {
            detected = "Claude not found — auto notes disabled. Set manually later in Settings."
        }
    }
}
