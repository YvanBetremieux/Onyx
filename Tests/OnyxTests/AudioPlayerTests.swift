import XCTest
import AVFoundation
import Combine
@testable import Onyx

/// `AudioPlayer`'s state machine, exercised against real files (building the
/// `AVMutableComposition` refuses anything that is not decodable audio).
///
/// Playback *advancement* depends on an available output device. Unlike the
/// old `AVAudioPlayer.play()` (which returned `false` with no device),
/// `AVPlayer` claims playback unconditionally — so `isPlaying` is our declared
/// intent, always true after `play()`, and the only honest hardware signal is
/// whether the clock actually moves. The one test that needs real audio
/// hardware skips on that.
@MainActor
final class AudioPlayerTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-player-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    /// 16 kHz mono float32 WAV, same shape as `MicRecorder` writes.
    @discardableResult
    private func makeWav(named: String = "a.wav", seconds: Double = 2.0) throws -> URL {
        let url = tmp.appendingPathComponent(named)
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
        return url
    }

    // MARK: - Loading

    func test_load_publishesDurationAndHasAudio() async throws {
        let url = try makeWav(seconds: 2.0)
        let p = AudioPlayer()
        await p.load(url: url)
        XCTAssertTrue(p.hasAudio)
        XCTAssertEqual(p.duration, 2.0, accuracy: 0.05)
        XCTAssertEqual(p.currentTime, 0)
        XCTAssertFalse(p.isPlaying)
    }

    /// The "meeting has no audio file" path: it must be a quiet no-op, not a
    /// crash and not a spinner.
    func test_load_missingFileLeavesPlayerInert() async throws {
        let p = AudioPlayer()
        await p.load(url: tmp.appendingPathComponent("nope.m4a"))
        XCTAssertFalse(p.hasAudio)
        XCTAssertEqual(p.duration, 0)
        p.play()
        XCTAssertFalse(p.isPlaying, "play() with no audio must not claim to be playing")
        p.toggle()
        XCTAssertFalse(p.isPlaying)
        p.seek(42)
        XCTAssertEqual(p.currentTime, 0)
    }

    func test_load_garbageFileLeavesPlayerInert() async throws {
        let url = tmp.appendingPathComponent("garbage.m4a")
        try Data(repeating: 0xAB, count: 4096).write(to: url)
        let p = AudioPlayer()
        await p.load(url: url)
        XCTAssertFalse(p.hasAudio)
        XCTAssertEqual(p.duration, 0)
    }

    /// Loading a second meeting must not leave the first one's duration or
    /// playhead published.
    func test_load_replacesPreviousMedia() async throws {
        let long = try makeWav(named: "long.wav", seconds: 3.0)
        let short = try makeWav(named: "short.wav", seconds: 1.0)
        let p = AudioPlayer()
        await p.load(url: long)
        p.seek(2.5)
        XCTAssertEqual(p.currentTime, 2.5, accuracy: 0.05)
        await p.load(url: short)
        XCTAssertEqual(p.duration, 1.0, accuracy: 0.05)
        XCTAssertEqual(p.currentTime, 0)
    }

    // MARK: - Seeking

    func test_seek_clampsBothEnds() async throws {
        let p = AudioPlayer()
        await p.load(url: try makeWav(seconds: 2.0))
        p.seek(-100)
        XCTAssertEqual(p.currentTime, 0)
        p.seek(10_000)
        XCTAssertEqual(p.currentTime, p.duration, accuracy: 0.05)
        p.seek(1.0)
        XCTAssertEqual(p.currentTime, 1.0, accuracy: 0.05)
    }

    /// `hit.approximateTimestamp` and `segment.start` are decoded from JSON.
    func test_seek_nonFiniteIsTreatedAsZero() async throws {
        let p = AudioPlayer()
        await p.load(url: try makeWav(seconds: 2.0))
        p.seek(1.0)
        p.seek(.nan)
        XCTAssertEqual(p.currentTime, 0)
        p.seek(1.0)
        p.seek(.infinity)
        XCTAssertEqual(p.currentTime, p.duration, accuracy: 0.05)
    }

    func test_seek_notifiesTimeObserver() async throws {
        let p = AudioPlayer()
        var seen: [TimeInterval] = []
        p.onTimeChanged = { seen.append($0) }
        await p.load(url: try makeWav(seconds: 2.0))
        p.seek(1.5)
        XCTAssertEqual(seen.last ?? -1, 1.5, accuracy: 0.05)
    }

    // MARK: - Rate

    func test_setRate_clampsToSupportedRangeAndSurvivesLoad() async throws {
        let p = AudioPlayer()
        p.setRate(1.5)
        XCTAssertEqual(p.rate, 1.5)
        p.setRate(99)
        XCTAssertEqual(p.rate, 2.0)
        p.setRate(0.01)
        XCTAssertEqual(p.rate, 0.5)
        p.setRate(.nan)
        XCTAssertEqual(p.rate, 1.0)
        p.setRate(1.25)
        await p.load(url: try makeWav(seconds: 1.0))
        XCTAssertEqual(p.rate, 1.25, "a chosen speed must not be reset by loading a meeting")
    }

    // MARK: - Play / pause / stop

    /// The published `isPlaying` must match the ticker, and `stop()` must leave
    /// nothing behind: `isPlaying == true` with no ticker running would freeze
    /// the playhead, and `isPlaying == false` with a live ticker would leak a
    /// timer. `play()` on `AVPlayer` always claims playback (no synchronous
    /// failure path like the old `AVAudioPlayer.play()` returning false), so
    /// these assertions are unconditional — no device needed.
    func test_playPauseStop_keepPublishedStateAndTickerConsistent() async throws {
        let p = AudioPlayer()
        await p.load(url: try makeWav(seconds: 3.0))
        XCTAssertFalse(p.isTickerRunning)

        p.play()
        XCTAssertTrue(p.isPlaying)
        XCTAssertTrue(p.isTickerRunning, "ticker must run exactly while isPlaying")

        p.pause()
        XCTAssertFalse(p.isPlaying)
        XCTAssertFalse(p.isTickerRunning, "the ticker must be stopped on pause")

        p.toggle()
        XCTAssertTrue(p.isPlaying)
        XCTAssertTrue(p.isTickerRunning)
        p.toggle()
        XCTAssertFalse(p.isPlaying)
        XCTAssertFalse(p.isTickerRunning)

        p.stop()
        XCTAssertFalse(p.isPlaying)
        XCTAssertFalse(p.isTickerRunning)
        XCTAssertFalse(p.hasAudio)
        XCTAssertEqual(p.duration, 0)
        XCTAssertEqual(p.currentTime, 0)
    }

    /// End-to-end: real playback advances the published playhead and notifies the
    /// time observer. `AVPlayer` claims playback whether or not a device exists
    /// (there is no synchronous failure like `AVAudioPlayer.play()` returning
    /// false), so the skip is based on the only honest signal: whether the
    /// playback clock actually moved after a grace period. The cost, accepted
    /// and deliberate: on a device-less machine a genuinely broken ticker skips
    /// instead of failing — the ticker/`isPlaying` invariants are still covered
    /// unconditionally by `test_playPauseStop_keepPublishedStateAndTickerConsistent`.
    func test_playbackAdvancesThePublishedPlayhead() async throws {
        let p = AudioPlayer()
        var lastObserved: TimeInterval = -1
        p.onTimeChanged = { lastObserved = $0 }
        await p.load(url: try makeWav(seconds: 3.0))
        p.play()
        try await Task.sleep(nanoseconds: 500_000_000)
        try XCTSkipUnless(p.currentTime > 0.2,
                          "playback clock not advancing — no audio output device "
                          + "available in this environment")
        XCTAssertEqual(lastObserved, p.currentTime, accuracy: 0.001,
                       "the time observer must see every playhead move")
        p.pause()
        let frozen = p.currentTime
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(p.currentTime, frozen, "the playhead must not move while paused")
    }

    /// Pressing play at the very end restarts from the top instead of doing
    /// nothing (AVAudioPlayer at `currentTime == duration` plays no audio and
    /// immediately reports itself finished).
    func test_play_atEndOfFileRewinds() async throws {
        let p = AudioPlayer()
        await p.load(url: try makeWav(seconds: 2.0))
        p.seek(10_000)
        XCTAssertEqual(p.currentTime, p.duration, accuracy: 0.05)
        p.play()
        XCTAssertLessThan(p.currentTime, 0.5, "play() at EOF must rewind")
        p.pause()
    }

    // MARK: - Mixed (mic + system) loading

    /// Two time-aligned streams in one mix: the published duration is the
    /// longest stream's, so the scrubber can reach the end of both.
    func test_load_mixesTwoTracksAndPublishesTheLongestDuration() async throws {
        let mic = try makeWav(named: "mic.wav", seconds: 1.0)
        let system = try makeWav(named: "system.wav", seconds: 2.0)
        let p = AudioPlayer()
        await p.load(urls: [mic, system])
        XCTAssertTrue(p.hasAudio)
        XCTAssertEqual(p.duration, 2.0, accuracy: 0.05)
        XCTAssertEqual(p.currentTime, 0)
    }

    /// One broken stream must not silence the other — a pre-cleanup meeting can
    /// have a perfectly playable mic WAV next to a truncated system file.
    func test_load_skipsAnUnreadableTrackAndPlaysTheOther() async throws {
        let garbage = tmp.appendingPathComponent("garbage.m4a")
        try Data(repeating: 0xAB, count: 4096).write(to: garbage)
        let good = try makeWav(named: "good.wav", seconds: 1.0)
        let p = AudioPlayer()
        await p.load(urls: [garbage, good])
        XCTAssertTrue(p.hasAudio)
        XCTAssertEqual(p.duration, 1.0, accuracy: 0.05)
    }

    func test_load_withNoUrlsLeavesPlayerInert() async throws {
        let p = AudioPlayer()
        await p.load(urls: [])
        XCTAssertFalse(p.hasAudio)
        XCTAssertEqual(p.duration, 0)
    }

    /// Seeking the mix must land both-tracks-at-once (a single transport): the
    /// published time is the clamped target, immediately.
    func test_seek_onAMixedLoadPublishesTheTarget() async throws {
        let p = AudioPlayer()
        await p.load(urls: [try makeWav(named: "m2.wav", seconds: 1.0),
                            try makeWav(named: "s2.wav", seconds: 2.0)])
        p.seek(1.5)
        XCTAssertEqual(p.currentTime, 1.5, accuracy: 0.05)
        p.seek(10_000)
        XCTAssertEqual(p.currentTime, p.duration, accuracy: 0.05)
    }

    /// Opening the file happens off the main thread, so two quick meeting
    /// selections have two loads in flight at once. The *last* request must win;
    /// without a generation guard the slower one republishes stale media over
    /// the newer one. Main-actor tasks start FIFO, so `long` is the older
    /// request here whichever detached read finishes first.
    func test_concurrentLoadsEndOnTheLastRequest() async throws {
        let long = try makeWav(named: "long2.wav", seconds: 3.0)
        let short = try makeWav(named: "short2.wav", seconds: 1.0)
        let p = AudioPlayer()
        let a = Task { await p.load(url: long) }
        let b = Task { await p.load(url: short) }
        await a.value
        await b.value
        XCTAssertEqual(p.duration, 1.0, accuracy: 0.05,
                       "the superseded load must not republish its duration")
    }
}
