import SwiftUI

struct BrowserAutomationView: View {
    let onDone: () -> Void
    @State private var results: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Browser detection permissions").font(.title2).bold()
            Text("""
                Onyx uses AppleScript to see when a Google Meet tab is open. \
                macOS will show a permission popup for each browser we probe \
                — click OK for the ones you use.
                """).multilineTextAlignment(.leading)
            Button("Probe browsers") { probe() }
            if !results.isEmpty {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(results, id: \.self) { r in
                            Text(r).font(.system(.body, design: .monospaced))
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
            HStack {
                Spacer()
                Button("Continue") { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
    }

    private func probe() {
        results.removeAll()
        let bundles = [
            "com.google.Chrome",
            "com.apple.Safari",
            "company.thebrowser.Browser",
            "com.brave.Browser",
        ]
        for b in bundles {
            let script = "tell application id \"\(b)\" to return name"
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            let out = Pipe(); proc.standardOutput = out; proc.standardError = out
            do {
                try proc.run(); proc.waitUntilExit()
            } catch {
                results.append("\(b): \(error.localizedDescription)")
                continue
            }
            let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
            let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            results.append("\(b): \(proc.terminationStatus == 0 ? "OK — \(s)" : "denied/not installed")")
        }
    }
}
