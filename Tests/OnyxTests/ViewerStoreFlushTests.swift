import XCTest
import RecorderCore
@testable import Onyx

/// Viewer state is persisted through a 500 ms debounce. Quitting inside that
/// window used to silently drop the change; `flushState()` is the escape hatch
/// wired to `NSApplication.willTerminateNotification` and `windowShouldClose`.
final class ViewerStoreFlushTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-flush-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    @MainActor
    private func makeStore(_ persistence: ViewerStatePersistence) throws -> ViewerStore {
        ViewerStore(storage: MeetingStorage(root: tmp),
                    indexer: try MeetingIndexer.inMemory(),
                    claudeBinary: { nil },
                    persistence: persistence)
    }

    @MainActor
    func test_flushState_persistsCurrentStateWithoutWaitingForDebounce() throws {
        let url = tmp.appendingPathComponent("viewer_state.json")
        // A debounce far longer than the test: only a real flush can produce a
        // correct file here.
        let p = ViewerStatePersistence(url: url, debounceMs: 60_000)
        let store = try makeStore(p)

        store.selectedMeetingId = "2026-08-01_10h00"
        store.activeNoteLevel = .brief
        store.setSplitRatio(0.42)
        store.transcriptPanelHidden = true
        store.searchQuery = "budget"

        store.flushState()

        let onDisk = p.load()
        XCTAssertEqual(onDisk.lastMeetingId, "2026-08-01_10h00")
        XCTAssertEqual(onDisk.activeNoteLevel, "brief")
        XCTAssertEqual(onDisk.notesToTranscriptRatio, 0.42, accuracy: 0.0001)
        XCTAssertTrue(onDisk.transcriptPanelHidden)
        XCTAssertEqual(onDisk.lastSearchQuery, "budget")
    }

    /// And the flushed state must survive a fresh store built over the same
    /// file — i.e. this is a real round trip, not just a well-formed write.
    @MainActor
    func test_flushedStateIsReloadedByANewStore() throws {
        let url = tmp.appendingPathComponent("viewer_state.json")
        let p = ViewerStatePersistence(url: url, debounceMs: 60_000)
        let store = try makeStore(p)
        store.selectedMeetingId = "meeting-x"
        store.activeNoteLevel = .detaillee
        store.flushState()

        let reloaded = try makeStore(ViewerStatePersistence(url: url, debounceMs: 60_000))
        XCTAssertEqual(reloaded.selectedMeetingId, "meeting-x")
        XCTAssertEqual(reloaded.activeNoteLevel, .detaillee)
    }
}
