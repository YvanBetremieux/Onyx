import Foundation
import RecorderCore

public final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published public var language: String {
        didSet { defaults.set(language, forKey: "language") }
    }
    @Published public var meetingsFolder: URL {
        didSet { defaults.set(meetingsFolder.path, forKey: "meetingsFolder") }
    }
    @Published public var autoUpdateEnabled: Bool {
        didSet { defaults.set(autoUpdateEnabled, forKey: "autoUpdate") }
    }
    @Published public var autoTriggerEnabled: Bool {
        didSet { defaults.set(autoTriggerEnabled, forKey: "autoTriggerEnabled") }
    }
    @Published public var autoNotesEnabled: Bool {
        didSet { defaults.set(autoNotesEnabled, forKey: "autoNotesEnabled") }
    }
    @Published public var detectionMeetEnabled: Bool {
        didSet { defaults.set(detectionMeetEnabled, forKey: "detectionMeetEnabled") }
    }
    @Published public var detectionHuddleEnabled: Bool {
        didSet { defaults.set(detectionHuddleEnabled, forKey: "detectionHuddleEnabled") }
    }
    @Published public var claudeBinaryPath: String {
        didSet { defaults.set(claudeBinaryPath, forKey: "claudeBinaryPath") }
    }
    @Published public var defaultNoteLevel: NoteLevel {
        didSet { defaults.set(defaultNoteLevel.rawValue, forKey: "defaultNoteLevel") }
    }
    @Published public var enabledCalendarIds: [String] {
        didSet { defaults.set(enabledCalendarIds, forKey: "enabledCalendarIds") }
    }

    public init() {
        language = defaults.string(forKey: "language") ?? "fr"
        let defaultFolder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Meetings")
        if let s = defaults.string(forKey: "meetingsFolder") {
            meetingsFolder = URL(fileURLWithPath: s)
        } else { meetingsFolder = defaultFolder }
        autoUpdateEnabled = defaults.object(forKey: "autoUpdate") as? Bool ?? true
        autoTriggerEnabled = defaults.object(forKey: "autoTriggerEnabled") as? Bool ?? true
        autoNotesEnabled = defaults.object(forKey: "autoNotesEnabled") as? Bool ?? true
        detectionMeetEnabled = defaults.object(forKey: "detectionMeetEnabled") as? Bool ?? true
        detectionHuddleEnabled = defaults.object(forKey: "detectionHuddleEnabled") as? Bool ?? true
        claudeBinaryPath = defaults.string(forKey: "claudeBinaryPath") ?? ""
        if let raw = defaults.string(forKey: "defaultNoteLevel"),
           let lvl = NoteLevel(rawValue: raw) {
            defaultNoteLevel = lvl
        } else {
            defaultNoteLevel = .synthese
        }
        enabledCalendarIds = defaults.array(forKey: "enabledCalendarIds") as? [String] ?? []
    }
}
