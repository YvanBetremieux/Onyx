import XCTest
@testable import RecorderCore

final class MarkdownRendererTests: XCTestCase {
    func testRendersHeadingsAndBodies() {
        let started = Date(timeIntervalSince1970: 1_784_819_535)
        let segs = [
            TranscriptSegment(start: 0.0, end: 4.2, speaker: "MOI", text: "Bonjour."),
            TranscriptSegment(start: 4.5, end: 7.1, speaker: "SPEAKER_00", text: "Salut."),
        ]
        let out = MarkdownRenderer.render(segments: segs, meetingStart: started,
                                          slug: "2026-07-22_12h32",
                                          timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(out.contains("# Meeting 2026-07-22_12h32"))
        XCTAssertTrue(out.contains("## 15:12:15 — MOI"))
        XCTAssertTrue(out.contains("Bonjour."))
        XCTAssertTrue(out.contains("## 15:12:19 — SPEAKER_00"))
    }
}
