import Foundation

public protocol WhisperTranscribing: Sendable {
    func transcribe(wavPath: URL, to jsonPath: URL) async throws
}

extension WhisperTranscriber: WhisperTranscribing {}

public struct NoteGenerationConfig: Sendable {
    public let generator: ClaudeNoteGenerator
    public let binary: URL?
    /// Levels to auto-generate — one independent `claude -p` session each,
    /// run in parallel by the notes step. May be empty (generate nothing).
    public let levels: [NoteLevel]
    /// Model alias for `claude --model`; nil = the CLI's own default.
    public let model: String?
    /// Destinataire des succès/échecs d'authentification. Optionnel : les tests
    /// et les call sites qui n'en ont pas besoin passent `nil`.
    public let authMonitor: ClaudeAuthMonitor?

    public init(generator: ClaudeNoteGenerator = ClaudeNoteGenerator(),
                binary: URL?,
                levels: [NoteLevel],
                model: String? = nil,
                authMonitor: ClaudeAuthMonitor? = nil) {
        self.generator = generator
        self.binary = binary
        self.levels = levels
        self.model = model
        self.authMonitor = authMonitor
    }

    /// Single-level convenience, kept for the chantier-2 call sites and tests.
    public init(generator: ClaudeNoteGenerator = ClaudeNoteGenerator(),
                binary: URL?,
                level: NoteLevel,
                authMonitor: ClaudeAuthMonitor? = nil) {
        self.init(generator: generator, binary: binary, levels: [level], authMonitor: authMonitor)
    }
}

public actor Pipeline {
    private let storage: MeetingStorage
    private let whisper: any WhisperTranscribing
    private let diarizer: any Diarizing
    private var notes: NoteGenerationConfig?
    /// Fired on every overall-state transition (slug, new state) — including
    /// the terminal `.done` / `.failed`. This is what gives the UI its live
    /// "Transcription…" / "Génération des notes…" status without polling
    /// job.json. Best-effort: no observer, no cost.
    private var stateObserver: (@Sendable (String, JobOverallState) -> Void)?

    public func setStateObserver(
        _ observer: (@Sendable (String, JobOverallState) -> Void)?
    ) {
        self.stateObserver = observer
    }

    public init(storage: MeetingStorage,
                whisper: any WhisperTranscribing = WhisperTranscriber(),
                diarizer: any Diarizing = Diarizer(),
                notes: NoteGenerationConfig? = nil) {
        self.storage = storage
        self.whisper = whisper
        self.diarizer = diarizer
        self.notes = notes
    }

    // MARK: - Job serialization + recording gate
    //
    // The actor is reentrant at suspension points, so without an explicit
    // guard two `run(paths:)` calls (post-stop + resumePendingJobs) interleave
    // and their whisper/diarization steps run concurrently — that saturated
    // CPU + ANE during live meetings (CoreML timeouts, detector timeouts
    // falsely ending recordings). Two mechanisms:
    //
    // 1. `isRunningJob` + FIFO `jobWaiters`: at most ONE job runs at a time;
    //    concurrent callers queue and the slot is handed over in order.
    // 2. `recordingActive` + `gateWaiters`: while a recording is live, no new
    //    STEP starts (checked at the top of runStep/runStepSoft, the natural
    //    pause boundary) — a mid-run job finishes its current step then waits.
    //    AppState flips this from the orchestrator's state transitions.
    private var isRunningJob = false
    private var jobWaiters: [CheckedContinuation<Void, Never>] = []
    private var recordingActive = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    /// Pauses/resumes pipeline work around a live recording. While active,
    /// no new job and no new step starts; setting it back to false resumes
    /// everything that was waiting.
    public func setRecordingActive(_ active: Bool) {
        recordingActive = active
        if !active {
            let waiters = gateWaiters
            gateWaiters = []
            for w in waiters { w.resume() }
        }
    }

    private func acquireJobSlot() async {
        if !isRunningJob {
            isRunningJob = true
            return
        }
        // The releaser hands the slot to the first waiter directly
        // (isRunningJob stays true), so this is strictly FIFO. Deliberately
        // NOT cancellation-aware (Never-throwing continuation): a cancelled
        // caller still waits its turn — do not rely on Task cancellation
        // to abandon a queued job.
        await withCheckedContinuation { jobWaiters.append($0) }
    }

    private func releaseJobSlot() {
        if jobWaiters.isEmpty {
            isRunningJob = false
        } else {
            jobWaiters.removeFirst().resume()
        }
    }

    private func waitWhileRecording() async {
        while recordingActive {
            await withCheckedContinuation { gateWaiters.append($0) }
        }
    }

    public func run(paths: MeetingPaths) async throws {
        await acquireJobSlot()
        defer { releaseJobSlot() }
        try await prepareRetryIfFailed(paths: paths)
        try await runSteps(paths: paths)
    }

    /// A job persisted as `.failed` (e.g. a transient CoreML/ANE timeout
    /// killed the whisper step) is retried: one retry is consumed, failed
    /// steps go back to `.pending`, and the run proceeds normally — `.done`
    /// steps are still skipped by `runStep`. `resumePendingJobs` only calls
    /// `run` while `isResumable` is true, so `JobState.maxRetries` bounds
    /// the number of automatic attempts. Retrying ANY failure — not just
    /// transient ones — is deliberate: a deterministic failure just burns
    /// the bounded budget and the job is then left alone.
    private func prepareRetryIfFailed(paths: MeetingPaths) async throws {
        var job = try storage.loadJob(paths)
        guard job.state == .failed else { return }
        job.prepareRetry()
        try storage.saveJob(job, at: paths)
        Log.pipeline.info(
            "Retrying failed job \(paths.slug, privacy: .public) (attempt \(job.retryCount)/\(JobState.maxRetries))")
    }

    private func runSteps(paths: MeetingPaths) async throws {
        try await runStep(.normalize, paths: paths, overall: .normalizing) {
            try Normalizer.normalize(input: paths.micWav, output: paths.micNormalized)
            try Normalizer.normalize(input: paths.systemWav, output: paths.systemNormalized)
        }
        // Whisper and diarization are independent (whisper reads the chunks /
        // normalized WAVs, diarization reads the system WAV) and use disjoint
        // hardware (ANE/GPU vs CPU) — run them CONCURRENTLY. Sequential, the
        // diarization used to start only after the whisper tail; now it is
        // fully hidden behind it (or vice versa). Safe on job.json: each
        // runStep's read-modify-write is synchronous, so the actor serializes
        // them despite the interleaving at await points.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.runStep(.diarize, paths: paths, overall: .diarizing) {
                    // Move blocking sherpa-onnx C call off the Swift cooperative
                    // thread pool to avoid starving other async tasks.
                    let diarizer = self.diarizer
                    let src = paths.systemNormalized
                    let dst = paths.diarization
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        DispatchQueue.global(qos: .userInitiated).async {
                            do {
                                try diarizer.diarize(wavPath: src, to: dst)
                                continuation.resume()
                            } catch {
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                }
            }
            group.addTask {
                // Live-transcribed chunks (see ChunkedTranscriber) are used when
                // they cover the whole recording; otherwise classic full-file
                // whisper. The duration reference is the WAV itself, not
                // meta.json — it is what the chunks were actually cut from.
                try await self.runStep(.whisperMic, paths: paths, overall: .transcribing) {
                    let duration = ChunkWav.availableSeconds(in: paths.micWav)
                    if let segments = ChunkAssembly.assembledSegments(
                        paths: paths, channel: .mic, durationSeconds: duration) {
                        Log.pipeline.info("whisper_mic assembled from chunks for \(paths.slug, privacy: .public)")
                        try AtomicJSON.write(segments, to: paths.whisperMic)
                    } else {
                        try await self.whisper.transcribe(wavPath: paths.micNormalized, to: paths.whisperMic)
                    }
                }
                try await self.runStep(.whisperSystem, paths: paths, overall: .transcribing) {
                    let duration = ChunkWav.availableSeconds(in: paths.systemWav)
                    if let segments = ChunkAssembly.assembledSegments(
                        paths: paths, channel: .system, durationSeconds: duration) {
                        Log.pipeline.info("whisper_system assembled from chunks for \(paths.slug, privacy: .public)")
                        try AtomicJSON.write(segments, to: paths.whisperSystem)
                    } else {
                        try await self.whisper.transcribe(wavPath: paths.systemNormalized, to: paths.whisperSystem)
                    }
                }
            }
            try await group.waitForAll()
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

            // Pre-compute the waveform for the viewer's scrubber. Uses the
            // normalized mic WAV — same file the transcriber runs on, so it
            // exists at this point. Failure is non-fatal: the viewer falls
            // back to on-the-fly generation if this file is missing.
            //
            // Generation is a synchronous full re-read of the WAV (multiple
            // seconds for a 2-hour recording), so it runs off the actor's
            // executor — same pattern as the `.diarize` step above — otherwise
            // it would block every other call into the actor, including
            // `setNotesConfig` from the MainActor, hanging the UI.
            do {
                let src = paths.micNormalized
                let dst = paths.waveformJson
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let wf = try WaveformGenerator.generate(from: src,
                                                                    bucketSizeMs: 50)
                            try wf.write(to: dst)
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } catch {
                Log.pipeline.warning(
                    "Waveform generation failed for \(paths.slug, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        try await runStep(.cleanup, paths: paths, overall: .cleanup) {
            try await Cleanup.run(paths: paths)
        }
        let notesCfg = self.notes
        let storage = self.storage
        await runStepSoft(.notes, paths: paths, overall: .generatingNotes) {
            guard let cfg = notesCfg, let binary = cfg.binary else { return }
            let meta = try storage.loadMetadata(paths)
            // One independent `claude -p` session per configured level, in
            // parallel — they write disjoint files (notes/<level>.md). Levels
            // already generated (resume after crash) are skipped.
            let todo = cfg.levels.filter { level in
                level != .live
                    && !FileManager.default.fileExists(atPath: paths.notesFile(level).path)
            }
            guard !todo.isEmpty else { return }
            // Titre auto : les meetings calendar gardent le titre de
            // l'événement ; huddles et meetings sauvages démarrent sans titre,
            // Claude en déduit un du transcript pendant la session du niveau
            // porteur. Voir `MeetingMetadata.wantsTitleDetection`.
            let titleCarrier = NoteLevel.titleCarrier(among: todo)
            // Le groupe est vidé jusqu'au bout plutôt que laissé lever tôt
            // (`withThrowingTaskGroup` + `for try await`) : avec plusieurs
            // niveaux, un échec non-auth (timeout, sortie vide) sur un niveau
            // peut sinon gagner la course contre un échec d'auth sur un autre
            // niveau — et `ClaudeAuthMonitor.reportFailure` ignore
            // volontairement les échecs non-auth, donc le vrai signal d'auth
            // disparaîtrait silencieusement. Laisser le groupe lever tôt
            // abandonnerait aussi les process `claude` frères en plein vol
            // (leur boucle de sondage dans `runClaude` lève sur annulation,
            // laissant le process orphelin).
            var failures: [Error] = []
            var detectedTitles: [String] = []
            await withTaskGroup(of: Result<String?, Error>.self) { group in
                for level in todo {
                    let detectTitle = level == titleCarrier && meta.wantsTitleDetection
                    group.addTask {
                        do {
                            let title = try await cfg.generator.generate(
                                paths: paths, level: level, binary: binary,
                                model: cfg.model, detectTitle: detectTitle
                            ).detectedTitle
                            return .success(title)
                        } catch {
                            return .failure(error)
                        }
                    }
                }
                for await result in group {
                    switch result {
                    case .success(let title):
                        if let title { detectedTitles.append(title) }
                    case .failure(let error):
                        failures.append(error)
                    }
                }
            }
            // Un titre détecté par un niveau qui a réussi est conservé même si
            // l'étape finit par échouer globalement (à cause d'un autre
            // niveau) : la détection de titre et le succès de la note ne sont
            // pas la même chose, pas de raison de perdre l'un pour l'autre.
            for title in detectedTitles {
                do {
                    try storage.patchMetadata({ m in
                        m.title = title
                        m.titleAutoDetected = true
                    }, at: paths)
                } catch {
                    failures.append(error)
                }
            }
            guard !failures.isEmpty else {
                await cfg.authMonitor?.reportSuccess()
                return
            }
            // Un échec d'auth prime sur tout échec non-auth récolté à côté :
            // c'est le seul qui doit atteindre le monitor, et l'ordre de
            // complétion des tâches ne doit pas décider à sa place.
            let toReport = failures.first { error in
                if case ClaudeNoteGenerator.GenerationError.authFailed = error { return true }
                return false
            } ?? failures[0]
            // `await` ici introduit une suspension supplémentaire sur l'acteur
            // avant le `throw` : `runStepSoft` observera l'erreur seulement
            // après ce hop, mais son avalage (retour à `.done`) est
            // indépendant du timing puisqu'il agit sur l'état déjà persisté.
            await cfg.authMonitor?.reportFailure(toReport)
            throw toReport
        }
        // Crash-recovery continuation (meta.continuationOf): merge this
        // segment's transcript into the interrupted parent meeting and hide
        // this one. Soft on purpose — on failure both segments stay visible
        // as two complete meetings, which is the pre-feature behavior. No-op
        // for regular meetings. Overall state reuses .generatingNotes because
        // the step's expensive part IS regenerating the parent's notes.
        let absorber = ContinuationAbsorber(storage: storage, notes: notesCfg)
        await runStepSoft(.absorb, paths: paths, overall: .generatingNotes) {
            try await absorber.absorbIfContinuation(child: paths)
        }
        var job = try storage.loadJob(paths)
        job.state = .done
        try storage.saveJob(job, at: paths)
        stateObserver?(paths.slug, .done)
        Log.pipeline.info("Pipeline done for \(paths.slug)")
    }

    /// Updates the notes generation config at runtime (hot-reload).
    /// Called by AppState when the user changes the Claude binary path or note level in Settings.
    /// Actor isolation makes this automatically thread-safe.
    public func setNotesConfig(_ config: NoteGenerationConfig?) {
        self.notes = config
    }

    private func runStepSoft(_ step: JobStep, paths: MeetingPaths,
                             overall: JobOverallState,
                             body: @Sendable () async throws -> Void) async {
        await waitWhileRecording()
        do {
            var job = try storage.loadJob(paths)
            if job.stepStatus(step) == .done {
                Log.pipeline.info("Skip \(step.rawValue) — already done for \(paths.slug)")
                return
            }
            job.state = overall
            job.markStarted(step)
            try storage.saveJob(job, at: paths)
            stateObserver?(paths.slug, overall)
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
        // Recording gate: steps are the pause boundaries — a live recording
        // holds the pipeline here, between steps, never mid-step.
        await waitWhileRecording()
        var job = try storage.loadJob(paths)
        if job.stepStatus(step) == .done {
            Log.pipeline.info("Skip \(step.rawValue) — already done for \(paths.slug)")
            return
        }
        job.state = overall
        job.markStarted(step)
        try storage.saveJob(job, at: paths)
        stateObserver?(paths.slug, overall)
        do {
            try await body()
            var updated = try storage.loadJob(paths)
            updated.markDone(step)
            try storage.saveJob(updated, at: paths)
        } catch {
            var updated = try storage.loadJob(paths)
            updated.markFailed(step, error: String(describing: error))
            try storage.saveJob(updated, at: paths)
            stateObserver?(paths.slug, .failed)
            throw error
        }
    }
}
