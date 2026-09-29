import XCTest
import RecorderCore
@testable import Onyx

/// `ViewerStore` is `@MainActor`, so its unstructured `Task { }` bodies inherit
/// the main actor. The synchronous SQLite/FTS5 queries and note-file writes were
/// therefore running *on* the main thread; they now go through a detached
/// executor. These tests pin down the behaviour that restructuring must not
/// change, plus the stale-result race that going genuinely concurrent creates.
final class ViewerStoreAsyncTests: XCTestCase {
    private var tmp: URL!
    private var dbPath: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-async-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        dbPath = tmp.appendingPathComponent("index.sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    @MainActor
    private func makeStore(_ indexer: MeetingIndexer) -> ViewerStore {
        ViewerStore(storage: MeetingStorage(root: tmp),
                    indexer: indexer,
                    claudeBinary: { nil },
                    persistence: ViewerStatePersistence(
                        url: tmp.appendingPathComponent("viewer_state.json"),
                        debounceMs: 60_000))
    }

    private func seed(_ indexer: MeetingIndexer, id: String, title: String,
                      text: String) throws {
        let meta = MeetingMetadata(
            id: id, startedAt: Date(timeIntervalSince1970: 1_000), endedAt: nil,
            durationSeconds: nil, title: title, source: .manual,
            appVersion: "0.1.0", models: .init(whisper: "w", diarization: "d"))
        try indexer.upsert(meta: meta,
                           folderPath: tmp.appendingPathComponent(id),
                           transcriptState: "done",
                           transcript: [TranscriptSegment(start: 1, end: 2,
                                                        speaker: "MOI", text: text)])
    }

    /// Spins the main run loop until `condition` holds — proves the main actor
    /// is free to make progress while the detached work runs, and never blocks
    /// forever on a regression.
    @MainActor
    private func waitUntil(_ description: String,
                           _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for \(description)"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - refreshMeetings

    @MainActor
    func test_refreshMeetings_publishesListingsOnTheMainActor() async throws {
        let indexer = try MeetingIndexer(dbPath: dbPath)
        try seed(indexer, id: "m1", title: "Debug pipeline", text: "whisper hangs")
        let store = makeStore(indexer)

        store.refreshMeetings()
        try await waitUntil("meetings to load") { !store.meetings.isEmpty }
        XCTAssertEqual(store.meetings.map(\.id), ["m1"])
    }

    // MARK: - search

    @MainActor
    func test_onSearchQueryChanged_publishesHits() async throws {
        let indexer = try MeetingIndexer(dbPath: dbPath)
        try seed(indexer, id: "m1", title: "Debug pipeline", text: "whisper hangs")
        let store = makeStore(indexer)

        store.onSearchQueryChanged("whisper")
        XCTAssertEqual(store.searchQuery, "whisper",
                       "the query must be applied synchronously for the text field")
        try await waitUntil("search hits") { !store.searchResults.isEmpty }
        XCTAssertEqual(store.searchResults.map(\.meetingId), ["m1"])
    }

    /// The stale-result guard. Running the FTS5 query off the main actor means
    /// an older search can finish after a newer one; publishing it would show
    /// results for a query the user has already replaced. Here the in-flight
    /// search for "whisper" must refuse to publish because `searchQuery` moved
    /// on underneath it.
    @MainActor
    func test_searchResultForASupersededQueryIsDiscarded() async throws {
        let indexer = try MeetingIndexer(dbPath: dbPath)
        try seed(indexer, id: "m1", title: "Debug pipeline", text: "whisper hangs")
        let store = makeStore(indexer)

        store.onSearchQueryChanged("whisper")
        // Move the query on *without* cancelling the in-flight task, which is
        // exactly the shape of a late-landing older result.
        store.searchQuery = "something else entirely"

        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertTrue(store.searchResults.isEmpty,
                      "a result for a superseded query must never be published")
    }

    @MainActor
    func test_emptyQueryYieldsNoHits() async throws {
        let indexer = try MeetingIndexer(dbPath: dbPath)
        try seed(indexer, id: "m1", title: "Debug pipeline", text: "whisper hangs")
        let store = makeStore(indexer)
        store.onSearchQueryChanged("")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(store.searchResults.isEmpty)
    }

    // MARK: - note writes

    @MainActor
    func test_onNotesEdited_writesFileOffMainAndFlagsEdited() async throws {
        let indexer = try MeetingIndexer.inMemory()
        let store = makeStore(indexer)
        let paths = MeetingPaths(root: tmp, slug: "2026-08-01_10h00")
        try FileManager.default.createDirectory(at: paths.notesDir,
                                                withIntermediateDirectories: true)
        store.selectedMeetingId = paths.slug
        store.activeNoteLevel = .synthese

        store.onNotesEdited("EDITED SYNTHESE")
        XCTAssertEqual(store.currentNotes, "EDITED SYNTHESE",
                       "the editor's text must be applied synchronously")

        try await waitUntil("the debounced note write") {
            (try? String(contentsOf: paths.notesFile(.synthese), encoding: .utf8))
                == "EDITED SYNTHESE"
        }
        XCTAssertTrue(store.notesEditedSinceGeneration)
    }

    /// Debounce + cancellation ordering must survive the restructuring: only the
    /// last edit in a burst reaches disk.
    @MainActor
    func test_onNotesEdited_onlyTheLastEditInABurstIsWritten() async throws {
        let indexer = try MeetingIndexer.inMemory()
        let store = makeStore(indexer)
        let paths = MeetingPaths(root: tmp, slug: "2026-08-01_11h00")
        try FileManager.default.createDirectory(at: paths.notesDir,
                                                withIntermediateDirectories: true)
        store.selectedMeetingId = paths.slug
        store.activeNoteLevel = .brief

        store.onNotesEdited("v1")
        store.onNotesEdited("v2")
        store.onNotesEdited("v3")
        try await waitUntil("the debounced note write") {
            FileManager.default.fileExists(atPath: paths.notesFile(.brief).path)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(try String(contentsOf: paths.notesFile(.brief), encoding: .utf8),
                       "v3")
    }

    @MainActor
    func test_onLiveNotesEdited_writesLiveFile() async throws {
        let indexer = try MeetingIndexer.inMemory()
        let store = makeStore(indexer)
        let paths = MeetingPaths(root: tmp, slug: "2026-08-01_12h00")
        try FileManager.default.createDirectory(at: paths.notesDir,
                                                withIntermediateDirectories: true)
        store.selectedMeetingId = paths.slug

        store.onLiveNotesEdited("MY LIVE NOTES")
        XCTAssertEqual(store.currentLiveNotes, "MY LIVE NOTES")
        try await waitUntil("the debounced live-note write") {
            (try? String(contentsOf: paths.liveNotes, encoding: .utf8)) == "MY LIVE NOTES"
        }
    }
}
