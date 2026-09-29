import XCTest
import RecorderCore
@testable import Onyx

/// The viewer half of the manual merge: which ticked meetings are mergeable and
/// in what order, and the end state the user is left with — one row in the
/// sidebar, the merged meeting selected.
final class ViewerStoreMergeTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-vmerge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    @MainActor
    private func makeStore() throws -> (ViewerStore, MeetingStorage, MeetingIndexer) {
        let storage = MeetingStorage(root: tmp.appendingPathComponent("Meetings"))
        let indexer = try MeetingIndexer.inMemory()
        let store = ViewerStore(storage: storage, indexer: indexer,
                                claudeBinary: { nil },   // notes fan-out no-ops
                                persistence: ViewerStatePersistence(
                                    url: tmp.appendingPathComponent("viewer_state.json"),
                                    debounceMs: 60_000))
        return (store, storage, indexer)
    }

    /// A finished, indexed meeting.
    @discardableResult
    private func seed(_ storage: MeetingStorage, _ indexer: MeetingIndexer,
                      start: Date, title: String, text: String,
                      state: JobOverallState = .done) throws -> MeetingPaths {
        let paths = try storage.createMeeting(startedAt: start)
        try storage.patchMetadata({ m in m.title = title; m.durationSeconds = 60 },
                                  at: paths)
        try AtomicJSON.write([TranscriptSegment(start: 0, end: 5,
                                                speaker: "MOI", text: text)],
                             to: paths.transcriptJson)
        var job = try storage.loadJob(paths)
        job.state = state
        try storage.saveJob(job, at: paths)
        RescanRunner(storage: storage, indexer: indexer).reindex(slug: paths.slug)
        return paths
    }

    @MainActor
    private func waitForMeetings(_ store: ViewerStore, count: Int) async throws {
        store.refreshMeetings()
        for _ in 0..<200 where store.meetings.count != count {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.meetings.count, count)
    }

    private let t0 = Date(timeIntervalSince1970: 1_784_800_000)

    // MARK: - Eligibility

    @MainActor
    func test_mergeNeedsAtLeastTwoTickedMeetings() async throws {
        let (store, storage, indexer) = try makeStore()
        let a = try seed(storage, indexer, start: t0, title: "A", text: "a")
        try seed(storage, indexer, start: t0.addingTimeInterval(3600), title: "B", text: "b")
        try await waitForMeetings(store, count: 2)

        store.beginSelecting()
        XCTAssertFalse(store.canMergeChecked)
        store.toggleChecked(a.slug)
        XCTAssertFalse(store.canMergeChecked, "one part is not a merge")
        store.toggleChecked(store.meetings[0].id == a.slug
                            ? store.meetings[1].id : store.meetings[0].id)
        XCTAssertTrue(store.canMergeChecked)
    }

    /// The order is chronological, never the order the boxes were ticked — that
    /// is what the confirmation dialog shows and what the parts become.
    @MainActor
    func test_mergeableIdsAreOrderedOldestFirst() async throws {
        let (store, storage, indexer) = try makeStore()
        let a = try seed(storage, indexer, start: t0, title: "A", text: "a")
        let b = try seed(storage, indexer, start: t0.addingTimeInterval(3600),
                         title: "B", text: "b")
        let c = try seed(storage, indexer, start: t0.addingTimeInterval(7200),
                         title: "C", text: "c")
        try await waitForMeetings(store, count: 3)

        store.beginSelecting()
        // Ticked newest → oldest.
        store.toggleChecked(c.slug)
        store.toggleChecked(a.slug)
        store.toggleChecked(b.slug)
        XCTAssertEqual(store.mergeableCheckedIds, [a.slug, b.slug, c.slug])
    }

    /// A failed meeting has no transcript to contribute; it is deletable but not
    /// mergeable, and the two counts must not be confused in the footer.
    @MainActor
    func test_failedMeetingIsDeletableButNotMergeable() async throws {
        let (store, storage, indexer) = try makeStore()
        let a = try seed(storage, indexer, start: t0, title: "A", text: "a")
        let bad = try seed(storage, indexer, start: t0.addingTimeInterval(3600),
                           title: "KO", text: "", state: .failed)
        try await waitForMeetings(store, count: 2)

        store.beginSelecting()
        store.checkAllDeletable()
        XCTAssertEqual(Set(store.deletableCheckedIds), Set([a.slug, bad.slug]))
        XCTAssertEqual(store.mergeableCheckedIds, [a.slug])
        XCTAssertFalse(store.canMergeChecked)
    }

    // MARK: - End state

    @MainActor
    func test_mergeLeavesOneRowSelectedOnTheMergedMeeting() async throws {
        let (store, storage, indexer) = try makeStore()
        let a = try seed(storage, indexer, start: t0, title: "Matin", text: "un")
        let b = try seed(storage, indexer, start: t0.addingTimeInterval(14_400),
                         title: "Aprem", text: "deux")
        try await waitForMeetings(store, count: 2)

        store.beginSelecting()
        store.toggleChecked(a.slug)
        store.toggleChecked(b.slug)
        await store.mergeCheckedMeetings()

        XCTAssertNil(store.mergeError)
        XCTAssertFalse(store.isSelecting, "the merge leaves selection mode")
        XCTAssertFalse(store.isMerging)
        XCTAssertEqual(store.selectedMeetingId, a.slug,
                       "the user lands on the merged meeting")

        try await waitForMeetings(store, count: 1)
        XCTAssertEqual(store.meetings.first?.id, a.slug)
        XCTAssertEqual(store.meetings.first?.title, "Matin")

        // The absorbed meeting is gone from the index but not from the disk.
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.root.path))
        XCTAssertEqual(try storage.loadMetadata(b).mergedInto, a.slug)

        // The merged transcript is what the viewer shows, and the parts are
        // published for the UI.
        XCTAssertEqual(store.currentTranscript.map(\.text), ["un", "deux"])
        XCTAssertEqual(store.currentMergedParts.map(\.slug), [a.slug, b.slug])
    }

    @MainActor
    func test_mergeFailureIsReportedAndChangesNothing() async throws {
        let (store, storage, indexer) = try makeStore()
        let a = try seed(storage, indexer, start: t0, title: "A", text: "a")
        let b = try seed(storage, indexer, start: t0.addingTimeInterval(3600),
                         title: "B", text: "b")
        try await waitForMeetings(store, count: 2)

        store.beginSelecting()
        store.toggleChecked(a.slug)
        store.toggleChecked(b.slug)
        // Slip a running pipeline under the merge, exactly as a recording
        // starting between the tick and the click would.
        var job = try storage.loadJob(b)
        job.state = .transcribing
        try storage.saveJob(job, at: b)

        await store.mergeCheckedMeetings()

        XCTAssertNotNil(store.mergeError)
        XCTAssertTrue(store.isSelecting, "a failed merge keeps the selection")
        XCTAssertNil(try storage.loadMetadata(a).mergedParts)
        XCTAssertNil(try storage.loadMetadata(b).mergedInto)
    }
}
