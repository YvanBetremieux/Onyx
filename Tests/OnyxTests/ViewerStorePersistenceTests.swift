import XCTest
@testable import Onyx

final class ViewerStorePersistenceTests: XCTestCase {
    var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-\(UUID().uuidString).json")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp); super.tearDown() }

    func test_load_missingFileReturnsDefaults() {
        let p = ViewerStatePersistence(url: tmp)
        XCTAssertEqual(p.load(), ViewerState())
    }

    func test_load_corruptFileReturnsDefaults() throws {
        try Data("{ not json".utf8).write(to: tmp)
        let p = ViewerStatePersistence(url: tmp)
        XCTAssertEqual(p.load(), ViewerState())
    }

    func test_saveThenLoad_returnsPersistedState() {
        let p = ViewerStatePersistence(url: tmp)
        var s = ViewerState()
        s.lastMeetingId = "abc"
        s.notesToTranscriptRatio = 0.42
        p.saveImmediately(s)
        XCTAssertEqual(p.load(), s)
    }

    func test_scheduleSave_debouncesMultipleCalls() async throws {
        let p = ViewerStatePersistence(url: tmp, debounceMs: 80)
        var s = ViewerState()
        s.lastMeetingId = "step1"
        p.scheduleSave(s)
        s.lastMeetingId = "step2"
        p.scheduleSave(s)
        s.lastMeetingId = "step3"
        p.scheduleSave(s)
        // Immediately after: nothing on disk yet (or a stale value).
        XCTAssertNotEqual(p.load().lastMeetingId, "step3")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(p.load().lastMeetingId, "step3")
    }

    // MARK: - flush()

    /// The whole point of `flush()`: at quit time we cannot wait `debounceMs`,
    /// so the last scheduled state must hit disk synchronously.
    func test_flush_writesLastScheduledStateImmediately() {
        let p = ViewerStatePersistence(url: tmp, debounceMs: 5_000)
        var s = ViewerState()
        s.lastMeetingId = "pending"
        s.notesToTranscriptRatio = 0.77
        p.scheduleSave(s)
        p.flush()
        XCTAssertEqual(p.load(), s, "flush() must not wait for the debounce")
    }

    func test_flush_withNothingScheduled_writesNothing() {
        let p = ViewerStatePersistence(url: tmp, debounceMs: 5_000)
        p.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path))
    }

    /// After a flush the pending work item must be cancelled, so a *later*
    /// firing of the debounce can't resurrect an already-written state on top
    /// of something newer.
    func test_flush_cancelsPendingWorkItem() async throws {
        let p = ViewerStatePersistence(url: tmp, debounceMs: 60)
        var s = ViewerState()
        s.lastMeetingId = "scheduled"
        p.scheduleSave(s)
        p.flush()
        XCTAssertEqual(p.load().lastMeetingId, "scheduled")
        // Overwrite out-of-band, then let the original debounce deadline pass.
        var newer = ViewerState()
        newer.lastMeetingId = "newer"
        p.saveImmediately(newer)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(p.load().lastMeetingId, "newer",
                       "the flushed work item must not fire a second time")
    }

    func test_flush_isIdempotent() {
        let p = ViewerStatePersistence(url: tmp, debounceMs: 5_000)
        var s = ViewerState()
        s.lastMeetingId = "once"
        p.scheduleSave(s)
        p.flush()
        p.flush()
        XCTAssertEqual(p.load().lastMeetingId, "once")
    }
}
