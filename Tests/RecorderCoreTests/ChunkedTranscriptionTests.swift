import XCTest
@testable import RecorderCore

/// Chunked live transcription (chantier 4): WAV slicing, the chunker's
/// cover-everything contract, and the all-or-nothing assembly the pipeline
/// relies on for its fallback safety.
final class ChunkedTranscriptionTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-chunks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    /// Writes `seconds` of audio where every sample holds the second it
    /// belongs to — lets a test verify a slice contains the right audio.
    private func writeWav(seconds: Int, to url: URL) throws {
        let writer = try WavWriter(url: url, sampleRate: 16_000, channels: 1)
        for s in 0..<seconds {
            let buf = [Float](repeating: Float(s), count: 16_000)
            try buf.withUnsafeBufferPointer { try writer.write($0) }
        }
        try writer.finish()
    }

    private func makeMeeting() throws -> (MeetingPaths, MeetingStorage) {
        let storage = MeetingStorage(root: tmp.appendingPathComponent("Meetings"))
        let paths = try storage.createMeeting(startedAt: Date())
        return (paths, storage)
    }

    // MARK: - ChunkWav

    func test_extract_producesAValidSliceWithTheRightAudio() throws {
        let src = tmp.appendingPathComponent("src.wav")
        try writeWav(seconds: 10, to: src)
        XCTAssertEqual(ChunkWav.availableSeconds(in: src), 10, accuracy: 0.01)

        let dst = tmp.appendingPathComponent("slice.wav")
        XCTAssertTrue(try ChunkWav.extract(from: src, startSeconds: 3,
                                           endSeconds: 5, to: dst))
        XCTAssertEqual(ChunkWav.availableSeconds(in: dst), 2, accuracy: 0.01)

        // The slice must contain seconds 3 and 4 of the source (sample values
        // equal their second-of-origin).
        let data = try Data(contentsOf: dst).dropFirst(44)
        let first = data.withUnsafeBytes { $0.load(as: Float.self) }
        let last = data.suffix(4).withUnsafeBytes { $0.load(as: Float.self) }
        XCTAssertEqual(first, 3.0)
        XCTAssertEqual(last, 4.0)
    }

    func test_extract_refusesWhenAudioNotYetAvailable() throws {
        let src = tmp.appendingPathComponent("short.wav")
        try writeWav(seconds: 4, to: src)
        let dst = tmp.appendingPathComponent("slice.wav")
        XCTAssertFalse(try ChunkWav.extract(from: src, startSeconds: 3,
                                            endSeconds: 6, to: dst),
                       "a chunk whose end is still being recorded must not be cut")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.path))
    }

    // MARK: - ChunkedTranscriber

    /// Fake whisper: one segment spanning the file, text = the wav's basename,
    /// so tests can trace which slice produced which segment.
    private struct FakeWhisper: WhisperTranscribing {
        func transcribe(wavPath: URL, to jsonPath: URL) async throws {
            let dur = ChunkWav.availableSeconds(in: wavPath)
            try AtomicJSON.write(
                [WhisperSegment(start: 0, end: dur,
                                text: wavPath.deletingPathExtension().lastPathComponent,
                                confidence: 0)],
                to: jsonPath)
        }
    }

    func test_finish_coversWholeRecording_withAbsoluteTimestamps() async throws {
        let (paths, _) = try makeMeeting()
        try writeWav(seconds: 10, to: paths.micWav)
        try writeWav(seconds: 10, to: paths.systemWav)

        // 4-second chunks over 10 s → chunks [0,4) [4,8) [8,10).
        let chunker = ChunkedTranscriber(paths: paths, chunkSeconds: 4,
                                         whisper: FakeWhisper())
        await chunker.start()
        await chunker.finish()

        let chunks = ChunkAssembly.chunks(paths: paths)
        XCTAssertEqual(chunks.map(\.index), [0, 1, 2])
        XCTAssertEqual(chunks.last!.end, 10, accuracy: 0.05)
        // Timestamps must be absolute: chunk 1's segment starts at ~4 s.
        XCTAssertEqual(chunks[1].mic.first!.start, 4, accuracy: 0.05)

        let mic = try XCTUnwrap(ChunkAssembly.assembledSegments(
            paths: paths, channel: .mic, durationSeconds: 10))
        XCTAssertEqual(mic.count, 3)
        let sys = try XCTUnwrap(ChunkAssembly.assembledSegments(
            paths: paths, channel: .system, durationSeconds: 10))
        XCTAssertEqual(sys.count, 3)
    }

    /// A fully silent channel must never reach Whisper (that is where the
    /// "Sous-titrage Société Radio-Canada" hallucinations are born) — the
    /// chunk still exists with empty segments, so coverage stays complete.
    func test_silentChannel_skipsWhisperEntirely() async throws {
        final class CountingWhisper: WhisperTranscribing, @unchecked Sendable {
            let lock = NSLock()
            var calls = 0
            func transcribe(wavPath: URL, to jsonPath: URL) async throws {
                lock.lock(); calls += 1; lock.unlock()
                try AtomicJSON.write(
                    [WhisperSegment(start: 0, end: 1, text: "x", confidence: 0)],
                    to: jsonPath)
            }
        }
        let (paths, _) = try makeMeeting()
        // Silent mic (all zeros), speech-like system.
        let silent = try WavWriter(url: paths.micWav, sampleRate: 16_000, channels: 1)
        let zeros = [Float](repeating: 0, count: 16_000 * 4)
        try zeros.withUnsafeBufferPointer { try silent.write($0) }
        try silent.finish()
        try writeWav(seconds: 4, to: paths.systemWav)

        let whisper = CountingWhisper()
        let chunker = ChunkedTranscriber(paths: paths, chunkSeconds: 4, whisper: whisper)
        await chunker.start()
        await chunker.finish()

        XCTAssertEqual(whisper.calls, 1, "only the system channel has speech")
        let mic = try XCTUnwrap(ChunkAssembly.assembledSegments(
            paths: paths, channel: .mic, durationSeconds: 4))
        XCTAssertTrue(mic.isEmpty, "silence transcribes to nothing, not hallucinations")
        let sys = try XCTUnwrap(ChunkAssembly.assembledSegments(
            paths: paths, channel: .system, durationSeconds: 4))
        XCTAssertFalse(sys.isEmpty)
    }

    // MARK: - Hallucination filter

    func test_knownWhisperHallucinationsAreRecognized() {
        for text in ["Sous-titrage Société Radio-Canada",
                     " sous-titrage société radio-canada ",
                     "Sous-titres réalisés par la communauté d'Amara.org",
                     "❤️ par SousTitreur.com",
                     "Merci d'avoir regardé cette vidéo !"] {
            XCTAssertTrue(WhisperTranscriber.isKnownHallucination(text), text)
        }
        for text in ["On a parlé du budget Q3 avec Radio-Canada comme référence ?",
                     "Le sous-titrage des vidéos produit est en retard",
                     "Bonjour à tous"] {
            XCTAssertFalse(WhisperTranscriber.isKnownHallucination(text), text)
        }
    }

    /// A failing whisper must poison the whole chunk set (all-or-nothing), so
    /// the pipeline falls back to full transcription rather than losing audio.
    func test_whisperFailure_leavesIncompleteCoverage() async throws {
        struct FailingWhisper: WhisperTranscribing {
            func transcribe(wavPath: URL, to jsonPath: URL) async throws {
                throw NSError(domain: "test", code: 1)
            }
        }
        let (paths, _) = try makeMeeting()
        try writeWav(seconds: 6, to: paths.micWav)
        try writeWav(seconds: 6, to: paths.systemWav)

        let chunker = ChunkedTranscriber(paths: paths, chunkSeconds: 2,
                                         whisper: FailingWhisper())
        await chunker.start()
        await chunker.finish()

        XCTAssertNil(ChunkAssembly.assembledSegments(
            paths: paths, channel: .mic, durationSeconds: 6),
            "incomplete chunks must never be assembled")
    }

    // MARK: - ChunkAssembly

    private func writeChunk(_ index: Int, start: Double, end: Double,
                            paths: MeetingPaths) throws {
        try FileManager.default.createDirectory(at: paths.transcriptChunks,
                                                withIntermediateDirectories: true)
        let seg = [WhisperSegment(start: start, end: end, text: "c\(index)", confidence: 0)]
        try AtomicJSON.write(TranscriptChunk(index: index, start: start, end: end,
                                             mic: seg, system: seg),
                             to: paths.chunkFile(index))
    }

    func test_assembly_rejectsAGapInTheMiddle() throws {
        let (paths, _) = try makeMeeting()
        try writeChunk(0, start: 0, end: 300, paths: paths)
        try writeChunk(1, start: 600, end: 900, paths: paths)   // hole [300, 600)
        XCTAssertNil(ChunkAssembly.assembledSegments(
            paths: paths, channel: .mic, durationSeconds: 900))
    }

    func test_assembly_rejectsCoverageEndingTooEarly() throws {
        let (paths, _) = try makeMeeting()
        try writeChunk(0, start: 0, end: 300, paths: paths)
        XCTAssertNil(ChunkAssembly.assembledSegments(
            paths: paths, channel: .mic, durationSeconds: 600),
            "the recording's tail is missing — must fall back")
    }

    // MARK: - Pipeline integration

    /// With complete chunks on disk, the whisper steps must assemble instead
    /// of transcribing: the stub whisper here would produce a marker segment,
    /// and it must NOT appear in the output.
    func test_pipelineUsesChunksWhenComplete_andStubWhenNot() async throws {
        struct MarkerWhisper: WhisperTranscribing {
            func transcribe(wavPath: URL, to jsonPath: URL) async throws {
                try AtomicJSON.write(
                    [WhisperSegment(start: 0, end: 1, text: "FULL-TRANSCRIPTION",
                                    confidence: 0)], to: jsonPath)
            }
        }
        struct StubDiar: Diarizing {
            func diarize(wavPath: URL, to jsonPath: URL) throws {
                try AtomicJSON.write([DiarSegment](), to: jsonPath)
            }
        }
        let (paths, storage) = try makeMeeting()
        try writeWav(seconds: 4, to: paths.micWav)
        try writeWav(seconds: 4, to: paths.systemWav)
        try writeChunk(0, start: 0, end: 4, paths: paths)

        let pipeline = Pipeline(storage: storage, whisper: MarkerWhisper(),
                                diarizer: StubDiar())
        try await pipeline.run(paths: paths)

        let mic = try AtomicJSON.read([WhisperSegment].self, from: paths.whisperMic)
        XCTAssertEqual(mic.map(\.text), ["c0"],
                       "complete chunks must be assembled, not re-transcribed")

        // Second meeting without chunks → the stub must be used (fallback).
        let paths2 = try storage.createMeeting(startedAt: Date().addingTimeInterval(90))
        try writeWav(seconds: 4, to: paths2.micWav)
        try writeWav(seconds: 4, to: paths2.systemWav)
        try await pipeline.run(paths: paths2)
        let mic2 = try AtomicJSON.read([WhisperSegment].self, from: paths2.whisperMic)
        XCTAssertEqual(mic2.map(\.text), ["FULL-TRANSCRIPTION"])
    }
}
