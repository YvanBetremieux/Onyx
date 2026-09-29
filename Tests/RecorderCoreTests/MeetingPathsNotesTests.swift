import XCTest
@testable import RecorderCore

final class MeetingPathsNotesTests: XCTestCase {
    func testNotesDirIsNotesSubfolder() {
        let root = URL(fileURLWithPath: "/tmp/onyx-test")
        let paths = MeetingPaths(root: root, slug: "2026-07-28_10h00")
        XCTAssertEqual(paths.notesDir.lastPathComponent, "notes")
        XCTAssertTrue(paths.notesDir.path.hasSuffix("/2026-07-28_10h00/notes"))
    }

    func testNotesFilePerLevel() {
        let root = URL(fileURLWithPath: "/tmp/onyx-test")
        let paths = MeetingPaths(root: root, slug: "s")
        XCTAssertEqual(paths.notesFile(.brief).lastPathComponent, "brief.md")
        XCTAssertEqual(paths.notesFile(.synthese).lastPathComponent, "synthese.md")
        XCTAssertEqual(paths.notesFile(.detaillee).lastPathComponent, "detaillee.md")
    }

    func testNoteLevelRawValues() {
        XCTAssertEqual(NoteLevel.brief.rawValue, "brief")
        XCTAssertEqual(NoteLevel.synthese.rawValue, "synthese")
        XCTAssertEqual(NoteLevel.detaillee.rawValue, "detaillee")
    }

    func testNoteLevelAllCases() {
        // 3 generatable levels + `.live` (user-authored, chantier 3).
        XCTAssertEqual(NoteLevel.allCases.count, 4)
        XCTAssertEqual(NoteLevel.generatable.count, 3)
    }
}
