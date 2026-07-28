import SwiftUI
import AppKit
import EventKit
import RecorderCore

struct SettingsWindow: View {
    @ObservedObject var settings: SettingsStore
    let storage: MeetingStorage
    let indexer: MeetingIndexer

    @State private var claudeTestResult: String = ""
    @State private var availableCalendars: [EKCalendar] = []

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            calendarTab.tabItem { Label("Calendar", systemImage: "calendar") }
            detectionTab.tabItem { Label("Detection", systemImage: "waveform") }
            notesTab.tabItem { Label("Notes", systemImage: "doc.text") }
            advancedTab.tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 560, height: 420)
        .onAppear { loadCalendars() }
    }

    // MARK: - Tabs

    @ViewBuilder private var generalTab: some View {
        Form {
            Section("Language") {
                Picker("Transcription language", selection: $settings.language) {
                    Text("Français").tag("fr")
                    Text("English").tag("en")
                    Text("Auto").tag("auto")
                }
            }
            Section("Storage") {
                LabeledContent("Meetings folder", value: settings.meetingsFolder.path)
                Button("Choose folder…") { pickFolder() }
                Button("Rescan meetings folder") {
                    let storage = self.storage
                    let indexer = self.indexer
                    Task { try? await RescanRunner(storage: storage, indexer: indexer).rescan() }
                }
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $settings.autoUpdateEnabled)
            }
        }
        .padding(16)
    }

    @ViewBuilder private var calendarTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable auto-trigger from calendar", isOn: $settings.autoTriggerEnabled)
            Text("Calendars to watch:").font(.headline)
            if availableCalendars.isEmpty {
                Text("No calendars available. Grant calendar access in onboarding or System Settings > Privacy > Calendars.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(availableCalendars, id: \.calendarIdentifier) { cal in
                            Toggle(cal.title, isOn: Binding(
                                get: { settings.enabledCalendarIds.contains(cal.calendarIdentifier) },
                                set: { on in
                                    var s = settings.enabledCalendarIds
                                    if on {
                                        if !s.contains(cal.calendarIdentifier) { s.append(cal.calendarIdentifier) }
                                    } else {
                                        s.removeAll { $0 == cal.calendarIdentifier }
                                    }
                                    settings.enabledCalendarIds = s
                                }
                            ))
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .padding(16)
    }

    @ViewBuilder private var detectionTab: some View {
        Form {
            Toggle("Detect Google Meet in browser", isOn: $settings.detectionMeetEnabled)
            Toggle("Detect Slack Huddles", isOn: $settings.detectionHuddleEnabled)
            Text("Note: Firefox and Slack web app are not detected v1.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
    }

    @ViewBuilder private var notesTab: some View {
        Form {
            Toggle("Auto-generate notes after recording", isOn: $settings.autoNotesEnabled)
            Picker("Default level", selection: Binding(
                get: { settings.defaultNoteLevel },
                set: { settings.defaultNoteLevel = $0 }
            )) {
                ForEach(NoteLevel.allCases, id: \.self) { l in
                    Text(l.rawValue.capitalized).tag(l)
                }
            }
            .pickerStyle(.segmented)
            HStack {
                TextField("Claude binary path", text: $settings.claudeBinaryPath)
                Button("Test") { testClaudeBinary() }
            }
            if !claudeTestResult.isEmpty {
                Text(claudeTestResult).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    @ViewBuilder private var advancedTab: some View {
        Form {
            Toggle("Auto-trigger master switch", isOn: $settings.autoTriggerEnabled)
            Button("Reset onboarding (V1 + V2)") {
                UserDefaults.standard.removeObject(forKey: "onboardingDone")
                UserDefaults.standard.removeObject(forKey: "onboardingV2Done")
            }
        }
        .padding(16)
    }

    // MARK: - Actions

    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let url = p.url { settings.meetingsFolder = url }
    }

    private func loadCalendars() {
        // Best-effort — returns empty if permission not granted, which is fine.
        availableCalendars = EKEventStore().calendars(for: .event)
    }

    private func testClaudeBinary() {
        let path = settings.claudeBinaryPath
        guard !path.isEmpty else { claudeTestResult = "Path is empty."; return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["--version"]
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do {
            try p.run(); p.waitUntilExit()
            let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
            let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            claudeTestResult = p.terminationStatus == 0
                ? "OK: \(s)"
                : "Exit \(p.terminationStatus): \(s)"
        } catch {
            claudeTestResult = "Failed to launch: \(error.localizedDescription)"
        }
    }
}
