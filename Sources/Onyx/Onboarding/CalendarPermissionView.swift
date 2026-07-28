import SwiftUI
import RecorderCore

struct CalendarPermissionView: View {
    let onDone: (Bool) -> Void
    @State private var status: String = "Onyx needs access to your calendars to auto-start recording."
    @State private var requesting = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Calendar access").font(.title2).bold()
            Text(status).multilineTextAlignment(.center)
            HStack {
                Button("Skip") { onDone(false) }
                Button("Grant access") {
                    requesting = true
                    Task {
                        let watcher = CalendarWatcher()
                        let ok = await watcher.requestAccess()
                        await MainActor.run {
                            status = ok
                                ? "Granted."
                                : "Denied — can be enabled later in System Settings."
                            requesting = false
                            onDone(ok)
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(requesting)
            }
        }
        .padding(40)
    }
}
