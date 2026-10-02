import Foundation
import AppKit
import RecorderCore
import ServiceManagement

public final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults

    @Published public var language: String {
        didSet { defaults.set(language, forKey: "language") }
    }
    @Published public var meetingsFolder: URL {
        didSet { defaults.set(meetingsFolder.path, forKey: "meetingsFolder") }
    }
    /// Stored under Sparkle's own key so that `automaticallyChecksForUpdates` and this toggle stay in sync.
    @Published public var autoUpdateEnabled: Bool {
        didSet { defaults.set(autoUpdateEnabled, forKey: "SUEnableAutomaticChecks") }
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
    /// Traitement de la voix d'Apple sur le micro (voir MicRecorder.Config).
    @Published public var micEchoCancellation: Bool {
        didSet { defaults.set(micEchoCancellation, forKey: MicRecorder.echoCancellationDefaultsKey) }
    }
    @Published public var detectionHuddleEnabled: Bool {
        didSet { defaults.set(detectionHuddleEnabled, forKey: "detectionHuddleEnabled") }
    }
    @Published public var claudeBinaryPath: String {
        didSet { defaults.set(claudeBinaryPath, forKey: "claudeBinaryPath") }
    }
    /// Model alias passed to `claude -p --model` (e.g. "haiku", "sonnet",
    /// "opus"). Empty string = let the CLI use its configured default.
    @Published public var claudeModel: String {
        didSet { defaults.set(claudeModel, forKey: "claudeModel") }
    }
    /// Levels auto-generated at the end of the pipeline. A set, not a single
    /// pick: the user can want brief + synthèse + détaillée at once (they run
    /// as parallel `claude -p` sessions). May be empty (auto-notes then
    /// produce nothing, which is a legitimate "off by default" state).
    @Published public var defaultNoteLevels: [NoteLevel] {
        didSet { defaults.set(defaultNoteLevels.map(\.rawValue), forKey: "defaultNoteLevels") }
    }
    /// "system" | "light" | "dark". Applied to `NSApp.appearance` — see
    /// `applyAppearance()`.
    @Published public var appearance: String {
        didSet {
            defaults.set(appearance, forKey: "appearance")
            applyAppearance()
        }
    }
    @Published public var enabledCalendarIds: [String] {
        didSet { defaults.set(enabledCalendarIds, forKey: "enabledCalendarIds") }
    }
    /// Live chunked transcription: slice + transcribe every `chunkMinutes`
    /// while recording, model kept resident. Off = classic post-stop pipeline.
    @Published public var chunkedTranscriptionEnabled: Bool {
        didSet { defaults.set(chunkedTranscriptionEnabled, forKey: "chunkedTranscriptionEnabled") }
    }
    /// Chunk duration in minutes (1…20). Bigger chunks = less concurrent load
    /// on a weaker machine, at the cost of a longer wait after the meeting.
    @Published public var chunkMinutes: Int {
        didSet { defaults.set(chunkMinutes, forKey: "chunkMinutes") }
    }
    /// Whisper variant id (a `ModelManifest` whisper asset id). Default is
    /// large-v3-turbo: ~4-6× faster for near-identical quality. Missing
    /// variants are downloaded on first use.
    @Published public var whisperModel: String {
        didSet { defaults.set(whisperModel, forKey: "whisperModel") }
    }

    /// Open Onyx automatically at session login (SMAppService). The didSet
    /// applies it immediately; the boot-time sync lives in `AppState`, NOT in
    /// this initializer — SettingsStore is also instantiated by E2ETrigger and
    /// the onboarding previews, and `SMAppService.mainApp` registers whatever
    /// executable is running, which must only ever be the real app.
    @Published public var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: "launchAtLogin")
            Self.applyLaunchAtLogin(launchAtLogin)
        }
    }

    /// Registers/unregisters the running app as a login item. Best-effort:
    /// registration can fail for a dev build launched outside /Applications —
    /// the toggle keeps its value and the next launch retries.
    public static func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("launchAtLogin: SMAppService failed: %@", String(describing: error))
        }
    }

    /// Pushes the theme choice onto the whole app. `NSApp.appearance = nil`
    /// means "follow the system", which is also the pre-feature behaviour.
    public func applyAppearance() {
        switch appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil
        }
    }

    /// `defaults` is injectable so tests can run against a throwaway suite
    /// instead of mutating the user's real preferences.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = defaults.string(forKey: "language") ?? "fr"
        let defaultFolder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Meetings")
        if let s = defaults.string(forKey: "meetingsFolder") {
            meetingsFolder = URL(fileURLWithPath: s)
        } else { meetingsFolder = defaultFolder }
        autoUpdateEnabled = defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true
        autoTriggerEnabled = defaults.object(forKey: "autoTriggerEnabled") as? Bool ?? true
        autoNotesEnabled = defaults.object(forKey: "autoNotesEnabled") as? Bool ?? true
        detectionMeetEnabled = defaults.object(forKey: "detectionMeetEnabled") as? Bool ?? true
        detectionHuddleEnabled = defaults.object(forKey: "detectionHuddleEnabled") as? Bool ?? true
        micEchoCancellation = defaults.bool(forKey: MicRecorder.echoCancellationDefaultsKey)
        claudeBinaryPath = defaults.string(forKey: "claudeBinaryPath") ?? ""
        claudeModel = defaults.string(forKey: "claudeModel") ?? ""
        appearance = defaults.string(forKey: "appearance") ?? "system"
        // Levels are coerced at the source: they are only ever *generation*
        // targets, and `.live` is the user's own notes/live.md — a stale or
        // hand-edited "live" on disk is dropped exactly once, here.
        if let raws = defaults.array(forKey: "defaultNoteLevels") as? [String] {
            defaultNoteLevels = raws.compactMap(NoteLevel.init(rawValue:))
                .filter { NoteLevel.generatable.contains($0) }
        } else {
            // Migration from the single-level era ("defaultNoteLevel" key):
            // the old pick becomes a one-element set, defaulting to synthèse.
            let old = defaults.string(forKey: "defaultNoteLevel")
                .flatMap(NoteLevel.init(rawValue:)) ?? .synthese
            defaultNoteLevels = [NoteLevel.generatable.contains(old) ? old : .synthese]
        }
        enabledCalendarIds = defaults.array(forKey: "enabledCalendarIds") as? [String] ?? []
        chunkedTranscriptionEnabled =
            defaults.object(forKey: "chunkedTranscriptionEnabled") as? Bool ?? true
        let mins = defaults.object(forKey: "chunkMinutes") as? Int ?? 5
        chunkMinutes = min(20, max(1, mins))
        whisperModel = defaults.string(forKey: "whisperModel")
            ?? ModelManifest.whisperLargeV3Turbo.id
        launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? true
    }
}
