import XCTest
import AVFoundation
import RecorderCore
@testable import Onyx

/// Audio wiring in `ViewerStore`: which file gets played, where the waveform
/// comes from, and what happens when there is neither.
@MainActor
final class ViewerStoreAudioTests: XCTestCase {
    private var tmp: URL!
    private var dbPath: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        dbPath = tmp.appendingPathComponent("index.sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    private func makeStore(_ indexer: MeetingIndexer) -> ViewerStore {
        ViewerStore(storage: MeetingStorage(root: tmp),
                    indexer: indexer,
                    claudeBinary: { nil },
                    persistence: ViewerStatePersistence(
                        url: tmp.appendingPathComponent("viewer_state.json"),
                        debounceMs: 60_000))
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 20,
                           _ cond: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)"); return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    /// Builds `<root>/<slug>/audio/` and returns the paths.
    private func makeMeetingDir(_ slug: String) throws -> MeetingPaths {
        let paths = MeetingPaths(root: tmp, slug: slug)
        try FileManager.default.createDirectory(at: paths.audio,
                                               withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.transcripts,
                                               withIntermediateDirectories: true)
        return paths
    }

    private func writeSineWav(to url: URL, seconds: Double = 2.0) throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(16_000 * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData![0]
        for i in 0..<Int(frames) { ch[i] = Float(sin(2 * .pi * 440 * Double(i) / 16_000)) }
        try file.write(from: buf)
    }

    /// The load-bearing assumption of the whole fallback: after `.cleanup` the
    /// only audio left is an `.m4a`, so on-the-fly waveform generation has to
    /// work on a *compressed* file. `WaveformGenerator` was written for WAVs.
    func test_waveformGeneratorWorksOnAnM4a() async throws {
        let paths = try makeMeetingDir("2026-01-01_09h00")
        try writeSineWav(to: paths.micWav, seconds: 2.0)
        try await Mp4Converter.convert(wav: paths.micWav, to: paths.micM4a)
        let wf = try WaveformGenerator.generate(from: paths.micM4a, bucketSizeMs: 50)
        XCTAssertGreaterThan(wf.peaks.count, 30, "expected ~40 buckets for 2 s")
        XCTAssertGreaterThan(wf.peaks.max() ?? 0, 0.5)
    }

    /// Completed meeting: only `mic.m4a` survives, and `waveform.json` was never
    /// written (pre-chantier-3 recording). Both playback and waveform must come
    /// up anyway, and the generated waveform must be cached to disk.
    func test_selectMeeting_generatesWaveformFromM4aAndCachesIt() async throws {
        let indexer = try MeetingIndexer(dbPath: dbPath)
        let paths = try makeMeetingDir("2026-01-02_09h00")
        try writeSineWav(to: paths.micWav, seconds: 2.0)
        try await Mp4Converter.convert(wav: paths.micWav, to: paths.micM4a)
        // Emulate `.cleanup`.
        try FileManager.default.removeItem(at: paths.micWav)

        let store = makeStore(indexer)
        store.selectMeeting(paths.slug)
        try await waitUntil("audio + waveform") {
            store.audioPlayer.hasAudio && !store.currentWaveform.isEmpty
        }
        XCTAssertEqual(store.audioPlayer.duration, 2.0, accuracy: 0.2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.waveformJson.path),
                      "the generated waveform must be cached so the next open is instant")
    }

    /// The normal case: `waveform.json` is on disk, so nothing is regenerated.
    func test_selectMeeting_prefersWaveformJsonOnDisk() async throws {
        let indexer = try MeetingIndexer(dbPath: dbPath)
        let paths = try makeMeetingDir("2026-01-03_09h00")
        try writeSineWav(to: paths.micWav, seconds: 1.0)
        let sentinel: [Float] = [0.11, 0.22, 0.33]
        try WaveformFile(peaks: sentinel, sampleRate: 16_000, bucketSizeMs: 50)
            .write(to: paths.waveformJson)

        let store = makeStore(indexer)
        store.selectMeeting(paths.slug)
        try await waitUntil("waveform") { !store.currentWaveform.isEmpty }
        XCTAssertEqual(store.currentWaveform, sentinel)
    }

    /// No audio and no waveform: degrade, do not crash and do not hang.
    func test_selectMeeting_withNoAudioAtAll() async throws {
        let indexer = try MeetingIndexer(dbPath: dbPath)
        let paths = try makeMeetingDir("2026-01-04_09h00")

        let store = makeStore(indexer)
        store.selectMeeting(paths.slug)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(store.audioPlayer.hasAudio)
        XCTAssertEqual(store.audioPlayer.duration, 0)
        XCTAssertTrue(store.currentWaveform.isEmpty)
        // The transcript playhead must still move so clicking a turn highlights
        // it even with no audio.
        store.seek(to: 12.5)
        XCTAssertEqual(store.playhead.seconds, 12.5, accuracy: 0.001)
    }

    /// Switching meetings must not leave the previous meeting's waveform or
    /// duration on screen.
    func test_selectingAnotherMeetingResetsAudioState() async throws {
        let indexer = try MeetingIndexer(dbPath: dbPath)
        let withAudio = try makeMeetingDir("2026-01-05_09h00")
        try writeSineWav(to: withAudio.micWav, seconds: 2.0)
        let silentOne = try makeMeetingDir("2026-01-06_09h00")

        let store = makeStore(indexer)
        store.selectMeeting(withAudio.slug)
        try await waitUntil("first meeting audio") { store.audioPlayer.hasAudio }

        store.selectMeeting(silentOne.slug)
        XCTAssertTrue(store.currentWaveform.isEmpty,
                      "the waveform must be cleared synchronously with the selection")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(store.audioPlayer.hasAudio)
        XCTAssertEqual(store.audioPlayer.duration, 0)
    }

    /// Both streams present: the player mixes them, so the published duration
    /// is the *longest* stream's, and the cached mic waveform is still reused —
    /// the mix includes the mic, so the mic-drawn waveform still describes what
    /// is audible.
    func test_selectMeeting_withBothStreamsPlaysTheMixAndKeepsTheMicWaveform() async throws {
        let indexer = try MeetingIndexer(dbPath: dbPath)
        let paths = try makeMeetingDir("2026-01-13_09h00")
        try writeSineWav(to: paths.micWav, seconds: 1.0)
        try writeSineWav(to: paths.systemWav, seconds: 2.0)
        let sentinel: [Float] = [0.5, 0.6, 0.7]
        try WaveformFile(peaks: sentinel, sampleRate: 16_000, bucketSizeMs: 50)
            .write(to: paths.waveformJson)

        let store = makeStore(indexer)
        store.selectMeeting(paths.slug)
        try await waitUntil("audio + waveform") {
            store.audioPlayer.hasAudio && !store.currentWaveform.isEmpty
        }
        XCTAssertEqual(store.audioPlayer.duration, 2.0, accuracy: 0.1,
                       "the mix must run as long as the longest stream")
        XCTAssertEqual(store.currentWaveform, sentinel,
                       "the mic waveform stays reusable when the mix includes the mic")
    }

    /// System-only meeting (the mic file never existed or is a 0-byte stub):
    /// current behaviour preserved — play the system stream alone.
    func test_selectMeeting_withSystemStreamOnlyPlaysIt() async throws {
        let indexer = try MeetingIndexer(dbPath: dbPath)
        let paths = try makeMeetingDir("2026-01-14_09h00")
        try writeSineWav(to: paths.systemWav, seconds: 2.0)

        let store = makeStore(indexer)
        store.selectMeeting(paths.slug)
        try await waitUntil("audio") { store.audioPlayer.hasAudio }
        XCTAssertEqual(store.audioPlayer.duration, 2.0, accuracy: 0.1)
    }

    // MARK: - Search-hit seeking

    private func hit(_ id: String, _ t: TimeInterval?) -> SearchHit {
        SearchHit(meetingId: id, title: nil, startedAt: Date(), speaker: "MOI",
                  snippet: AttributedString("x"), approximateTimestamp: t)
    }

    /// Previously deferred: `SearchResultRow` showed a timestamp but selecting a
    /// hit did not move the playhead because no player existed.
    func test_selectSearchHit_seeksOnceAudioIsLoaded() async throws {
        let indexer = try MeetingIndexer(dbPath: dbPath)
        let paths = try makeMeetingDir("2026-01-07_09h00")
        try writeSineWav(to: paths.micWav, seconds: 10.0)

        let store = makeStore(indexer)
        store.selectSearchHit(hit(paths.slug, 4.0))
        try await waitUntil("seek to land") {
            store.audioPlayer.hasAudio && store.audioPlayer.currentTime > 3.5
        }
        XCTAssertEqual(store.audioPlayer.currentTime, 4.0, accuracy: 0.1)
        XCTAssertEqual(store.playhead.seconds, 4.0, accuracy: 0.5)
    }

    /// Same meeting already open: seek immediately, no reload.
    func test_selectSearchHit_inTheAlreadySelectedMeetingSeeksNow() async throws {
        let indexer = try MeetingIndexer(dbPath: dbPath)
        let paths = try makeMeetingDir("2026-01-08_09h00")
        try writeSineWav(to: paths.micWav, seconds: 10.0)

        let store = makeStore(indexer)
        store.selectMeeting(paths.slug)
        try await waitUntil("audio") { store.audioPlayer.hasAudio }
        store.selectSearchHit(hit(paths.slug, 7.0))
        XCTAssertEqual(store.audioPlayer.currentTime, 7.0, accuracy: 0.1)
    }

    /// `approximateTimestamp` is optional (the FTS row may carry no start_ms) and
    /// the meeting may have no audio. Neither may throw or seek to a garbage
    /// position.
    func test_selectSearchHit_degradesWithoutTimestampOrAudio() async throws {
        let indexer = try MeetingIndexer(dbPath: dbPath)
        let noAudio = try makeMeetingDir("2026-01-09_09h00")
        let store = makeStore(indexer)

        store.selectSearchHit(hit(noAudio.slug, 30))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(store.audioPlayer.currentTime, 0)
        XCTAssertEqual(store.selectedMeetingId, noAudio.slug)

        let withAudio = try makeMeetingDir("2026-01-10_09h00")
        try writeSineWav(to: withAudio.micWav, seconds: 5.0)
        store.selectSearchHit(hit(withAudio.slug, nil))
        try await waitUntil("audio") { store.audioPlayer.hasAudio }
        XCTAssertEqual(store.audioPlayer.currentTime, 0,
                       "a hit with no timestamp must not seek anywhere")
    }

    /// A pending seek belongs to the hit that requested it. Selecting a
    /// different meeting in between must drop it rather than apply it to the
    /// wrong recording.
    func test_pendingSeekIsDroppedWhenTheSelectionChanges() async throws {
        let indexer = try MeetingIndexer(dbPath: dbPath)
        let a = try makeMeetingDir("2026-01-11_09h00")
        try writeSineWav(to: a.micWav, seconds: 10.0)
        let b = try makeMeetingDir("2026-01-12_09h00")
        try writeSineWav(to: b.micWav, seconds: 10.0)

        let store = makeStore(indexer)
        store.selectSearchHit(hit(a.slug, 8.0))
        store.selectMeeting(b.slug)
        try await waitUntil("b loaded") { store.audioPlayer.hasAudio }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(store.selectedMeetingId, b.slug)
        XCTAssertEqual(store.audioPlayer.currentTime, 0,
                       "the pending seek was for another meeting")
    }
}
