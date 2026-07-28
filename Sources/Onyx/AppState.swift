import Foundation
import RecorderCore

@MainActor
public final class AppState: ObservableObject {
    public enum UIState { case idle, recording, transcribing }
    @Published public var uiState: UIState = .idle
    @Published public var currentSlug: String?
    @Published public var lastError: String?

    public let settings = SettingsStore()
    public let storage: MeetingStorage
    public let indexer: MeetingIndexer
    public let calendarWatcher: CalendarWatcher
    private let recorder: Recorder
    private let pipeline: Pipeline
    private let detectionCoordinator: DetectionCoordinator
    private let orchestrator: AutoTriggerOrchestrator

    public init() {
        storage = MeetingStorage(root: settings.meetingsFolder)
        let dbURL = FileManager.default.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask)[0]
            .appendingPathComponent("Onyx/index.sqlite")
        try? FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        indexer = try! MeetingIndexer(dbPath: dbURL)
        recorder = Recorder(storage: storage)

        // Build pipeline with optional notes config.
        let binaryURL: URL? = settings.claudeBinaryPath.isEmpty
            ? nil : URL(fileURLWithPath: settings.claudeBinaryPath)
        let notesCfg: NoteGenerationConfig? = (settings.autoNotesEnabled && binaryURL != nil)
            ? NoteGenerationConfig(binary: binaryURL, level: settings.defaultNoteLevel)
            : nil
        pipeline = Pipeline(storage: storage, notes: notesCfg)

        calendarWatcher = CalendarWatcher()

        var detectors: [any MeetingAppDetector] = []
        if settings.detectionMeetEnabled { detectors.append(MeetDetector()) }
        if settings.detectionHuddleEnabled { detectors.append(SlackHuddleDetector()) }
        detectionCoordinator = DetectionCoordinator(detectors: detectors)

        let session = RecorderSession(recorder: recorder, storage: storage, pipeline: pipeline)
        orchestrator = AutoTriggerOrchestrator(session: session)

        // Wire opt-out notification.
        let localOrch = orchestrator
        OptOutNotificationCenter.shared.optOutHandler = {
            try? await localOrch.optOut()
        }
        OptOutNotificationCenter.shared.configureIfNeeded()
    }

    public func toggleRecording() {
        Task {
            do {
                switch uiState {
                case .idle:
                    try await orchestrator.manualStart()
                    uiState = .recording
                case .recording:
                    try await orchestrator.manualStop()
                    uiState = .transcribing
                    // Pipeline runs in the background via RecorderSession.
                    uiState = .idle
                case .transcribing:
                    try await orchestrator.manualStart()
                    uiState = .recording
                }
            } catch {
                lastError = String(describing: error)
                uiState = .idle
            }
        }
    }

    public func bootAutotrigger() {
        guard settings.autoTriggerEnabled else { return }

        let orch = orchestrator
        let watcher = calendarWatcher
        let coordinator = detectionCoordinator
        let enabledIds = settings.enabledCalendarIds

        // Calendar loop.
        Task.detached {
            let matcher = CalendarMatcher(whitelistedCalendarIds: enabledIds)
            for await match in watcher.matches(matcher: matcher) {
                await MainActor.run {
                    OptOutNotificationCenter.shared.showRecordingStarted(title: match.title)
                }
                try? await orch.onCalendarEvent(match)
            }
        }

        // Detection loop.
        Task.detached {
            for await ev in coordinator.events() {
                if ev.kind == .started {
                    await MainActor.run {
                        OptOutNotificationCenter.shared.showRecordingStarted(title: "Meet/Huddle detected")
                    }
                }
                try? await orch.onCallEvent(ev)
            }
        }
    }

    public func regenerateNotes(for slug: String, level: NoteLevel) {
        Task {
            let path = settings.claudeBinaryPath
            guard !path.isEmpty else {
                self.lastError = "Claude binary path not configured"
                return
            }
            let binary = URL(fileURLWithPath: path)
            let paths = MeetingPaths(root: storage.root, slug: slug)
            let gen = ClaudeNoteGenerator()
            do {
                try await gen.generate(paths: paths, level: level, binary: binary)
            } catch {
                self.lastError = "Regenerate failed: \(String(describing: error))"
                OptOutNotificationCenter.shared.showNotesFailed(slug: slug)
            }
        }
    }

    public func resumePendingJobs() {
        let storage = self.storage
        let pipeline = self.pipeline
        Task {
            let listings = (try? storage.listMeetings()) ?? []
            for listing in listings {
                let paths = MeetingPaths(root: storage.root, slug: listing.slug)
                guard let job = try? storage.loadJob(paths), job.isResumable else { continue }
                try? await pipeline.run(paths: paths)
            }
        }
    }
}
