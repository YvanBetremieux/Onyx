import Foundation

@available(macOS 13.0, *)
public final class RecorderSession: RecordingSession, @unchecked Sendable {
    private let recorder: Recorder
    private let storage: MeetingStorage
    private let pipeline: Pipeline

    private var currentPaths: MeetingPaths?
    private let lock = NSLock()

    public init(recorder: Recorder, storage: MeetingStorage, pipeline: Pipeline) {
        self.recorder = recorder
        self.storage = storage
        self.pipeline = pipeline
    }

    public func start(meta: MeetingMetadata) async throws {
        let paths = try await recorder.start()
        // Patch persisted metadata with the fields the orchestrator provided.
        try storage.patchMetadata({ m in
            m.title = meta.title
            m.source = meta.source
            m.calendarEventId = meta.calendarEventId
            m.detectedApp = meta.detectedApp
            m.detectedCode = meta.detectedCode
        }, at: paths)
        lock.lock(); currentPaths = paths; lock.unlock()
    }

    public func stop() async throws {
        let paths = try await recorder.stop()
        lock.lock(); currentPaths = nil; lock.unlock()
        // Fire-and-forget pipeline so the orchestrator can return to .idle immediately.
        Task.detached { [pipeline] in
            do { try await pipeline.run(paths: paths) }
            catch {
                // Pipeline logs its own errors via Log.pipeline; we swallow here
                // since RecordingSession's contract is only about capture.
                _ = error
            }
        }
    }

    public func cancel() async throws {
        let snapshot: MeetingPaths?
        lock.lock(); snapshot = currentPaths; currentPaths = nil; lock.unlock()
        guard let paths = snapshot else { return }
        try await recorder.cancel(paths: paths)
    }

    public func patchMeta(_ mut: @Sendable (inout MeetingMetadata) -> Void) async throws {
        let snapshot: MeetingPaths?
        lock.lock(); snapshot = currentPaths; lock.unlock()
        guard let paths = snapshot else { return }
        try storage.patchMetadata(mut, at: paths)
    }
}
