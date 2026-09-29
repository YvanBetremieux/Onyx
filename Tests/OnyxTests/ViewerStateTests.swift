import XCTest
@testable import Onyx

final class ViewerStateTests: XCTestCase {
    func test_defaults() {
        let s = ViewerState()
        XCTAssertNil(s.lastMeetingId)
        XCTAssertEqual(s.activeNoteLevel, "synthese")
        XCTAssertEqual(s.notesToTranscriptRatio, 0.6, accuracy: 0.001)
        XCTAssertFalse(s.transcriptPanelHidden)
        XCTAssertEqual(s.lastSearchQuery, "")
    }

    func test_roundTrip_json() throws {
        var s = ViewerState()
        s.lastMeetingId = "2026-07-31_15h10"
        s.activeNoteLevel = "brief"
        s.notesToTranscriptRatio = 0.72
        s.transcriptPanelHidden = true
        s.lastSearchQuery = "whisper"

        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(ViewerState.self, from: data)
        XCTAssertEqual(back, s)
    }
}
