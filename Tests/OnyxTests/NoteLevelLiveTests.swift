import XCTest
@testable import Onyx
@testable import RecorderCore

/// Covers `NoteLevel.live` (Task 17) and the two hazards it introduces:
/// 1. `.live` must never reach a Claude generation target.
/// 2. `ViewerStore.loadActiveNote` must read `live.md` as *user* notes, not as
///    a generated note whose freshness is compared to `job.json`.
final class NoteLevelLiveTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    // MARK: - Enum

    func test_live_caseExistsWithLiveRawValue() {
        XCTAssertEqual(NoteLevel.live.rawValue, "live")
        XCTAssertEqual(NoteLevel(rawValue: "live"), .live)
    }

    func test_generatable_excludesLive() {
        XCTAssertEqual(NoteLevel.generatable, [.brief, .synthese, .detaillee])
        XCTAssertFalse(NoteLevel.generatable.contains(.live),
                       ".live must never be offered as a generation target")
    }

    /// `.live` writes to the same file as `paths.liveNotes` — so any code path
    /// that treats it as a generated note would clobber the user's own notes.
    func test_notesFileForLive_isTheUserLiveNotesFile() {
        let paths = MeetingPaths(root: tmp, slug: "2026-08-01_10h00")
        XCTAssertEqual(paths.notesFile(.live), paths.liveNotes)
    }

    // MARK: - ViewerStore

    @MainActor
    private func makeStore(paths: MeetingPaths,
                           binary: URL? = nil) throws -> (ViewerStore, MeetingStorage) {
        let storage = MeetingStorage(root: tmp)
        let idx = try MeetingIndexer.inMemory()
        let persistence = ViewerStatePersistence(
            url: tmp.appendingPathComponent("viewer_state.json"))
        let store = ViewerStore(storage: storage, indexer: idx,
                                claudeBinary: { binary },
                                persistence: persistence)
        store.selectedMeetingId = paths.slug
        return (store, storage)
    }

    private func seedMeeting(slug: String = "2026-08-01_10h00",
                             live: String,
                             synthese: String) throws -> MeetingPaths {
        let paths = MeetingPaths(root: tmp, slug: slug)
        try FileManager.default.createDirectory(at: paths.notesDir,
                                               withIntermediateDirectories: true)
        try Data(live.utf8).write(to: paths.liveNotes)
        try Data(synthese.utf8).write(to: paths.notesFile(.synthese))
        try Data("{}".utf8).write(to: paths.job)
        // Make every note look "edited long after the job" so the freshness
        // heuristic would fire if it were (wrongly) applied to .live.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(3600)],
            ofItemAtPath: paths.liveNotes.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(3600)],
            ofItemAtPath: paths.notesFile(.synthese).path)
        return paths
    }

    @MainActor
    func test_loadActiveNote_liveLevel_populatesLiveNotesAndLeavesCurrentNotes() throws {
        let paths = try seedMeeting(live: "USER LIVE NOTES", synthese: "GENERATED SYNTHESE")
        let (store, _) = try makeStore(paths: paths)

        store.activeNoteLevel = .synthese
        store.loadActiveNote(paths: paths)
        XCTAssertEqual(store.currentNotes, "GENERATED SYNTHESE")

        store.activeNoteLevel = .live
        store.loadActiveNote(paths: paths)
        XCTAssertEqual(store.currentLiveNotes, "USER LIVE NOTES",
                       ".live must be read into currentLiveNotes")
        XCTAssertNotEqual(store.currentNotes, "USER LIVE NOTES",
                          "live.md must not be smuggled into currentNotes")
    }

    @MainActor
    func test_loadActiveNote_liveLevel_neverFlagsEditedSinceGeneration() throws {
        let paths = try seedMeeting(live: "USER LIVE NOTES", synthese: "GENERATED SYNTHESE")
        let (store, _) = try makeStore(paths: paths)

        // Sanity: the heuristic DOES fire for a real generated level.
        store.activeNoteLevel = .synthese
        store.loadActiveNote(paths: paths)
        XCTAssertTrue(store.notesEditedSinceGeneration)

        store.activeNoteLevel = .live
        store.loadActiveNote(paths: paths)
        XCTAssertFalse(store.notesEditedSinceGeneration,
                       "live.md is always user-authored — 'edited since generation' is meaningless")
    }

    @MainActor
    func test_onNotesEdited_liveLevel_doesNotOverwriteLiveFile() async throws {
        let paths = try seedMeeting(live: "USER LIVE NOTES", synthese: "GENERATED SYNTHESE")
        let (store, _) = try makeStore(paths: paths)
        store.activeNoteLevel = .live
        store.onNotesEdited("DESTROYED BY GENERATED-NOTES EDITOR")
        try await Task.sleep(nanoseconds: 900_000_000)
        let onDisk = try String(contentsOf: paths.liveNotes, encoding: .utf8)
        XCTAssertEqual(onDisk, "USER LIVE NOTES",
                       "the generated-notes edit path must refuse to write live.md")
    }

    @MainActor
    func test_regenerateActiveNote_liveLevel_isANoOp() async throws {
        let paths = try seedMeeting(live: "USER LIVE NOTES", synthese: "GENERATED SYNTHESE")
        // /bin/echo would "succeed" and write output over live.md if the guard
        // were missing (the generator refuses too, with
        // GenerationError.liveIsNotGeneratable — this asserts the *store* guard).
        let (store, _) = try makeStore(paths: paths,
                                       binary: URL(fileURLWithPath: "/bin/echo"))
        store.activeNoteLevel = .live
        await store.regenerateActiveNote()
        let onDisk = try String(contentsOf: paths.liveNotes, encoding: .utf8)
        XCTAssertEqual(onDisk, "USER LIVE NOTES",
                       "regeneration must be refused for .live")
    }
}
