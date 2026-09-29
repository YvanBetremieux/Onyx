import XCTest
@testable import RecorderCore

// Shared stubs for use across multiple tests.
private struct _StubWhisper: WhisperTranscribing {
    func transcribe(wavPath: URL, to jsonPath: URL) async throws {
        try AtomicJSON.write([WhisperSegment](), to: jsonPath)
    }
}

private struct _StubDiar: Diarizing {
    func diarize(wavPath: URL, to jsonPath: URL) throws {
        try AtomicJSON.write([DiarSegment](), to: jsonPath)
    }
}

/// XCTest has no async variant of XCTAssertThrowsError.
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "expression must throw",
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail(message, file: file, line: line)
    } catch {}
}

final class PipelineTests: XCTestCase {
    static let stubWhisper: any WhisperTranscribing = _StubWhisper()
    static let stubDiar: any Diarizing = _StubDiar()

    struct FakeDiar: Diarizing {
        let output: [DiarSegment]
        func diarize(wavPath: URL, to jsonPath: URL) throws {
            try AtomicJSON.write(output, to: jsonPath)
        }
    }

    private func writeSilenceWav(to url: URL, samples: Int = 1600) throws {
        let writer = try WavWriter(url: url, sampleRate: 16_000, channels: 1)
        let buffer = [Float](repeating: 0, count: samples)
        try buffer.withUnsafeBufferPointer { try writer.write($0) }
        try writer.finish()
    }

    func testFullPipelineRunsAllStepsAndProducesMd() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("onyx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = MeetingStorage(root: root)
        let started = Date(timeIntervalSince1970: 1_784_819_535)
        let paths = try storage.createMeeting(startedAt: started)

        try writeSilenceWav(to: paths.micWav)
        try writeSilenceWav(to: paths.systemWav)

        struct DualWhisper: WhisperTranscribing {
            let mic: [WhisperSegment]
            let sys: [WhisperSegment]
            func transcribe(wavPath: URL, to jsonPath: URL) async throws {
                let payload = wavPath.lastPathComponent.contains("mic") ? mic : sys
                try AtomicJSON.write(payload, to: jsonPath)
            }
        }
        let dual = DualWhisper(
            mic: [.init(start: 0, end: 1, text: "moi parle")],
            sys: [.init(start: 1, end: 2, text: "alice repond")]
        )
        let diar = FakeDiar(output: [.init(start: 1, end: 2, speakerId: "SPEAKER_00")])

        let pipeline = Pipeline(storage: storage, whisper: dual, diarizer: diar)
        try await pipeline.run(paths: paths)

        let job = try storage.loadJob(paths)
        XCTAssertEqual(job.state, .done)
        let merged = try AtomicJSON.read([TranscriptSegment].self, from: paths.transcriptJson)
        XCTAssertEqual(merged.map(\.speaker), ["MOI", "SPEAKER_00"])
        let md = try String(contentsOf: paths.transcriptMd, encoding: .utf8)
        XCTAssertTrue(md.contains("MOI"))
        XCTAssertTrue(md.contains("SPEAKER_00"))
    }

    func testSecondRunSkipsCompletedSteps() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("onyx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = MeetingStorage(root: root)
        let paths = try storage.createMeeting(startedAt: Date())
        try writeSilenceWav(to: paths.micWav)
        try writeSilenceWav(to: paths.systemWav)

        actor CallCounter {
            var n = 0
            func bump() { n += 1 }
        }
        let counter = CallCounter()

        struct CountingWhisper: WhisperTranscribing {
            let counter: CallCounter
            func transcribe(wavPath: URL, to jsonPath: URL) async throws {
                await counter.bump()
                try AtomicJSON.write([WhisperSegment](), to: jsonPath)
            }
        }
        let whisper = CountingWhisper(counter: counter)
        struct EmptyDiar: Diarizing {
            func diarize(wavPath: URL, to jsonPath: URL) throws {
                try AtomicJSON.write([DiarSegment](), to: jsonPath)
            }
        }
        let pipeline = Pipeline(storage: storage, whisper: whisper, diarizer: EmptyDiar())
        try await pipeline.run(paths: paths)
        let firstCount = await counter.n
        try await pipeline.run(paths: paths)
        let secondCount = await counter.n
        XCTAssertEqual(firstCount, secondCount)
    }

    func testPipelineAbsorbsContinuationSegmentIntoParent() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("onyx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = MeetingStorage(root: root)
        let t0 = Date(timeIntervalSince1970: 1_784_819_535)

        struct OneLineWhisper: WhisperTranscribing {
            func transcribe(wavPath: URL, to jsonPath: URL) async throws {
                try AtomicJSON.write([WhisperSegment(start: 0, end: 1, text: "bla")],
                                     to: jsonPath)
            }
        }
        let pipeline = Pipeline(storage: storage, whisper: OneLineWhisper(),
                                diarizer: Self.stubDiar)

        // Segment 1: crashed mid-recording (endedAt never written), then its
        // pipeline resumed and completed at relaunch.
        let parent = try storage.createMeeting(startedAt: t0)
        try storage.patchMetadata({ m in m.detectedCode = "xxx-yyyy-zzz" }, at: parent)
        try writeSilenceWav(to: parent.micWav)
        try writeSilenceWav(to: parent.systemWav)
        try await pipeline.run(paths: parent)

        // Segment 2: re-detected after relaunch, marked as continuation.
        let child = try storage.createMeeting(startedAt: t0.addingTimeInterval(600))
        try storage.patchMetadata({ m in
            m.detectedCode = "xxx-yyyy-zzz"
            m.continuationOf = parent.slug
            m.endedAt = t0.addingTimeInterval(900)
        }, at: child)
        try writeSilenceWav(to: child.micWav)
        try writeSilenceWav(to: child.systemWav)
        try await pipeline.run(paths: child)

        let childJob = try storage.loadJob(child)
        XCTAssertEqual(childJob.state, .done)
        XCTAssertEqual(childJob.stepStatus(.absorb), .done)
        XCTAssertEqual(try storage.loadMetadata(child).absorbed, true)

        let merged = try AtomicJSON.read([TranscriptSegment].self,
                                         from: parent.transcriptJson)
        XCTAssertEqual(merged.map(\.start), [0, 600])
        XCTAssertEqual(try storage.loadMetadata(parent).endedAt,
                       t0.addingTimeInterval(900))
    }

    // MARK: - Helpers for notes tests

    static func makeMeetingWithArtifacts() throws -> (MeetingPaths, MeetingStorage) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-pipe-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = MeetingStorage(root: root)
        let paths = try storage.createMeeting(startedAt: Date())
        // Write real silence wavs so Normalizer (which uses AVAudioFile) succeeds.
        // paths.audio is already created by createMeeting.
        let writer1 = try WavWriter(url: paths.micWav, sampleRate: 16_000, channels: 1)
        let buf = [Float](repeating: 0, count: 1600)
        try buf.withUnsafeBufferPointer { try writer1.write($0) }
        try writer1.finish()
        let writer2 = try WavWriter(url: paths.systemWav, sampleRate: 16_000, channels: 1)
        try buf.withUnsafeBufferPointer { try writer2.write($0) }
        try writer2.finish()
        // paths.transcripts is already created by createMeeting.
        // The .notes step reads transcript.md — render will produce it from the empty segments.
        return (paths, storage)
    }

    static func makeFakeClaude(output: String, exitCode: Int = 0) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-fclaude-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("claude")
        let escaped = output.replacingOccurrences(of: "'", with: "'\\''")
        let body = "#!/bin/bash\ncat > /dev/null\nprintf '%s' '\(escaped)'\nexit \(exitCode)\n"
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        return script
    }

    /// Faux `claude` dont le comportement dépend du niveau demandé : le prompt
    /// arrive sur stdin et contient « Niveau demandé : BRIEF. » (ou SYNTHESE,
    /// DETAILLE), ce qui permet de simuler un échec partiel — un niveau qui
    /// échoue sur l'auth pendant qu'un autre échoue autrement (ou réussit).
    static func makeLevelAwareFakeClaude(
        brief: (output: String, exitCode: Int) = ("# brief", 0),
        synthese: (output: String, exitCode: Int) = ("# synthese", 0)
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-fclaude-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("claude")
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "'\\''") }
        let body = """
        #!/bin/bash
        prompt="$(cat)"
        if [[ "$prompt" == *"Niveau demandé : BRIEF."* ]]; then
          printf '%s' '\(esc(brief.output))'
          exit \(brief.exitCode)
        elif [[ "$prompt" == *"Niveau demandé : SYNTHESE."* ]]; then
          printf '%s' '\(esc(synthese.output))'
          exit \(synthese.exitCode)
        fi
        exit 0
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        return script
    }

    /// Whisper and diarization must overlap in time (they use disjoint
    /// hardware) — sequential execution was leaving the whole diarization
    /// after the whisper tail on the post-stop critical path.
    func testWhisperAndDiarizationRunConcurrently() async throws {
        final class IntervalBox: @unchecked Sendable {
            let lock = NSLock()
            var intervals: [String: (start: Date, end: Date)] = [:]
            func record(_ name: String, _ start: Date, _ end: Date) {
                lock.lock(); intervals[name] = (start, end); lock.unlock()
            }
        }
        let box = IntervalBox()
        struct SlowWhisper: WhisperTranscribing {
            let box: IntervalBox
            func transcribe(wavPath: URL, to jsonPath: URL) async throws {
                let start = Date()
                try await Task.sleep(nanoseconds: 200_000_000)
                box.record("whisper-\(wavPath.lastPathComponent)", start, Date())
                try AtomicJSON.write([WhisperSegment](), to: jsonPath)
            }
        }
        struct SlowDiar: Diarizing {
            let box: IntervalBox
            func diarize(wavPath: URL, to jsonPath: URL) throws {
                let start = Date()
                Thread.sleep(forTimeInterval: 0.2)   // runs on a GCD queue
                box.record("diarize", start, Date())
                try AtomicJSON.write([DiarSegment](), to: jsonPath)
            }
        }
        let (paths, storage) = try Self.makeMeetingWithArtifacts()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let pipeline = Pipeline(storage: storage,
                                whisper: SlowWhisper(box: box),
                                diarizer: SlowDiar(box: box))
        try await pipeline.run(paths: paths)

        let diar = try XCTUnwrap(box.intervals["diarize"])
        let whispers = box.intervals.filter { $0.key.hasPrefix("whisper-") }.values
        XCTAssertEqual(whispers.count, 2)
        let whisperStart = whispers.map(\.start).min()!
        let whisperEnd = whispers.map(\.end).max()!
        XCTAssertTrue(diar.start < whisperEnd && whisperStart < diar.end,
                      "diarization must overlap the whisper steps, not follow them")
    }

    // MARK: - Notes step tests

    func testPipelineRunsNotesStepWhenConfigured() async throws {
        let (paths, storage) = try Self.makeMeetingWithArtifacts()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let bin = try Self.makeFakeClaude(output: "# fake note\nok")
        defer { try? FileManager.default.removeItem(at: bin.deletingLastPathComponent()) }

        let cfg = NoteGenerationConfig(binary: bin, level: .brief)
        let pipeline = Pipeline(storage: storage,
                                whisper: Self.stubWhisper,
                                diarizer: Self.stubDiar,
                                notes: cfg)
        try await pipeline.run(paths: paths)

        let target = paths.notesFile(.brief)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        let content = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(content.contains("# fake note"))

        let job = try storage.loadJob(paths)
        XCTAssertEqual(job.state, .done)
        XCTAssertEqual(job.stepStatus(.notes), .done)
    }

    /// Real-time UI contract: the pipeline must announce each overall-state
    /// transition (transcribing, …, generatingNotes) and finish with `.done` —
    /// that is what drives the live sidebar badges.
    func testPipelineEmitsStateTransitions() async throws {
        let (paths, storage) = try Self.makeMeetingWithArtifacts()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let bin = try Self.makeFakeClaude(output: "# note")
        defer { try? FileManager.default.removeItem(at: bin.deletingLastPathComponent()) }

        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var states: [JobOverallState] = []
            func append(_ s: JobOverallState) { lock.lock(); states.append(s); lock.unlock() }
        }
        let box = Box()
        let pipeline = Pipeline(storage: storage,
                                whisper: Self.stubWhisper,
                                diarizer: Self.stubDiar,
                                notes: NoteGenerationConfig(binary: bin, level: .brief))
        await pipeline.setStateObserver { _, state in box.append(state) }
        try await pipeline.run(paths: paths)

        let states = box.states
        XCTAssertTrue(states.contains(.transcribing), "got: \(states)")
        XCTAssertTrue(states.contains(.generatingNotes), "got: \(states)")
        XCTAssertEqual(states.last, .done, "the sequence must end on .done; got: \(states)")
    }

    /// The multi-level config (Settings checkboxes) must produce one note file
    /// per configured level — three independent claude sessions.
    func testPipelineGeneratesAllConfiguredLevels() async throws {
        let (paths, storage) = try Self.makeMeetingWithArtifacts()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let bin = try Self.makeFakeClaude(output: "# fake note\nok")
        defer { try? FileManager.default.removeItem(at: bin.deletingLastPathComponent()) }

        let cfg = NoteGenerationConfig(binary: bin,
                                       levels: [.brief, .synthese, .detaillee])
        let pipeline = Pipeline(storage: storage,
                                whisper: Self.stubWhisper,
                                diarizer: Self.stubDiar,
                                notes: cfg)
        try await pipeline.run(paths: paths)

        for level in [NoteLevel.brief, .synthese, .detaillee] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: paths.notesFile(level).path),
                "notes/\(level.rawValue).md must be generated")
        }
        let job = try storage.loadJob(paths)
        XCTAssertEqual(job.state, .done)
        XCTAssertEqual(job.stepStatus(.notes), .done)
    }

    // MARK: - Job serialization + recording gate tests

    /// Thread-safe event log: (slug, state, timestamp) per observer callback.
    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [(slug: String, state: JobOverallState, at: Date)] = []
        func append(_ slug: String, _ state: JobOverallState) {
            lock.lock(); _events.append((slug, state, Date())); lock.unlock()
        }
        var events: [(slug: String, state: JobOverallState, at: Date)] {
            lock.lock(); defer { lock.unlock() }; return _events
        }
    }

    private struct WaitTimeout: Error {}

    /// Polls `condition` every 20 ms until true; fails fast (throws) on
    /// timeout so a hung pipeline doesn't cascade into secondary failures.
    private func waitUntil(timeout: TimeInterval = 5,
                           _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("timed out waiting for condition")
                throw WaitTimeout()
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// The actor is reentrant, so two `run` calls used to interleave their
    /// steps (two diarizations at once during live calls). They must now
    /// queue FIFO: all of job A's state transitions — through `.done` —
    /// before any of job B's.
    func testConcurrentRunsExecuteSerially() async throws {
        let (pathsA, storage) = try Self.makeMeetingWithArtifacts()
        defer { try? FileManager.default.removeItem(at: pathsA.root.deletingLastPathComponent()) }
        let pathsB = try storage.createMeeting(startedAt: Date().addingTimeInterval(3600))

        struct SlowWhisper: WhisperTranscribing {
            func transcribe(wavPath: URL, to jsonPath: URL) async throws {
                try await Task.sleep(nanoseconds: 100_000_000)
                try AtomicJSON.write([WhisperSegment](), to: jsonPath)
            }
        }
        // B reuses A's wav content — createMeeting only makes directories.
        try FileManager.default.copyItem(at: pathsA.micWav, to: pathsB.micWav)
        try FileManager.default.copyItem(at: pathsA.systemWav, to: pathsB.systemWav)

        let box = EventBox()
        let pipeline = Pipeline(storage: storage, whisper: SlowWhisper(),
                                diarizer: Self.stubDiar)
        await pipeline.setStateObserver { slug, state in box.append(slug, state) }

        async let runA: Void = pipeline.run(paths: pathsA)
        async let runB: Void = pipeline.run(paths: pathsB)
        try await runA
        try await runB

        let events = box.events
        let firstSlug = try XCTUnwrap(events.first?.slug)
        let doneIndex = try XCTUnwrap(
            events.firstIndex { $0.slug == firstSlug && $0.state == .done },
            "first job must reach .done; got: \(events)")
        let otherFirst = events.firstIndex { $0.slug != firstSlug }
        if let otherFirst {
            XCTAssertGreaterThan(otherFirst, doneIndex,
                "second job must not emit any state before the first job's .done; got: \(events)")
        } else {
            XCTFail("second job emitted no states at all")
        }
    }

    /// A `run` issued while a recording is active must not start any step
    /// until the recording gate is cleared.
    func testRunWaitsWhileRecordingActive() async throws {
        let (paths, storage) = try Self.makeMeetingWithArtifacts()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let box = EventBox()
        let pipeline = Pipeline(storage: storage, whisper: Self.stubWhisper,
                                diarizer: Self.stubDiar)
        await pipeline.setStateObserver { slug, state in box.append(slug, state) }
        await pipeline.setRecordingActive(true)

        let task = Task { try await pipeline.run(paths: paths) }
        // Negative check: give the job ample opportunity to (wrongly) start.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(box.events.isEmpty,
                      "no step may start while recording is active; got: \(box.events)")

        await pipeline.setRecordingActive(false)
        try await task.value
        XCTAssertEqual(box.events.last?.state, .done)
        XCTAssertEqual(try storage.loadJob(paths).state, .done)
    }

    /// A job already mid-run must finish its CURRENT step when a recording
    /// starts, then hold before the next step until the recording ends.
    func testMidRunJobPausesBetweenStepsWhileRecording() async throws {
        let (paths, storage) = try Self.makeMeetingWithArtifacts()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        /// Blocks the mic transcription until the test releases it, so the
        /// recording flag can be raised while a step is provably in flight.
        final class Flags: @unchecked Sendable {
            let lock = NSLock()
            private var _entered = false, _released = false
            var entered: Bool {
                get { lock.lock(); defer { lock.unlock() }; return _entered }
                set { lock.lock(); _entered = newValue; lock.unlock() }
            }
            var released: Bool {
                get { lock.lock(); defer { lock.unlock() }; return _released }
                set { lock.lock(); _released = newValue; lock.unlock() }
            }
        }
        struct BlockingMicWhisper: WhisperTranscribing {
            let flags: Flags
            func transcribe(wavPath: URL, to jsonPath: URL) async throws {
                if wavPath.lastPathComponent.contains("mic") {
                    flags.entered = true
                    while !flags.released {
                        try await Task.sleep(nanoseconds: 20_000_000)
                    }
                }
                try AtomicJSON.write([WhisperSegment](), to: jsonPath)
            }
        }
        let flags = Flags()
        let box = EventBox()
        let pipeline = Pipeline(storage: storage,
                                whisper: BlockingMicWhisper(flags: flags),
                                diarizer: Self.stubDiar)
        await pipeline.setStateObserver { slug, state in box.append(slug, state) }

        let task = Task { try await pipeline.run(paths: paths) }
        try await waitUntil { flags.entered }

        // Recording starts while whisper_mic is mid-flight.
        await pipeline.setRecordingActive(true)
        flags.released = true   // the current step is allowed to finish…

        // …but no NEW step may start: the observer fires at step start, so
        // the event log must stay frozen while the gate is closed.
        try await waitUntil {
            (try? storage.loadJob(paths))?.stepStatus(.whisperMic) == .done
        }
        let frozenCount = box.events.count
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(box.events.count, frozenCount,
                       "no step may start while paused; got: \(box.events)")

        let resumedAt = Date()
        await pipeline.setRecordingActive(false)
        try await task.value

        XCTAssertEqual(try storage.loadJob(paths).state, .done)
        // Everything that started after the pause resumed only once the
        // recording ended.
        let late = box.events.dropFirst(frozenCount)
        XCTAssertFalse(late.isEmpty, "the job must resume after the gate opens")
        for event in late {
            XCTAssertGreaterThanOrEqual(event.at, resumedAt,
                "step \(event.state) started while recording was active")
        }
    }

    // MARK: - Failed-job retry tests

    /// Fails every whisper call while `failing` is true; the test flips the
    /// flag between runs. Also counts diarize calls so the test can prove
    /// what was and wasn't re-run.
    private final class FlakyState: @unchecked Sendable {
        private let lock = NSLock()
        private var _failing: Bool
        private var _diarCalls = 0
        init(failing: Bool) { _failing = failing }
        var failing: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _failing }
            set { lock.lock(); _failing = newValue; lock.unlock() }
        }
        var diarCalls: Int { lock.lock(); defer { lock.unlock() }; return _diarCalls }
        func bumpDiar() { lock.lock(); _diarCalls += 1; lock.unlock() }
    }

    private struct ANETimeoutish: Error, CustomStringConvertible {
        var description: String {
            #"Error Domain=com.apple.CoreML Code=0 "Timeout occurred while computing the asynchronous prediction using ML Program.""#
        }
    }

    private struct FlakyWhisper: WhisperTranscribing {
        let state: FlakyState
        func transcribe(wavPath: URL, to jsonPath: URL) async throws {
            if state.failing { throw ANETimeoutish() }
            try AtomicJSON.write([WhisperSegment](), to: jsonPath)
        }
    }

    private struct CountingDiar: Diarizing {
        let state: FlakyState
        func diarize(wavPath: URL, to jsonPath: URL) throws {
            state.bumpDiar()
            try AtomicJSON.write([DiarSegment](), to: jsonPath)
        }
    }

    /// A job persisted `.failed` (whisper died once, e.g. ANE timeout) must
    /// be retried on the next run: failed steps reset, retryCount consumed,
    /// already-done steps NOT re-run, and the job completes.
    func testFailedJobIsRetriedOnNextRun() async throws {
        let (paths, storage) = try Self.makeMeetingWithArtifacts()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let state = FlakyState(failing: true)   // run 1 fails, then recovers
        let pipeline = Pipeline(storage: storage,
                                whisper: FlakyWhisper(state: state),
                                diarizer: CountingDiar(state: state))

        await XCTAssertThrowsErrorAsync(try await pipeline.run(paths: paths))
        var job = try storage.loadJob(paths)
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.retryCount, 0, "the first run is not a retry")
        XCTAssertTrue(job.isResumable, "a freshly failed job must stay resumable")
        let diarCallsAfterFirstRun = state.diarCalls

        state.failing = false   // the transient saturation is over
        try await pipeline.run(paths: paths)
        job = try storage.loadJob(paths)
        XCTAssertEqual(job.state, .done)
        XCTAssertEqual(job.retryCount, 1)
        XCTAssertEqual(job.stepStatus(.whisperMic), .done)
        XCTAssertEqual(job.stepStatus(.whisperSystem), .done)
        XCTAssertNil(job.error)
        XCTAssertEqual(state.diarCalls, diarCallsAfterFirstRun,
                       "steps already .done must not be re-run on retry")
    }

    /// A quit/crash AFTER the retry was prepared and persisted but BEFORE
    /// the run made progress (e.g. parked behind the recording gate for a
    /// whole meeting) must not bill another retry at the next launch: the
    /// prepared job is persisted out of `.failed`, so the relaunch resumes
    /// it through the normal free resume path.
    func testRelaunchAfterRetryPreparationDoesNotConsumeAnotherRetry() async throws {
        let (paths, storage) = try Self.makeMeetingWithArtifacts()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let state = FlakyState(failing: true)
        let pipeline = Pipeline(storage: storage,
                                whisper: FlakyWhisper(state: state),
                                diarizer: CountingDiar(state: state))
        await XCTAssertThrowsErrorAsync(try await pipeline.run(paths: paths))

        // Same preparation the pipeline persists at the start of a retry
        // run, then a simulated crash before any step executed.
        var job = try storage.loadJob(paths)
        job.prepareRetry()
        try storage.saveJob(job, at: paths)
        XCTAssertNotEqual(job.state, .failed,
                          "a prepared retry must not persist as .failed")
        XCTAssertEqual(job.retryCount, 1)
        XCTAssertTrue(job.isResumable)

        // "Relaunch": the resume scan calls run again — for free.
        state.failing = false
        try await pipeline.run(paths: paths)
        let final = try storage.loadJob(paths)
        XCTAssertEqual(final.state, .done)
        XCTAssertEqual(final.retryCount, 1,
                       "the parked retry must not be double-billed")
    }

    /// After `JobState.maxRetries` consumed retries the job stops being
    /// resumable — the resumePendingJobs scan leaves it alone.
    func testJobStopsBeingResumableAfterMaxRetries() async throws {
        let (paths, storage) = try Self.makeMeetingWithArtifacts()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let state = FlakyState(failing: true)   // whisper never recovers
        let pipeline = Pipeline(storage: storage,
                                whisper: FlakyWhisper(state: state),
                                diarizer: CountingDiar(state: state))

        // Initial run + maxRetries automatic retries, all failing.
        for attempt in 0...JobState.maxRetries {
            await XCTAssertThrowsErrorAsync(try await pipeline.run(paths: paths))
            let job = try storage.loadJob(paths)
            XCTAssertEqual(job.state, .failed)
            XCTAssertEqual(job.retryCount, attempt)
        }
        let job = try storage.loadJob(paths)
        XCTAssertFalse(job.isResumable,
                       "retry budget exhausted — the scan must skip this job")
    }

    func testPipelineTolerantToNotesFailure() async throws {
        let (paths, storage) = try Self.makeMeetingWithArtifacts()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let bin = try Self.makeFakeClaude(output: "", exitCode: 7)
        defer { try? FileManager.default.removeItem(at: bin.deletingLastPathComponent()) }

        let cfg = NoteGenerationConfig(binary: bin, level: .brief)
        let pipeline = Pipeline(storage: storage,
                                whisper: Self.stubWhisper,
                                diarizer: Self.stubDiar,
                                notes: cfg)
        try await pipeline.run(paths: paths)

        let job = try storage.loadJob(paths)
        XCTAssertEqual(job.state, .done)
        XCTAssertEqual(job.stepStatus(.notes), .failed)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.notesFile(.brief).path))
    }

    /// Le chemin qui a manqué pendant l'incident : un échec d'auth de l'étape
    /// .notes doit remonter au monitor, sinon l'app reste muette.
    func testNotesAuthFailureIsReportedToMonitor() async throws {
        let (paths, storage) = try Self.makeMeetingWithArtifacts()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        // Message réel du CLI déconnecté, sur stdout, avec exit 1.
        let bin = try Self.makeFakeClaude(output: "Not logged in · Please run /login",
                                          exitCode: 1)
        defer { try? FileManager.default.removeItem(at: bin.deletingLastPathComponent()) }

        let stateFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-auth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stateFile) }
        let monitor = ClaudeAuthMonitor(stateFile: stateFile)

        let cfg = NoteGenerationConfig(binary: bin, level: .brief, authMonitor: monitor)
        let pipeline = Pipeline(storage: storage, whisper: Self.stubWhisper,
                                diarizer: Self.stubDiar, notes: cfg)
        try await pipeline.run(paths: paths)

        let status = await monitor.status
        guard case .disconnected(let failure, _) = status else {
            return XCTFail("expected disconnected, got \(status)")
        }
        XCTAssertEqual(failure, .notLoggedIn)
        // Le soft-fail reste inchangé : le transcript demeure valide.
        let job = try storage.loadJob(paths)
        XCTAssertEqual(job.state, .done)
        XCTAssertEqual(job.stepStatus(.notes), .failed)
    }

    func testNotesSuccessReportsConnected() async throws {
        let (paths, storage) = try Self.makeMeetingWithArtifacts()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let bin = try Self.makeFakeClaude(output: "# note")
        defer { try? FileManager.default.removeItem(at: bin.deletingLastPathComponent()) }

        let stateFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-auth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stateFile) }
        let monitor = ClaudeAuthMonitor(stateFile: stateFile)

        let cfg = NoteGenerationConfig(binary: bin, level: .brief, authMonitor: monitor)
        let pipeline = Pipeline(storage: storage, whisper: Self.stubWhisper,
                                diarizer: Self.stubDiar, notes: cfg)
        try await pipeline.run(paths: paths)

        let status = await monitor.status
        guard case .connected = status else {
            return XCTFail("expected connected, got \(status)")
        }
    }

    /// Un échec non-auth (ici exit 7 sans message reconnaissable) ne doit pas
    /// faire croire à une déconnexion.
    func testNotesNonAuthFailureLeavesMonitorUnknown() async throws {
        let (paths, storage) = try Self.makeMeetingWithArtifacts()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let bin = try Self.makeFakeClaude(output: "boom", exitCode: 7)
        defer { try? FileManager.default.removeItem(at: bin.deletingLastPathComponent()) }

        let stateFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-auth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stateFile) }
        let monitor = ClaudeAuthMonitor(stateFile: stateFile)

        let cfg = NoteGenerationConfig(binary: bin, level: .brief, authMonitor: monitor)
        let pipeline = Pipeline(storage: storage, whisper: Self.stubWhisper,
                                diarizer: Self.stubDiar, notes: cfg)
        try await pipeline.run(paths: paths)

        let status = await monitor.status
        XCTAssertEqual(status, .unknown)
    }

    /// Régression pour D1 : avant le drain complet du groupe, un échec non-auth
    /// sur un niveau pouvait gagner la course contre un échec d'auth sur un
    /// autre niveau et faire disparaître le signal (le monitor resterait
    /// `.unknown` au lieu de `.disconnected`). Ce test échoue contre
    /// l'implémentation qui laisse `withThrowingTaskGroup` lever tôt.
    func testMultiLevelAuthFailureIsNotMaskedByNonAuthFailure() async throws {
        let (paths, storage) = try Self.makeMeetingWithArtifacts()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let bin = try Self.makeLevelAwareFakeClaude(
            brief: (output: "Not logged in · Please run /login", exitCode: 1),
            synthese: (output: "boom", exitCode: 7))
        defer { try? FileManager.default.removeItem(at: bin.deletingLastPathComponent()) }

        let stateFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-auth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stateFile) }
        let monitor = ClaudeAuthMonitor(stateFile: stateFile)

        let cfg = NoteGenerationConfig(binary: bin, levels: [.brief, .synthese],
                                       authMonitor: monitor)
        let pipeline = Pipeline(storage: storage, whisper: Self.stubWhisper,
                                diarizer: Self.stubDiar, notes: cfg)
        try await pipeline.run(paths: paths)

        let status = await monitor.status
        guard case .disconnected(let failure, _) = status else {
            return XCTFail("expected disconnected, got \(status)")
        }
        XCTAssertEqual(failure, .notLoggedIn)
    }

    /// Un succès partiel garde sa note sur disque même si l'étape échoue
    /// globalement à cause d'un autre niveau en échec d'auth.
    func testMultiLevelPartialSuccessKeepsSuccessfulNoteOnAuthFailure() async throws {
        let (paths, storage) = try Self.makeMeetingWithArtifacts()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let bin = try Self.makeLevelAwareFakeClaude(
            brief: (output: "# fake brief note", exitCode: 0),
            synthese: (output: "Not logged in · Please run /login", exitCode: 1))
        defer { try? FileManager.default.removeItem(at: bin.deletingLastPathComponent()) }

        let stateFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-auth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stateFile) }
        let monitor = ClaudeAuthMonitor(stateFile: stateFile)

        let cfg = NoteGenerationConfig(binary: bin, levels: [.brief, .synthese],
                                       authMonitor: monitor)
        let pipeline = Pipeline(storage: storage, whisper: Self.stubWhisper,
                                diarizer: Self.stubDiar, notes: cfg)
        try await pipeline.run(paths: paths)

        let status = await monitor.status
        guard case .disconnected(let failure, _) = status else {
            return XCTFail("expected disconnected, got \(status)")
        }
        XCTAssertEqual(failure, .notLoggedIn)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.notesFile(.brief).path),
                     "the successful level's note must survive the other level's failure")
    }
}
