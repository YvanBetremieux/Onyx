import SwiftUI
import EventKit
import RecorderCore

struct CalendarPickerView: View {
    let settings: SettingsStore
    let onDone: () -> Void

    @State private var selected: Set<String> = []
    @State private var calendars: [EKCalendar] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick calendars to watch").font(.title2).bold()
            Text("Onyx will only auto-record events in the calendars you check.")
                .foregroundStyle(.secondary)
            if calendars.isEmpty {
                Text("No calendars found. You can enable them later in Settings > Calendar.")
                    .foregroundStyle(.secondary).font(.caption)
            } else {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(calendars, id: \.calendarIdentifier) { cal in
                            Toggle(cal.title, isOn: Binding(
                                get: { selected.contains(cal.calendarIdentifier) },
                                set: { on in
                                    if on { selected.insert(cal.calendarIdentifier) }
                                    else { selected.remove(cal.calendarIdentifier) }
                                }
                            ))
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            HStack {
                Spacer()
                Button("Continue") {
                    settings.enabledCalendarIds = Array(selected)
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .onAppear { loadCalendars() }
    }

    private func loadCalendars() {
        let store = EKEventStore()
        calendars = store.calendars(for: .event)
        // Pre-select those whose name contains "work" or "travail" (case-insensitive).
        let auto = calendars
            .filter { c in
                c.title.range(of: "work", options: .caseInsensitive) != nil
                || c.title.range(of: "travail", options: .caseInsensitive) != nil
            }
            .map(\.calendarIdentifier)
        selected = Set(auto)
    }
}
