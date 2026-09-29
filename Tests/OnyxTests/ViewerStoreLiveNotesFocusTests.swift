import XCTest
import RecorderCore
@testable import Onyx

/// ⌘⇧L ("Open live notes") used to be a data-loss bug.
///
/// Nothing indexes a meeting while it is being recorded (`MeetingIndexer.upsert`
/// is only ever called by `RescanRunner`), so the in-progress meeting is absent
/// from `ViewerStore.meetings`. `focusLiveNotes()` only flipped the note level to
/// `.live` and left `selectedMeetingId` pointing at whatever the user had last
/// selected — so the editor showed *that* meeting's `notes/live.md` and every
/// keystroke was written into it.
///
/// These tests pin the two halves of the fix: the editor is never pointed at a
/// meeting that is not the active recording (Part A), and the in-progress
/// meeting is reachable even though it has no index row (Part B).
final class ViewerStoreLiveNotesFocusTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-livefocus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    @MainActor
    private func makeStore(storage: MeetingStorage,
                           indexer: MeetingIndexer) throws -> ViewerStore {
        ViewerStore(storage: storage, indexer: indexer, claudeBinary: { nil },
                    persistence: ViewerStatePersistence(
                        url: tmp.appendingPathComponent("viewer_state.json"),
                        debounceMs: 60_000))
    }

    /// Old meeting `old` (indexed, selected by the user) + in-progress meeting
    /// `live` (created by `createMeeting`, deliberately NOT indexed — that is
    /// exactly the state of a recording in flight).
    @MainActor
    private func seedOldAndInProgress() throws
        -> (store: ViewerStore, old: MeetingPaths, inProgress: MeetingPaths) {
        let storage = MeetingStorage(root: tmp.appendingPathComponent("Meetings"))
        let old = try storage.createMeeting(startedAt: Date().addingTimeInterval(-86_400))
        try "OLD LIVE NOTES".write(to: old.liveNotes, atomically: true, encoding: .utf8)
        try "OLD SYNTHESE".write(to: old.notesFile(.synthese), atomically: true, encoding: .utf8)

        let inProgress = try storage.createMeeting(startedAt: Date())

        let indexer = try MeetingIndexer.inMemory()
        try indexer.upsert(meta: try storage.loadMetadata(old), folderPath: old.root,
                           transcriptState: "done", transcript: [])
        let store = try makeStore(storage: storage, indexer: indexer)
        store.meetings = try indexer.listAllGrouped()
        store.selectMeeting(old.slug)
        store.setActiveNoteLevel(.synthese)
        return (store, old, inProgress)
    }

    // MARK: - Part A: the wrong-target write must be impossible

    /// With no active recording there is no legitimate target for ⌘⇧L. Switching
    /// to the `.live` tab anyway points the editor at the previously selected
    /// meeting's `live.md`, which is precisely the corruption path.
    @MainActor
    func test_focusLiveNotes_withNoActiveRecording_doesNotOpenTheLiveTab() throws {
        let (store, old, _) = try seedOldAndInProgress()

        store.focusLiveNotes(slug: nil)

        XCTAssertNotEqual(store.activeNoteLevel, .live,
                          "⌘⇧L with no recording must not open the .live editor")
        XCTAssertEqual(store.selectedMeetingId, old.slug,
                       "selection must be left alone")
    }

    /// An empty slug is the same non-target as `nil` (defensive: the recorder
    /// hands back an optional and callers may stringify it).
    @MainActor
    func test_focusLiveNotes_withEmptySlug_doesNotOpenTheLiveTab() throws {
        let (store, _, _) = try seedOldAndInProgress()
        store.focusLiveNotes(slug: "")
        XCTAssertNotEqual(store.activeNoteLevel, .live)
    }

    /// The core Part A guarantee: whatever was selected before, ⌘⇧L retargets the
    /// editor onto the active recording.
    @MainActor
    func test_focusLiveNotes_retargetsSelectionOntoTheActiveRecording() throws {
        let (store, old, inProgress) = try seedOldAndInProgress()
        XCTAssertEqual(store.selectedMeetingId, old.slug)

        store.focusLiveNotes(slug: inProgress.slug)

        XCTAssertEqual(store.selectedMeetingId, inProgress.slug)
        XCTAssertEqual(store.activeNoteLevel, .live)
    }

    // MARK: - Part B: the in-progress meeting is reachable and writable

    /// End-to-end at the store level: after ⌘⇧L, typing must land in the
    /// in-progress meeting's `notes/live.md` and must leave the previously
    /// selected meeting's file byte-for-byte intact.
    @MainActor
    func test_typingAfterFocusLiveNotes_writesOnlyToTheInProgressMeeting() async throws {
        let (store, old, inProgress) = try seedOldAndInProgress()

        store.focusLiveNotes(slug: inProgress.slug)
        store.onLiveNotesEdited("notes tapées pendant l'appel")

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let written = (try? String(contentsOf: inProgress.liveNotes, encoding: .utf8)) ?? ""
            if written == "notes tapées pendant l'appel" { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(try String(contentsOf: inProgress.liveNotes, encoding: .utf8),
                       "notes tapées pendant l'appel")
        XCTAssertEqual(try String(contentsOf: old.liveNotes, encoding: .utf8),
                       "OLD LIVE NOTES",
                       "the previously selected meeting's live notes must be untouched")
    }

    /// A meeting with no index row must still load its own content — otherwise
    /// `focusLiveNotes` would switch the selection and then show the *old*
    /// meeting's text, which is the same corruption with an extra step.
    @MainActor
    func test_selectMeeting_withoutAnIndexRow_loadsThatMeetingsOwnContent() throws {
        let (store, _, inProgress) = try seedOldAndInProgress()
        try "IN PROGRESS LIVE".write(to: inProgress.liveNotes,
                                    atomically: true, encoding: .utf8)

        store.selectMeeting(inProgress.slug)
        store.setActiveNoteLevel(.live)

        XCTAssertEqual(store.currentLiveNotes, "IN PROGRESS LIVE")
        XCTAssertNotEqual(store.currentNotes, "OLD SYNTHESE",
                          "stale content from the previous selection must be cleared")
    }

    /// `MainPanel` renders the "nothing selected" empty state when no listing can
    /// be resolved — so during a recording the live notes were unreachable even
    /// though `live.md` existed. The store must synthesize a listing from
    /// `meta.json` for a selected-but-unindexed meeting.
    @MainActor
    func test_currentListing_isSynthesizedForAnUnindexedMeeting() throws {
        let (store, _, inProgress) = try seedOldAndInProgress()

        store.focusLiveNotes(slug: inProgress.slug)

        let listing = try XCTUnwrap(store.currentListing,
                                    "an unindexed meeting must still produce a listing")
        XCTAssertEqual(listing.id, inProgress.slug)
        XCTAssertEqual(listing.folderPath, inProgress.root)
        XCTAssertEqual(listing.transcriptState, "in_progress")
    }

    /// The index row, when there is one, stays authoritative (it carries the
    /// title and transcript state the pipeline produced).
    @MainActor
    func test_currentListing_prefersTheIndexRowWhenOneExists() throws {
        let (store, old, _) = try seedOldAndInProgress()
        let listing = try XCTUnwrap(store.currentListing)
        XCTAssertEqual(listing.id, old.slug)
        XCTAssertEqual(listing.transcriptState, "done")
    }

    /// Nothing selected still means the empty state.
    @MainActor
    func test_currentListing_isNilWithNoSelection() throws {
        let storage = MeetingStorage(root: tmp.appendingPathComponent("Meetings"))
        let store = try makeStore(storage: storage,
                                  indexer: try MeetingIndexer.inMemory())
        store.selectedMeetingId = nil
        store.setActiveNoteLevel(.brief)
        XCTAssertNil(store.currentListing)
    }
}
