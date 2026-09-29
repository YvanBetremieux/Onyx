import Foundation

@available(macOS 13.0, *)
public actor Recorder {
    public enum State: String { case idle, recording, stopping }

    public enum RecorderError: Error, Equatable {
        /// start() called while a recording is already in progress.
        /// Recoverable error — NOT a precondition (would crash in production).
        case notIdle
        case notRecording
    }

    public private(set) var state: State = .idle
    public private(set) var paths: MeetingPaths?
    public private(set) var startedAt: Date?

    /// Fired when a writer is sealed (size cap or repeated write failures).
    /// Wired by AppState toward a graceful stop via the orchestrator.
    private var onSizeCapReached: (@Sendable () -> Void)?
    public func setSizeCapHandler(_ h: @escaping @Sendable () -> Void) {
        onSizeCapReached = h
    }

    private let storage: MeetingStorage
    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()
    private var flushTask: Task<Void, Never>?

    public init(storage: MeetingStorage) { self.storage = storage }

    public func start() async throws -> MeetingPaths {
        guard state == .idle else { throw RecorderError.notIdle }
        let now = Date()
        let paths = try storage.createMeeting(startedAt: now)
        self.paths = paths; self.startedAt = now
        state = .recording

        do {
            // System first: SCShareableContent + startCapture is the slow path
            // (0.5–2s). Starting mic after keeps both WAV timelines aligned
            // to within a few ms (Merger sorts by relative timestamps).
            try await system.start(writingTo: paths.systemWav)
            try mic.start(writingTo: paths.micWav)
        } catch {
            // Rollback: never leave recorder half-started.
            try? mic.stop()
            try? await system.stop()
            try? FileManager.default.removeItem(at: paths.root)
            self.paths = nil; self.startedAt = nil
            state = .idle
            throw error
        }

        flushTask = Task { [weak self] in
            var capReported = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { return }
                guard let self else { return }
                await self.flushHeaders()
                if !capReported, await self.anyWriterSealed() {
                    capReported = true
                    Log.recorder.error(
                        "Recorder: a writer was sealed; forwarding stop request")
                    await self.fireSizeCap()
                }
            }
        }

        Log.recorder.info("Recorder started for \(paths.slug, privacy: .public)")
        return paths
    }

    public func stop() async throws -> MeetingPaths {
        guard state == .recording, let paths, let startedAt else {
            throw RecorderError.notRecording
        }
        state = .stopping
        flushTask?.cancel()
        await flushTask?.value
        flushTask = nil

        // Best-effort: even if one side fails, finalize the other and persist the job.
        do { try mic.stop() } catch {
            Log.recorder.error("mic.stop failed: \(String(describing: error), privacy: .public)")
        }
        do { try await system.stop() } catch {
            Log.recorder.error("system.stop failed: \(String(describing: error), privacy: .public)")
        }

        do {
            var meta = try storage.loadMetadata(paths)
            let end = Date()
            meta.endedAt = end
            meta.durationSeconds = Int(end.timeIntervalSince(startedAt))
            try storage.saveMetadata(meta, at: paths)
            var job = try storage.loadJob(paths)
            job.markStarted(.normalize)
            try storage.saveJob(job, at: paths)
        } catch {
            Log.recorder.error("Recorder.stop persist failed: \(String(describing: error), privacy: .public)")
        }

        self.paths = nil; self.startedAt = nil
        state = .idle
        Log.recorder.info("Recorder stopped for \(paths.slug, privacy: .public)")
        return paths
    }

    public func cancel(paths: MeetingPaths) async throws {
        flushTask?.cancel()
        await flushTask?.value
        flushTask = nil
        try? mic.stop()
        try? await system.stop()
        try? FileManager.default.removeItem(at: paths.root)
        self.paths = nil; self.startedAt = nil
        state = .idle
        Log.recorder.info("Recorder cancelled for \(paths.slug, privacy: .public)")
    }

    // MARK: - Private helpers (called from flushTask, must be actor-isolated)

    private func flushHeaders() {
        try? mic.flushHeader()
        try? system.flushHeader()
    }

    private func anyWriterSealed() -> Bool {
        mic.sizeCapReached || system.sizeCapReached
    }

    private func fireSizeCap() {
        onSizeCapReached?()
    }
}
