import XCTest
import RecorderCore
@testable import Onyx

/// End-to-end title behaviour through the store: a synthèse generation titles
/// an untitled huddle/manual meeting, never a calendar one, and a manual
/// rename both persists and disarms future auto-detection.
final class ViewerStoreTitleTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-title-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    /// Fake claude that emits a TITRE line then a note body, whatever the input.
    private func makeTitlingBinary() throws -> URL {
        let url = tmp.appendingPathComponent("fake-claude-title.sh")
        try """
        #!/bin/sh
        cat > /dev/null
        printf 'TITRE: Sujet detecte par Claude\\n\\n## Notes\\ncorps\\n'
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
        return url
    }

    @MainActor
    private func makeStore(binary: URL) throws -> (ViewerStore, MeetingStorage, MeetingPaths) {
        let storage = MeetingStorage(root: tmp.appendingPathComponent("Meetings"))
        let paths = try storage.createMeeting(startedAt: Date())
        try "MOI: transcript body".write(to: paths.transcriptMd, atomically: true, encoding: .utf8)
        let store = ViewerStore(storage: storage,
                                indexer: try MeetingIndexer.inMemory(),
                                claudeBinary: { binary },
                                persistence: ViewerStatePersistence(
                                    url: tmp.appendingPathComponent("viewer_state.json"),
                                    debounceMs: 60_000))
        store.selectedMeetingId = paths.slug
        return (store, storage, paths)
    }

    @MainActor
    func test_syntheseOnUntitledMeeting_setsAutoDetectedTitle() async throws {
        let (store, storage, paths) = try makeStore(binary: try makeTitlingBinary())

        await store.regenerateNote(level: .synthese)

        let meta = try storage.loadMetadata(paths)
        XCTAssertEqual(meta.title, "Sujet detecte par Claude")
        XCTAssertEqual(meta.titleAutoDetected, true)
        let note = try String(contentsOf: paths.notesFile(.synthese), encoding: .utf8)
        XCTAssertFalse(note.contains("TITRE:"),
                       "the TITRE line is metadata, it must not leak into the note")
        XCTAssertTrue(note.contains("## Notes"))
    }

    @MainActor
    func test_briefGeneration_neverDetectsTitle() async throws {
        let (store, storage, paths) = try makeStore(binary: try makeTitlingBinary())

        await store.regenerateNote(level: .brief)

        XCTAssertNil(try storage.loadMetadata(paths).title,
                     "title detection is a synthèse-only behaviour")
    }

    @MainActor
    func test_calendarMeeting_keepsEventTitle() async throws {
        let (store, storage, paths) = try makeStore(binary: try makeTitlingBinary())
        try storage.patchMetadata({ m in
            m.source = .calendar
            m.title = "Weekly produit"
        }, at: paths)

        await store.regenerateNote(level: .synthese)

        let meta = try storage.loadMetadata(paths)
        XCTAssertEqual(meta.title, "Weekly produit",
                       "calendar title is authoritative — no debate")
        XCTAssertNotEqual(meta.titleAutoDetected, true)
    }

    @MainActor
    func test_manualRename_persistsAndDisarmsAutoDetection() async throws {
        let (store, storage, paths) = try makeStore(binary: try makeTitlingBinary())

        await store.regenerateNote(level: .synthese)
        XCTAssertEqual(try storage.loadMetadata(paths).titleAutoDetected, true)

        store.renameSelectedMeeting("  Mon vrai titre  ")
        var meta = try storage.loadMetadata(paths)
        XCTAssertEqual(meta.title, "Mon vrai titre", "trimmed and persisted")
        XCTAssertEqual(meta.titleAutoDetected, false)

        // A later regeneration must not touch the user's title anymore.
        await store.regenerateNote(level: .synthese)
        meta = try storage.loadMetadata(paths)
        XCTAssertEqual(meta.title, "Mon vrai titre")
    }

    @MainActor
    func test_renameToEmpty_clearsTitle() async throws {
        let (store, storage, paths) = try makeStore(binary: try makeTitlingBinary())
        store.renameSelectedMeeting("Un titre")
        store.renameSelectedMeeting("   ")
        XCTAssertNil(try storage.loadMetadata(paths).title)
    }
}
