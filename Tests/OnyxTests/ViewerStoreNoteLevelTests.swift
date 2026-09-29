import XCTest
import RecorderCore
@testable import Onyx

/// Switching note tabs must actually load that level's content.
///
/// Before `setActiveNoteLevel` existed, `loadActiveNote` was only reachable via
/// `selectMeeting` / `regenerateActiveNote`, so assigning `activeNoteLevel`
/// (which is what the tab strip and ⌘⇧L did) left the *previous* level's text on
/// screen — and, worse for `.live`, left `notesEditedSinceGeneration` armed from
/// the generated note.
final class ViewerStoreNoteLevelTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-notelevel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    @MainActor
    private func makeStore(storage: MeetingStorage) throws -> ViewerStore {
        ViewerStore(storage: storage,
                    indexer: try MeetingIndexer.inMemory(),
                    claudeBinary: { nil },
                    persistence: ViewerStatePersistence(
                        url: tmp.appendingPathComponent("viewer_state.json"),
                        debounceMs: 60_000))
    }

    /// A meeting with a distinct body in each of the four note files.
    @MainActor
    private func seedAllLevels() throws -> (ViewerStore, MeetingPaths) {
        let storage = MeetingStorage(root: tmp.appendingPathComponent("Meetings"))
        let paths = try storage.createMeeting(startedAt: Date())
        try "LIVE BODY".write(to: paths.liveNotes, atomically: true, encoding: .utf8)
        try "BRIEF BODY".write(to: paths.notesFile(.brief), atomically: true, encoding: .utf8)
        try "SYNTHESE BODY".write(to: paths.notesFile(.synthese), atomically: true, encoding: .utf8)
        try "DETAILLEE BODY".write(to: paths.notesFile(.detaillee), atomically: true, encoding: .utf8)
        let store = try makeStore(storage: storage)
        store.selectedMeetingId = paths.slug
        return (store, paths)
    }

    // MARK: - Every tab shows its own content

    @MainActor
    func test_setActiveNoteLevel_loadsThatLevelsContent() throws {
        let (store, _) = try seedAllLevels()

        store.setActiveNoteLevel(.brief)
        XCTAssertEqual(store.activeNoteLevel, .brief)
        XCTAssertEqual(store.currentNotes, "BRIEF BODY")

        store.setActiveNoteLevel(.synthese)
        XCTAssertEqual(store.currentNotes, "SYNTHESE BODY")

        store.setActiveNoteLevel(.detaillee)
        XCTAssertEqual(store.currentNotes, "DETAILLEE BODY")

        store.setActiveNoteLevel(.live)
        XCTAssertEqual(store.currentLiveNotes, "LIVE BODY")
    }

    /// The `.live` invariant: switching to `.live` must read `liveNotes` into
    /// `currentLiveNotes` and must NOT copy the user's own notes into
    /// `currentNotes` (from where `onNotesEdited` would write them back through
    /// the generated-notes channel).
    @MainActor
    func test_setActiveNoteLevel_live_doesNotTouchGeneratedNotesChannel() throws {
        let (store, _) = try seedAllLevels()
        store.setActiveNoteLevel(.synthese)
        XCTAssertEqual(store.currentNotes, "SYNTHESE BODY")

        store.setActiveNoteLevel(.live)
        XCTAssertEqual(store.currentLiveNotes, "LIVE BODY")
        XCTAssertNotEqual(store.currentNotes, "LIVE BODY",
                          "live notes must never leak into the generated-notes channel")
    }

    /// The banner must never be armed on `.live` — those notes are always
    /// user-authored, so the "edited since generation" heuristic is meaningless
    /// and would leave the banner permanently visible.
    @MainActor
    func test_setActiveNoteLevel_live_disarmsEditedSinceGeneration() throws {
        let (store, paths) = try seedAllLevels()
        // Make the generated note look hand-edited well after the pipeline ran.
        try FileManager.default.setAttributes([.modificationDate: Date()],
                                             ofItemAtPath: paths.job.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: paths.notesFile(.synthese).path)

        store.setActiveNoteLevel(.synthese)
        XCTAssertTrue(store.notesEditedSinceGeneration)

        store.setActiveNoteLevel(.live)
        XCTAssertFalse(store.notesEditedSinceGeneration,
                       "the regenerate banner must never arm for .live")
    }

    /// A level whose file does not exist yet (never generated) must show empty,
    /// not the previous tab's text.
    @MainActor
    func test_setActiveNoteLevel_missingFileClearsPreviousLevelsText() throws {
        let storage = MeetingStorage(root: tmp.appendingPathComponent("Meetings"))
        let paths = try storage.createMeeting(startedAt: Date())
        try "SYNTHESE BODY".write(to: paths.notesFile(.synthese),
                                  atomically: true, encoding: .utf8)
        let store = try makeStore(storage: storage)
        store.selectedMeetingId = paths.slug

        store.setActiveNoteLevel(.synthese)
        XCTAssertEqual(store.currentNotes, "SYNTHESE BODY")
        store.setActiveNoteLevel(.detaillee)   // never generated
        XCTAssertEqual(store.currentNotes, "",
                       "a not-yet-generated level must render empty, not stale text")
    }

    @MainActor
    func test_setActiveNoteLevel_withNoSelectionClearsContent() throws {
        let storage = MeetingStorage(root: tmp.appendingPathComponent("Meetings"))
        let store = try makeStore(storage: storage)
        store.currentNotes = "STALE"
        store.currentLiveNotes = "STALE LIVE"
        store.notesEditedSinceGeneration = true

        store.setActiveNoteLevel(.brief)
        XCTAssertEqual(store.activeNoteLevel, .brief)
        XCTAssertEqual(store.currentNotes, "")
        XCTAssertEqual(store.currentLiveNotes, "")
        XCTAssertFalse(store.notesEditedSinceGeneration)
    }

    // MARK: - Duration

    /// `MainPanel` needs the duration for the header. Reading `meta.json` from a
    /// SwiftUI body would do file IO on every render, so the store publishes it
    /// when the meeting is selected instead.
    @MainActor
    func test_selectMeeting_publishesDurationFromMetadata() async throws {
        let storage = MeetingStorage(root: tmp.appendingPathComponent("Meetings"))
        let paths = try storage.createMeeting(startedAt: Date())
        try storage.patchMetadata({ $0.durationSeconds = 1_845 }, at: paths)
        let indexer = try MeetingIndexer.inMemory()
        let meta = try storage.loadMetadata(paths)
        try indexer.upsert(meta: meta, folderPath: paths.root,
                           transcriptState: "done", transcript: [])
        let store = ViewerStore(storage: storage, indexer: indexer,
                                claudeBinary: { nil },
                                persistence: ViewerStatePersistence(
                                    url: tmp.appendingPathComponent("vs.json"),
                                    debounceMs: 60_000))
        store.meetings = try indexer.listAllGrouped()

        store.selectMeeting(paths.slug)
        XCTAssertEqual(store.currentDurationSeconds, 1_845)
    }

    // MARK: - Restored selection

    /// The selection is restored from `viewer_state.json` at init, but nothing
    /// used to load its content: the viewer opened on a meeting whose header was
    /// filled in and whose notes, transcript and duration were all blank.
    @MainActor
    func test_refreshMeetings_loadsContentForARestoredSelection() async throws {
        let storage = MeetingStorage(root: tmp.appendingPathComponent("Meetings"))
        let paths = try storage.createMeeting(startedAt: Date())
        try "RESTORED SYNTHESE".write(to: paths.notesFile(.synthese),
                                     atomically: true, encoding: .utf8)
        let indexer = try MeetingIndexer.inMemory()
        try indexer.upsert(meta: try storage.loadMetadata(paths),
                           folderPath: paths.root, transcriptState: "done",
                           transcript: [TranscriptSegment(start: 0, end: 1,
                                                          speaker: "MOI", text: "hello")])
        let stateURL = tmp.appendingPathComponent("restored_state.json")
        let persistence = ViewerStatePersistence(url: stateURL, debounceMs: 60_000)
        persistence.saveImmediately(ViewerState(lastMeetingId: paths.slug,
                                                activeNoteLevel: "synthese"))

        let store = ViewerStore(storage: storage, indexer: indexer,
                                claudeBinary: { nil },
                                persistence: ViewerStatePersistence(url: stateURL,
                                                                    debounceMs: 60_000))
        XCTAssertEqual(store.selectedMeetingId, paths.slug)
        XCTAssertEqual(store.currentNotes, "")

        store.refreshMeetings()
        let deadline = Date().addingTimeInterval(5)
        while store.currentNotes.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(store.currentNotes, "RESTORED SYNTHESE")
    }
}
