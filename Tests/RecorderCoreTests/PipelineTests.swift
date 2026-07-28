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
}
