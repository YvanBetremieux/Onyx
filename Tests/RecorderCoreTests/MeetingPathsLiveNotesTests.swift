import XCTest
@testable import RecorderCore

final class MeetingPathsLiveNotesTests: XCTestCase {
    func test_liveNotes_isNotesDirLiveMd() {
        let root = URL(fileURLWithPath: "/tmp/onyx-test")
        let paths = MeetingPaths(root: root, slug: "2026-07-31_15h10")
        XCTAssertEqual(paths.liveNotes.lastPathComponent, "live.md")
        XCTAssertEqual(paths.liveNotes.deletingLastPathComponent().lastPathComponent, "notes")
    }

    func test_waveformJson_isAudioDirWaveformJson() {
        let root = URL(fileURLWithPath: "/tmp/onyx-test")
        let paths = MeetingPaths(root: root, slug: "2026-07-31_15h10")
        XCTAssertEqual(paths.waveformJson.lastPathComponent, "waveform.json")
        XCTAssertEqual(paths.waveformJson.deletingLastPathComponent().lastPathComponent, "audio")
    }
}
