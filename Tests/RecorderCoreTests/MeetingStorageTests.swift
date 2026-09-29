import XCTest
@testable import RecorderCore

final class MeetingStorageTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("onyx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCreateMeetingProducesLayoutAndInitialFiles() throws {
        let storage = MeetingStorage(root: root)
        let paths = try storage.createMeeting(startedAt: Date(timeIntervalSince1970: 1_784_819_535))
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.audio.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.meta.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.job.path))
        let meta = try AtomicJSON.read(MeetingMetadata.self, from: paths.meta)
        XCTAssertEqual(meta.source, .manual)
        let job = try AtomicJSON.read(JobState.self, from: paths.job)
        XCTAssertEqual(job.state, .recording)
    }

    func testCreateMeetingSameMinuteDoesNotOverwritePrevious() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = MeetingStorage(root: root)
        let date = Date()
        let first = try storage.createMeeting(startedAt: date)
        // Mark the first meeting to prove it's not overwritten.
        var meta1 = try storage.loadMetadata(first)
        meta1.title = "premier"
        try storage.saveMetadata(meta1, at: first)

        let second = try storage.createMeeting(startedAt: date)
        XCTAssertNotEqual(first.slug, second.slug)
        XCTAssertEqual(second.slug, "\(first.slug)_2")
        XCTAssertEqual(try storage.loadMetadata(first).title, "premier")
        XCTAssertEqual(try storage.loadMetadata(second).id, second.slug)

        let third = try storage.createMeeting(startedAt: date)
        XCTAssertEqual(third.slug, "\(first.slug)_3")
    }

    func testListMeetingsReturnsSortedDescending() throws {
        let storage = MeetingStorage(root: root)
        _ = try storage.createMeeting(startedAt: Date(timeIntervalSince1970: 1_000_000_000))
        _ = try storage.createMeeting(startedAt: Date(timeIntervalSince1970: 1_100_000_000))
        let list = try storage.listMeetings()
        XCTAssertEqual(list.count, 2)
        XCTAssertGreaterThan(list[0].slug, list[1].slug)
    }
}
