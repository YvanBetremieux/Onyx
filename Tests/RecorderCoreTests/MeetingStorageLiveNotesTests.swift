import XCTest
@testable import RecorderCore

@available(macOS 13.0, *)
final class MeetingStorageLiveNotesTests: XCTestCase {
    var tmpRoot: URL!

    override func setUp() {
        super.setUp()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpRoot)
        super.tearDown()
    }

    func test_createMeeting_writesEmptyLiveNotesFile() throws {
        let storage = MeetingStorage(root: tmpRoot)
        let paths = try storage.createMeeting(startedAt: Date())
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.liveNotes.path),
                      "live.md should be created at meeting start")
        let content = try String(contentsOf: paths.liveNotes)
        XCTAssertEqual(content, "", "live.md must be created empty")
    }
}
