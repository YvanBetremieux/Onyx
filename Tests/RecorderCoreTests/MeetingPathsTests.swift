import XCTest
@testable import RecorderCore

final class MeetingPathsTests: XCTestCase {
    func testSlugFromDateIsStable() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 22
        comps.hour = 14; comps.minute = 32
        comps.timeZone = TimeZone(identifier: "Europe/Paris")
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        XCTAssertEqual(MeetingPaths.slug(for: date, timeZone: comps.timeZone!),
                       "2026-07-22_14h32")
    }

    func testMeetingFolderComposition() {
        let root = URL(fileURLWithPath: "/tmp/Meetings")
        let paths = MeetingPaths(root: root, slug: "2026-07-22_14h32")
        XCTAssertEqual(paths.root.path,        "/tmp/Meetings/2026-07-22_14h32")
        XCTAssertEqual(paths.audio.path,       "/tmp/Meetings/2026-07-22_14h32/audio")
        XCTAssertEqual(paths.transcripts.path, "/tmp/Meetings/2026-07-22_14h32/transcripts")
        XCTAssertEqual(paths.meta.path,        "/tmp/Meetings/2026-07-22_14h32/meta.json")
        XCTAssertEqual(paths.job.path,         "/tmp/Meetings/2026-07-22_14h32/job.json")
        XCTAssertEqual(paths.transcriptMd.path,"/tmp/Meetings/2026-07-22_14h32/transcripts/transcript.md")
    }
}
