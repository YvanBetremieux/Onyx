import Foundation

@available(macOS 13.0, *)
public final class RecorderSession: RecordingSession, @unchecked Sendable {
    private let recorder: Recorder
    private let storage: MeetingStorage
    private let pipeline: Pipeline

    private var currentPaths: MeetingPaths?
    private var currentChunker: ChunkedTranscriber?
    private let lock = NSLock()

    /// Fired when the background pipeline started by `stop()` finishes.
    /// `error` is `nil` on success. Set once at wiring time (e.g. from AppState)
    /// so the UI can flip out of `.transcribing` and surface failures instead of
    /// leaving them silently swallowed.
    public var onPipelineFinished: (@Sendable (_ slug: String, _ error: Error?) -> Void)?

    /// Live chunked-transcription config, read at each recording start so a
    /// Settings change applies to the next recording. Nil (the default, and
    /// the "disabled" setting) records exactly as before — transcription
    /// happens entirely in the post-stop pipeline.
    public struct ChunkingConfig: Sendable {
        public let chunkSeconds: Double
        /// Shared, warm transcriber — the same instance the pipeline uses, so
        /// the model is loaded once and stays resident across both.
        public let whisper: any WhisperTranscribing
        public init(chunkSeconds: Double, whisper: any WhisperTranscribing) {
            self.chunkSeconds = chunkSeconds
            self.whisper = whisper
        }
    }
    public var chunkingConfig: (@Sendable () -> ChunkingConfig?)?
    /// Live transcription progress (slug, fraction 0…1), emitted by the
    /// chunker after each chunk — wired by AppState into the sidebar badge.
    public var onTranscriptionProgress: (@Sendable (String, Double) -> Void)?

    public init(recorder: Recorder, storage: MeetingStorage, pipeline: Pipeline) {
        self.recorder = recorder
        self.storage = storage
        self.pipeline = pipeline
    }

    public func start(meta: MeetingMetadata) async throws {
        Log.recorder.info(
            "RecorderSession.start: source=\(String(describing: meta.source), privacy: .public), title=\(meta.title ?? "<nil>", privacy: .public)")
        let paths = try await recorder.start()
        // Crash-recovery continuation: if an earlier recording of this very
        // call was interrupted (app crash/restart mid-meeting — its endedAt
        // was never written), this new recording is segment 2 of the same
        // meeting. Mark it so the pipeline's absorb step merges it back, and
        // inherit the identity segment 1 already had (calendar title/link).
        let parent = Self.findInterruptedParent(storage: storage,
                                                detectedCode: meta.detectedCode,
                                                excludingSlug: paths.slug)
        if let parent {
            Log.recorder.info(
                "RecorderSession.start: continuation of interrupted \(parent.id, privacy: .public)")
        }
        // Patch persisted metadata with the fields the orchestrator provided.
        try storage.patchMetadata({ m in
            m.title = meta.title ?? parent?.title
            m.source = meta.source == .detected ? (parent?.source ?? .detected) : meta.source
            m.calendarEventId = meta.calendarEventId ?? parent?.calendarEventId
            m.detectedApp = meta.detectedApp
            m.detectedCode = meta.detectedCode
            m.continuationOf = parent?.id
        }, at: paths)
        // Live transcription: slice-and-transcribe while recording, model
        // loaded once now and kept warm (see ChunkedTranscriber).
        var chunker: ChunkedTranscriber?
        if let cfg = chunkingConfig?() {
            let progress = onTranscriptionProgress
            let slug = paths.slug
            chunker = ChunkedTranscriber(paths: paths,
                                         chunkSeconds: cfg.chunkSeconds,
                                         whisper: cfg.whisper,
                                         onProgress: { p in progress?(slug, p) })
            await chunker?.start()
        }
        lock.lock(); currentPaths = paths; currentChunker = chunker; lock.unlock()
        Log.recorder.info("RecorderSession.start done for slug=\(paths.slug, privacy: .public)")
    }

    public func stop() async throws {
        let snapshotSlug: String?
        lock.lock(); snapshotSlug = currentPaths?.slug; lock.unlock()
        Log.recorder.info(
            "RecorderSession.stop: slug=\(snapshotSlug ?? "<nil>", privacy: .public)")
        let paths = try await recorder.stop()
        let chunker: ChunkedTranscriber?
        lock.lock(); chunker = currentChunker; currentPaths = nil; currentChunker = nil; lock.unlock()
        // Fire-and-forget pipeline so the orchestrator can return to .idle immediately.
        // Surface completion (success or failure) via `onPipelineFinished` so the UI
        // can flip out of `.transcribing` and surface failures. Without
        // this, a hung/failed pipeline (e.g. WhisperKit init blocked on a HF
        // tokenizer download) left the app in a silent broken state.
        let callback = onPipelineFinished
        Task.detached { [pipeline] in
            do {
                // Drain the live chunker first (final partial chunk + any
                // in-flight job) so the whisper steps find full coverage.
                // Inside the detached task on purpose: `stop()` must return
                // promptly for the orchestrator to go back to .idle.
                await chunker?.finish()
                try await pipeline.run(paths: paths)
                Log.pipeline.info("Pipeline finished OK for \(paths.slug, privacy: .public)")
                callback?(paths.slug, nil)
            } catch {
                Log.pipeline.error(
                    "Pipeline failed for \(paths.slug, privacy: .public): \(String(describing: error), privacy: .public)")
                callback?(paths.slug, error)
            }
        }
    }

    public func cancel() async throws {
        let snapshot: MeetingPaths?
        let chunker: ChunkedTranscriber?
        lock.lock()
        snapshot = currentPaths; chunker = currentChunker
        currentPaths = nil; currentChunker = nil
        lock.unlock()
        // No `finish()` — the meeting is being deleted, transcribing the tail
        // would be wasted work on files about to disappear.
        await chunker?.abort()
        Log.recorder.info(
            "RecorderSession.cancel: slug=\(snapshot?.slug ?? "<nil>", privacy: .public)")
        guard let paths = snapshot else { return }
        try await recorder.cancel(paths: paths)
    }

    /// The most recent meeting recording the same call (`detectedCode`) whose
    /// recording was *interrupted* — `endedAt` is only ever written by a clean
    /// `Recorder.stop()`, so nil + same code means the app died mid-meeting.
    /// The window guards against a reused personal Meet link: yesterday's
    /// never-resumed crash must not swallow today's meeting.
    static func findInterruptedParent(storage: MeetingStorage,
                                      detectedCode: String?,
                                      excludingSlug: String,
                                      now: Date = Date(),
                                      windowSeconds: TimeInterval = 4 * 3600) -> MeetingMetadata? {
        guard let code = detectedCode?.lowercased() else { return nil }
        let listings = (try? storage.listMeetings()) ?? []
        var best: MeetingMetadata?
        for listing in listings where listing.slug != excludingSlug {
            let paths = MeetingPaths(root: storage.root, slug: listing.slug)
            guard let m = try? storage.loadMetadata(paths),
                  m.endedAt == nil,
                  m.absorbed != true,
                  m.detectedCode?.lowercased() == code,
                  now.timeIntervalSince(m.startedAt) <= windowSeconds,
                  now.timeIntervalSince(m.startedAt) > 0
            else { continue }
            if best == nil || m.startedAt > best!.startedAt { best = m }
        }
        return best
    }

    public func patchMeta(_ mut: @Sendable (inout MeetingMetadata) -> Void) async throws {
        let snapshot: MeetingPaths?
        lock.lock(); snapshot = currentPaths; lock.unlock()
        guard let paths = snapshot else { return }
        try storage.patchMetadata(mut, at: paths)
    }
}
