import XCTest
import AVFoundation
import RecorderCore
@testable import Onyx

/// Closing the viewer only hides the window (`ViewerWindowController` returns
/// `false` from `windowShouldClose` and calls `orderOut`), so audio kept playing
/// with no visible transport and no way to stop it short of quitting. Hiding
/// must pause.
@MainActor
final class ViewerHiddenPausesPlaybackTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-viewerhide-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    /// 16 kHz mono float32 WAV — `AVAudioPlayer` refuses to open anything fake.
    private func makeWav(seconds: Double = 3.0) throws -> URL {
        let url = tmp.appendingPathComponent("a.wav")
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

    private func makeStore() throws -> ViewerStore {
        ViewerStore(storage: MeetingStorage(root: tmp.appendingPathComponent("Meetings")),
                    indexer: try MeetingIndexer.inMemory(),
                    claudeBinary: { nil },
                    persistence: ViewerStatePersistence(
                        url: tmp.appendingPathComponent("viewer_state.json"),
                        debounceMs: 60_000))
    }

    func test_viewerDidHide_pausesPlayback() async throws {
        let store = try makeStore()
        await store.audioPlayer.load(url: try makeWav())
        XCTAssertTrue(store.audioPlayer.hasAudio)
        store.audioPlayer.play()
        // Playback start needs an output device; without one the rest of the
        // assertion is vacuous, so skip honestly rather than pretend.
        try XCTSkipUnless(store.audioPlayer.isPlaying,
                          "no audio output device available in this environment")

        store.viewerDidHide()

        XCTAssertFalse(store.audioPlayer.isPlaying,
                       "hiding the viewer must pause playback")
        XCTAssertFalse(store.audioPlayer.isTickerRunning,
                       "the 10 Hz ticker must stop with playback")
    }

    /// Hiding must not release the media: reopening the viewer should find the
    /// same meeting still loaded at the same position.
    func test_viewerDidHide_keepsTheAudioLoadedAtItsPosition() async throws {
        let store = try makeStore()
        await store.audioPlayer.load(url: try makeWav())
        store.audioPlayer.seek(1.5)
        store.viewerDidHide()
        XCTAssertTrue(store.audioPlayer.hasAudio)
        XCTAssertEqual(store.audioPlayer.currentTime, 1.5, accuracy: 0.05)
    }

    /// With nothing loaded it must be a quiet no-op, not a crash: the user can
    /// close the viewer having never selected a meeting.
    func test_viewerDidHide_withNoAudioIsANoOp() throws {
        let store = try makeStore()
        store.viewerDidHide()
        XCTAssertFalse(store.audioPlayer.isPlaying)
        XCTAssertFalse(store.audioPlayer.hasAudio)
    }
}
