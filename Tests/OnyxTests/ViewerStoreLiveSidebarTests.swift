import XCTest
import RecorderCore
@testable import Onyx

/// Real-time viewer behaviour: a meeting that exists on disk but has no index
/// row yet (recording or mid-pipeline) must still show up in the sidebar, and
/// pipeline state pushes must translate into live status labels.
final class ViewerStoreLiveSidebarTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-livesidebar-\(UUID().uuidString)", isDirectory: true)
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

    @MainActor
    func test_unindexedMeetingAppearsInSidebar() async throws {
        let (store, storage) = try makeStore()
        let paths = try storage.createMeeting(startedAt: Date())

        store.refreshMeetings()
        // refreshMeetings is fire-and-forget; poll for the async publish.
        for _ in 0..<100 where store.meetings.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let row = try XCTUnwrap(store.meetings.first(where: { $0.id == paths.slug }),
                                "a meeting with no index row must still be listed")
        XCTAssertEqual(row.transcriptState, "in_progress",
                       "a freshly created meeting is mid-flight, not done")
    }

    @MainActor
    func test_pipelineStatePush_drivesLiveLabel_andDoneClearsIt() async throws {
        let (store, storage) = try makeStore()
        let paths = try storage.createMeeting(startedAt: Date())
        let slug = paths.slug

        store.setPipelineState(slug: slug, state: .recording)
        XCTAssertEqual(store.liveStatusLabel(for: slug), "Enregistrement…")

        store.setPipelineState(slug: slug, state: .transcribing)
        XCTAssertEqual(store.liveStatusLabel(for: slug), "Transcription…")

        store.setPipelineState(slug: slug, state: .generatingNotes)
        let notesLabel = try XCTUnwrap(store.liveStatusLabel(for: slug))
        XCTAssertTrue(notesLabel.hasPrefix("Génération des notes…"),
                      "got: \(notesLabel)")
        XCTAssertTrue(notesLabel.hasSuffix("%"),
                      "the notes badge now carries an estimated percentage")

        store.setPipelineState(slug: slug, state: .done)
        XCTAssertNil(store.liveStatusLabel(for: slug),
                     "a finished meeting carries no live badge")
    }

    /// Transcription shows a measured percentage when the chunker reports
    /// progress, and stays a plain label on the full-file fallback.
    @MainActor
    func test_transcriptionLabel_includesChunkProgress() async throws {
        let (store, storage) = try makeStore()
        let paths = try storage.createMeeting(startedAt: Date())
        store.setPipelineState(slug: paths.slug, state: .transcribing)

        XCTAssertEqual(store.liveStatusLabel(for: paths.slug), "Transcription…",
                       "no progress info → plain label (full-file fallback)")

        store.pipelineProgress[paths.slug] = 0.42
        XCTAssertEqual(store.liveStatusLabel(for: paths.slug), "Transcription… 42 %")

        store.setPipelineState(slug: paths.slug, state: .done)
        XCTAssertNil(store.pipelineProgress[paths.slug],
                     "progress must be cleared with the state")
    }

    func test_notesProgressEstimate_isMonotonicAndCapped() {
        XCTAssertEqual(ViewerStore.notesProgressPercent(elapsed: 0), 0)
        let p30 = ViewerStore.notesProgressPercent(elapsed: 30)
        let p75 = ViewerStore.notesProgressPercent(elapsed: 75)
        let p150 = ViewerStore.notesProgressPercent(elapsed: 150)
        XCTAssertTrue(p30 < p75 && p75 < p150, "must grow with elapsed time")
        XCTAssertEqual(p75, 63, "63 % at the typical duration (1 - 1/e)")
        XCTAssertLessThanOrEqual(ViewerStore.notesProgressPercent(elapsed: 3600), 99,
                                 "must never claim 100 % before the real completion")
    }

    /// The row badge must distinguish "recorded but not yet transcribed"
    /// (persisted in_progress, no live push) from live processing and from a
    /// finished meeting.
    @MainActor
    func test_rowStatus_fallsBackToPersistedState() async throws {
        let (store, storage) = try makeStore()
        let paths = try storage.createMeeting(startedAt: Date())
        store.refreshMeetings()
        for _ in 0..<100 where store.meetings.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let row = try XCTUnwrap(store.meetings.first(where: { $0.id == paths.slug }))

        // No live push: falls back to the persisted "in_progress".
        var status = try XCTUnwrap(store.rowStatus(for: row))
        XCTAssertEqual(status.label, "En attente de transcription")
        XCTAssertEqual(status.kind, .waiting)

        // Live push wins over the fallback.
        store.setPipelineState(slug: paths.slug, state: .transcribing)
        status = try XCTUnwrap(store.rowStatus(for: row))
        XCTAssertEqual(status.label, "Transcription…")
        XCTAssertEqual(status.kind, .processing)

        // Done: no badge at all.
        store.setPipelineState(slug: paths.slug, state: .done)
        let doneRow = try XCTUnwrap(store.meetings.first(where: { $0.id == paths.slug }))
        XCTAssertNil(store.rowStatus(for: doneRow))
    }

    @MainActor
    func test_terminalStateIsMirroredIntoListings() async throws {
        let (store, storage) = try makeStore()
        let paths = try storage.createMeeting(startedAt: Date())
        store.refreshMeetings()
        for _ in 0..<100 where store.meetings.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        store.setPipelineState(slug: paths.slug, state: .done)
        XCTAssertEqual(store.meetings.first(where: { $0.id == paths.slug })?.transcriptState,
                       "done",
                       "the in-memory listing must flip to done without a re-query")
    }
}
