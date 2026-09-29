import XCTest
import RecorderCore
@testable import Onyx

/// Sidebar checkbox selection + batch delete.
///
/// The invariants that are silent at runtime and expensive to get wrong (the
/// user loses recordings): a meeting being recorded or processed must be
/// impossible to tick and impossible to sweep into a batch, and the footer's
/// count must match what "Supprimer" actually deletes.
final class ViewerStoreMultiDeleteTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-multidelete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    @MainActor
    private func makeStore() throws -> (ViewerStore, MeetingStorage) {
        let storage = MeetingStorage(root: tmp.appendingPathComponent("Meetings"))
        let store = ViewerStore(storage: storage,
                               indexer: try MeetingIndexer.inMemory(),
                               claudeBinary: { nil },
                               persistence: ViewerStatePersistence(
                                   url: tmp.appendingPathComponent("viewer_state.json"),
                                   debounceMs: 60_000))
        return (store, storage)
    }

    /// Three meetings, listed newest-first as the sidebar does.
    @MainActor
    private func seedThree(_ store: ViewerStore,
                           _ storage: MeetingStorage) throws -> [String] {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let slugs = try (0..<3).map { i -> String in
            try storage.createMeeting(startedAt: base.addingTimeInterval(Double(i) * 3600)).slug
        }
        store.meetings = slugs.reversed().map {
            MeetingListing(id: $0, startedAt: base, title: $0,
                           folderPath: MeetingPaths(root: storage.root, slug: $0).root,
                           transcriptState: "done", source: .manual)
        }
        return slugs
    }

    // MARK: - Mode

    @MainActor
    func test_beginAndEndSelecting_clearTheTicks() throws {
        let (store, storage) = try makeStore()
        let slugs = try seedThree(store, storage)

        XCTAssertFalse(store.isSelecting)
        store.beginSelecting()
        XCTAssertTrue(store.isSelecting)

        store.toggleChecked(slugs[0])
        XCTAssertTrue(store.isChecked(slugs[0]))

        store.endSelecting()
        XCTAssertFalse(store.isSelecting)
        XCTAssertTrue(store.checkedMeetingIds.isEmpty,
                      "an abandoned selection must not survive into the next one")

        store.beginSelecting()
        XCTAssertTrue(store.checkedMeetingIds.isEmpty)
    }

    @MainActor
    func test_toggleChecked_isAToggle() throws {
        let (store, storage) = try makeStore()
        let slugs = try seedThree(store, storage)
        store.beginSelecting()

        store.toggleChecked(slugs[1])
        XCTAssertEqual(store.checkedMeetingIds, [slugs[1]])
        store.toggleChecked(slugs[1])
        XCTAssertTrue(store.checkedMeetingIds.isEmpty)
    }

    /// A search has no checkable rows, so typing one leaves the mode.
    @MainActor
    func test_searchQueryCancelsSelectionMode() throws {
        let (store, storage) = try makeStore()
        let slugs = try seedThree(store, storage)
        store.beginSelecting()
        store.toggleChecked(slugs[0])

        store.onSearchQueryChanged("   ")
        XCTAssertTrue(store.isSelecting, "a blank query is still browse mode")

        store.onSearchQueryChanged("produit")
        XCTAssertFalse(store.isSelecting)
        XCTAssertTrue(store.checkedMeetingIds.isEmpty)
    }

    // MARK: - Busy meetings

    @MainActor
    func test_recordingOrProcessingMeetingCannotBeTicked() throws {
        let (store, storage) = try makeStore()
        let slugs = try seedThree(store, storage)
        store.setPipelineState(slug: slugs[0], state: .recording)
        store.setPipelineState(slug: slugs[1], state: .transcribing)
        store.beginSelecting()

        store.toggleChecked(slugs[0])
        store.toggleChecked(slugs[1])
        XCTAssertTrue(store.checkedMeetingIds.isEmpty,
                      "neither a recording nor a running pipeline may be ticked")

        store.toggleChecked(slugs[2])
        XCTAssertEqual(store.checkedMeetingIds, [slugs[2]])
    }

    @MainActor
    func test_checkAllDeletable_skipsTheRecordingInProgress() throws {
        let (store, storage) = try makeStore()
        let slugs = try seedThree(store, storage)
        store.setPipelineState(slug: slugs[0], state: .recording)

        store.beginSelecting()
        store.checkAllDeletable()
        XCTAssertEqual(store.checkedMeetingIds, Set([slugs[1], slugs[2]]),
                       "\"Tout\" must not sweep the live recording into the batch")
    }

    /// The gap between ticking and pressing Supprimer: the box stays ticked but
    /// the meeting is now busy, so it must be dropped from the batch — and the
    /// others must still be deleted.
    @MainActor
    func test_meetingThatBecameBusyIsExcludedButTheRestAreDeleted() throws {
        let (store, storage) = try makeStore()
        let slugs = try seedThree(store, storage)
        store.beginSelecting()
        slugs.forEach { store.toggleChecked($0) }
        XCTAssertEqual(store.deletableCheckedIds.count, 3)

        store.setPipelineState(slug: slugs[0], state: .transcribing)
        XCTAssertEqual(Set(store.deletableCheckedIds), Set([slugs[1], slugs[2]]),
                       "the footer count must exclude the now-busy meeting")

        store.deleteCheckedMeetings()
        XCTAssertEqual(store.meetings.map(\.id), [slugs[0]])
        XCTAssertFalse(store.isSelecting)
    }

    // MARK: - Deletion

    @MainActor
    func test_deleteCheckedMeetings_trashesFoldersAndLeavesTheMode() async throws {
        let (store, storage) = try makeStore()
        let slugs = try seedThree(store, storage)
        store.beginSelecting()
        store.toggleChecked(slugs[0])
        store.toggleChecked(slugs[2])

        store.deleteCheckedMeetings()

        XCTAssertEqual(store.meetings.map(\.id), [slugs[1]],
                       "only the unticked meeting stays in the sidebar")
        XCTAssertFalse(store.isSelecting)
        XCTAssertTrue(store.checkedMeetingIds.isEmpty)

        // The trashing itself is off-main and fire-and-forget.
        let gone = { (slug: String) in
            !FileManager.default.fileExists(
                atPath: MeetingPaths(root: storage.root, slug: slug).root.path)
        }
        for _ in 0..<200 where !(gone(slugs[0]) && gone(slugs[2])) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(gone(slugs[0]))
        XCTAssertTrue(gone(slugs[2]))
        XCTAssertFalse(gone(slugs[1]), "an unticked meeting must not be trashed")
    }

    /// Deleting the meeting that is open must clear the selection first — the
    /// player would otherwise keep a file open inside a trashed folder.
    @MainActor
    func test_deletingTheOpenMeetingClearsTheSelection() throws {
        let (store, storage) = try makeStore()
        let slugs = try seedThree(store, storage)
        store.selectedMeetingId = slugs[1]

        store.beginSelecting()
        store.toggleChecked(slugs[1])
        store.deleteCheckedMeetings()

        XCTAssertNil(store.selectedMeetingId)
    }

    @MainActor
    func test_deleteMeetings_ignoresDuplicateIdsAndEmptyBatches() throws {
        let (store, storage) = try makeStore()
        let slugs = try seedThree(store, storage)

        store.deleteMeetings([])
        XCTAssertEqual(store.meetings.count, 3)

        store.deleteMeetings([slugs[0], slugs[0]])
        XCTAssertEqual(store.meetings.count, 2)
    }
}
