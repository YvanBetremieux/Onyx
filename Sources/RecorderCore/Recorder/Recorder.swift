import Foundation

@available(macOS 13.0, *)
public final class Recorder {
    public enum State: String { case idle, recording, stopping }

    public private(set) var state: State = .idle
    public private(set) var paths: MeetingPaths?
    public private(set) var startedAt: Date?

    private let storage: MeetingStorage
    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()
    private var flushTimer: Timer?

    public init(storage: MeetingStorage) { self.storage = storage }

    public func start() async throws -> MeetingPaths {
        precondition(state == .idle, "Recorder must be idle to start")
        let now = Date()
        let paths = try storage.createMeeting(startedAt: now)
        self.paths = paths; self.startedAt = now
        state = .recording

        try mic.start(writingTo: paths.micWav)
        try await system.start(writingTo: paths.systemWav)

        flushTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            try? self?.mic.flushHeader()
            try? self?.system.flushHeader()
        }
        Log.recorder.info("Recorder started for \(paths.slug)")
        return paths
    }

    public func stop() async throws -> MeetingPaths {
        guard state == .recording, let paths, let startedAt else {
            throw NSError(domain: "Onyx", code: 200,
                          userInfo: [NSLocalizedDescriptionKey: "Not recording"])
        }
        state = .stopping
        flushTimer?.invalidate(); flushTimer = nil
        try mic.stop()
        try await system.stop()

        var meta = try storage.loadMetadata(paths)
        let end = Date()
        meta.endedAt = end
        meta.durationSeconds = Int(end.timeIntervalSince(startedAt))
        try storage.saveMetadata(meta, at: paths)

        var job = try storage.loadJob(paths)
        job.state = .normalizing
        try storage.saveJob(job, at: paths)

        state = .idle
        Log.recorder.info("Recorder stopped, duration=\(meta.durationSeconds ?? 0)s")
        return paths
    }

    /// Cancels an ongoing recording — stops the mic/system capture without running
    /// the pipeline, and deletes the meeting folder entirely. Used by the auto-trigger
    /// opt-out flow within ~30s of start.
    public func cancel(paths: MeetingPaths) async throws {
        flushTimer?.invalidate()
        flushTimer = nil
        // Best-effort — errors on the cancel path are logged and swallowed.
        do { try mic.stop() } catch {
            Log.recorder.warning("mic.stop on cancel: \(String(describing: error), privacy: .public)")
        }
        do { try await system.stop() } catch {
            Log.recorder.warning("system.stop on cancel: \(String(describing: error), privacy: .public)")
        }
        try FileManager.default.removeItem(at: paths.root)
        self.paths = nil
        self.startedAt = nil
        state = .idle
    }
}
