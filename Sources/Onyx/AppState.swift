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
    private let recorder: Recorder
    private let pipeline: Pipeline

    public init() {
        storage = MeetingStorage(root: settings.meetingsFolder)
        let dbURL = FileManager.default.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask)[0]
            .appendingPathComponent("Onyx/index.sqlite")
        try? FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        indexer = try! MeetingIndexer(dbPath: dbURL)
        recorder = Recorder(storage: storage)
        pipeline = Pipeline(storage: storage)
    }

    public func toggleRecording() {
        Task {
            do {
                switch uiState {
                case .idle:
                    let paths = try await recorder.start()
                    currentSlug = paths.slug
                    uiState = .recording
                case .recording:
                    let paths = try await recorder.stop()
                    uiState = .transcribing
                    try await pipeline.run(paths: paths)
                    let meta = try storage.loadMetadata(paths)
                    let segs = (try? AtomicJSON.read([TranscriptSegment].self,
                                                     from: paths.transcriptJson)) ?? []
                    try indexer.upsert(meta: meta, folderPath: paths.root,
                                       transcriptState: "done", transcript: segs)
                    currentSlug = nil
                    uiState = .idle
                case .transcribing:
                    let paths = try await recorder.start()
                    currentSlug = paths.slug
                    uiState = .recording
                }
            } catch {
                lastError = String(describing: error)
                uiState = .idle
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
