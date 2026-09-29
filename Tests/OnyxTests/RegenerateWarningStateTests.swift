import XCTest
import RecorderCore
@testable import Onyx

final class RegenerateWarningStateTests: XCTestCase {
    var tmp: URL!
    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp); super.tearDown() }

    @MainActor
    func test_bannerShows_whenNoteMtimeAfterJobMtimePlusBuffer() async throws {
        let storage = MeetingStorage(root: tmp.appendingPathComponent("Meetings"))
        let paths = try storage.createMeeting(startedAt: Date())
        try "generated".write(to: paths.notesFile(.synthese),
                              atomically: true, encoding: .utf8)
        // Simulate the pipeline finishing.
        try FileManager.default.setAttributes([.modificationDate: Date()],
                                              ofItemAtPath: paths.job.path)
        // Now edit the note "later".
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(30)],
            ofItemAtPath: paths.notesFile(.synthese).path)

        let dbPath = tmp.appendingPathComponent("i.sqlite")
        let idx = try MeetingIndexer(dbPath: dbPath)
        // Inject a temp-path persistence — the default writes to the real
        // ~/Library/Application Support/Onyx/viewer_state.json and would
        // pollute the user's actual viewer state during tests.
        let persistence = ViewerStatePersistence(
            url: tmp.appendingPathComponent("viewer_state.json"), debounceMs: 60_000)
        let store = ViewerStore(storage: storage, indexer: idx,
                                claudeBinary: { nil }, persistence: persistence)
        store.selectedMeetingId = paths.slug
        store.activeNoteLevel = .synthese
        store.loadActiveNote(paths: paths)
        XCTAssertTrue(store.notesEditedSinceGeneration)
    }

    /// The same freshness heuristic must NOT arm on `.live`: `notes/live.md` is
    /// hand-typed by definition, so "modified after job.json" is always true and
    /// the banner would be permanently visible.
    @MainActor
    func test_bannerNeverArmsForLive() async throws {
        let storage = MeetingStorage(root: tmp.appendingPathComponent("Meetings"))
        let paths = try storage.createMeeting(startedAt: Date())
        try "my own notes".write(to: paths.liveNotes, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()],
                                             ofItemAtPath: paths.job.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(600)],
            ofItemAtPath: paths.liveNotes.path)

        let store = ViewerStore(
            storage: storage, indexer: try MeetingIndexer.inMemory(),
            claudeBinary: { nil },
            persistence: ViewerStatePersistence(
                url: tmp.appendingPathComponent("viewer_state.json"), debounceMs: 60_000))
        store.selectedMeetingId = paths.slug
        store.setActiveNoteLevel(.live)

        XCTAssertFalse(store.notesEditedSinceGeneration)
        XCTAssertFalse(NotesPanelRules.showsRegenerateBanner(
            level: .live, notesEdited: true, dismissed: false),
                       "even a wrongly-armed flag must not surface the banner on .live")
    }
}
