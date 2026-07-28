import Foundation

public protocol WhisperTranscribing: Sendable {
    func transcribe(wavPath: URL, to jsonPath: URL) async throws
}

extension WhisperTranscriber: WhisperTranscribing {}

public struct NoteGenerationConfig: Sendable {
    public let generator: ClaudeNoteGenerator
    public let binary: URL?
    public let level: NoteLevel
    public init(generator: ClaudeNoteGenerator = ClaudeNoteGenerator(),
                binary: URL?,
                level: NoteLevel) {
        self.generator = generator
        self.binary = binary
        self.level = level
    }
}

public actor Pipeline {
    private let storage: MeetingStorage
    private let whisper: any WhisperTranscribing
    private let diarizer: any Diarizing
    private let notes: NoteGenerationConfig?

    public init(storage: MeetingStorage,
                whisper: any WhisperTranscribing = WhisperTranscriber(),
                diarizer: any Diarizing = Diarizer(),
                notes: NoteGenerationConfig? = nil) {
        self.storage = storage
        self.whisper = whisper
        self.diarizer = diarizer
        self.notes = notes
    }

    public func run(paths: MeetingPaths) async throws {
        try await runStep(.normalize, paths: paths, overall: .normalizing) {
            try Normalizer.normalize(input: paths.micWav, output: paths.micNormalized)
            try Normalizer.normalize(input: paths.systemWav, output: paths.systemNormalized)
        }
        try await runStep(.whisperMic, paths: paths, overall: .transcribing) {
            try await self.whisper.transcribe(wavPath: paths.micNormalized, to: paths.whisperMic)
        }
        try await runStep(.whisperSystem, paths: paths, overall: .transcribing) {
            try await self.whisper.transcribe(wavPath: paths.systemNormalized, to: paths.whisperSystem)
        }
        try await runStep(.diarize, paths: paths, overall: .diarizing) {
            try self.diarizer.diarize(wavPath: paths.systemNormalized, to: paths.diarization)
        }
        try await runStep(.merge, paths: paths, overall: .merging) {
            let mic  = try AtomicJSON.read([WhisperSegment].self, from: paths.whisperMic)
            let sys  = try AtomicJSON.read([WhisperSegment].self, from: paths.whisperSystem)
            let diar = try AtomicJSON.read([DiarSegment].self,   from: paths.diarization)
            let merged = Merger.merge(mic: mic, system: sys, diarization: diar)
            try AtomicJSON.write(merged, to: paths.transcriptJson)
        }
        try await runStep(.render, paths: paths, overall: .rendering) {
            let segs = try AtomicJSON.read([TranscriptSegment].self, from: paths.transcriptJson)
            let meta = try self.storage.loadMetadata(paths)
            let md = MarkdownRenderer.render(segments: segs, meetingStart: meta.startedAt,
                                             slug: paths.slug)
            try md.data(using: .utf8)!.write(to: paths.transcriptMd, options: .atomic)
        }
        try await runStep(.cleanup, paths: paths, overall: .cleanup) {
            try await Cleanup.run(paths: paths)
        }
        await runStepSoft(.notes, paths: paths, overall: .generatingNotes) {
            guard let cfg = self.notes, let binary = cfg.binary else { return }
            if FileManager.default.fileExists(atPath: paths.notesFile(cfg.level).path) { return }
            try await cfg.generator.generate(paths: paths, level: cfg.level, binary: binary)
        }
        var job = try storage.loadJob(paths)
        job.state = .done
        try storage.saveJob(job, at: paths)
        Log.pipeline.info("Pipeline done for \(paths.slug)")
    }

    private func runStepSoft(_ step: JobStep, paths: MeetingPaths,
                             overall: JobOverallState,
                             body: @Sendable () async throws -> Void) async {
        do {
            var job = try storage.loadJob(paths)
            if job.stepStatus(step) == .done {
                Log.pipeline.info("Skip \(step.rawValue) — already done for \(paths.slug)")
                return
            }
            job.state = overall
            job.markStarted(step)
            try storage.saveJob(job, at: paths)
            try await body()
            var updated = try storage.loadJob(paths)
            updated.markDone(step)
            try storage.saveJob(updated, at: paths)
        } catch {
            Log.pipeline.error("Soft step \(step.rawValue) failed: \(String(describing: error), privacy: .public)")
            if var job = try? storage.loadJob(paths) {
                job.markFailed(step, error: String(describing: error))
                // Reset overall state — soft failure must not contaminate .done.
                job.state = .done
                job.error = nil
                try? storage.saveJob(job, at: paths)
            }
        }
    }

    private func runStep(_ step: JobStep, paths: MeetingPaths,
                         overall: JobOverallState,
                         body: @Sendable () async throws -> Void) async throws {
        var job = try storage.loadJob(paths)
        if job.stepStatus(step) == .done {
            Log.pipeline.info("Skip \(step.rawValue) — already done for \(paths.slug)")
            return
        }
        job.state = overall
        job.markStarted(step)
        try storage.saveJob(job, at: paths)
        do {
            try await body()
            var updated = try storage.loadJob(paths)
            updated.markDone(step)
            try storage.saveJob(updated, at: paths)
        } catch {
            var updated = try storage.loadJob(paths)
            updated.markFailed(step, error: String(describing: error))
            try storage.saveJob(updated, at: paths)
            throw error
        }
    }
}
