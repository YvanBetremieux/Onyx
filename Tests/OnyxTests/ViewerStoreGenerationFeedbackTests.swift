import XCTest
import RecorderCore
@testable import Onyx

/// Regeneration must be *observable*: a click that silently does nothing is a
/// bug report waiting to happen — and got one. The original
/// `regenerateActiveNote` returned silently when the binary was nil and
/// swallowed every `GenerationError` in an empty catch, so a stale
/// `claudeBinaryPath` (the binary moved during a Claude Code update) made the
/// "Générer" buttons look dead with no trace anywhere.
final class ViewerStoreGenerationFeedbackTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-genfeedback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    @MainActor
    private func makeStore(binary: URL?) throws -> (ViewerStore, MeetingPaths) {
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
        store.setActiveNoteLevel(.brief)
        return (store, paths)
    }

    /// Fake claude: echoes stdin back — same trick as ClaudeNoteGeneratorTests.
    private func makeEchoBinary(sleepSeconds: Double = 0) throws -> URL {
        let url = tmp.appendingPathComponent("fake-claude.sh")
        let sleepLine = sleepSeconds > 0 ? "sleep \(sleepSeconds)\n" : ""
        try "#!/bin/sh\n\(sleepLine)cat\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
        return url
    }

    // MARK: - Silent-failure paths must surface an error

    @MainActor
    func test_missingBinary_surfacesErrorMentioningThePath() async throws {
        let gone = tmp.appendingPathComponent("no-such-claude")
        let (store, _) = try makeStore(binary: gone)

        await store.regenerateActiveNote()

        let err = try XCTUnwrap(store.generationError,
                                "a nonexistent binary must produce a visible error, not silence")
        XCTAssertTrue(err.contains(gone.path), "the message should say WHICH path is stale")
        XCTAssertFalse(store.isGeneratingNote)
    }

    @MainActor
    func test_nilBinary_surfacesConfigurationError() async throws {
        let (store, _) = try makeStore(binary: nil)

        await store.regenerateActiveNote()

        XCTAssertNotNil(store.generationError,
                        "an unconfigured binary must produce a visible error, not silence")
        XCTAssertFalse(store.isGeneratingNote)
    }

    @MainActor
    func test_failingBinary_surfacesError() async throws {
        let (store, _) = try makeStore(binary: URL(fileURLWithPath: "/usr/bin/false"))

        await store.regenerateActiveNote()

        XCTAssertNotNil(store.generationError,
                        "a non-zero exit must produce a visible error, not silence")
        XCTAssertFalse(store.isGeneratingNote)
    }

    // MARK: - Success path

    @MainActor
    func test_success_reloadsNotesAndClearsError() async throws {
        let (store, paths) = try makeStore(binary: try makeEchoBinary())

        await store.regenerateActiveNote()

        XCTAssertNil(store.generationError)
        XCTAssertFalse(store.isGeneratingNote)
        XCTAssertFalse(store.currentNotes.isEmpty,
                       "the freshly generated note must be loaded into the editor")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.notesFile(.brief).path))
    }

    // MARK: - In-progress feedback

    @MainActor
    func test_isGeneratingNote_isTrueWhileRunning_andFalseAfter() async throws {
        let (store, _) = try makeStore(binary: try makeEchoBinary(sleepSeconds: 0.4))

        let run = Task { await store.regenerateActiveNote() }
        // Poll until the flag flips on (the subprocess sleeps 0.4 s, so this
        // cannot race past the whole generation).
        var sawGenerating = false
        for _ in 0..<100 {
            if store.isGeneratingNote { sawGenerating = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await run.value

        XCTAssertTrue(sawGenerating, "the UI needs a visible in-progress state")
        XCTAssertFalse(store.isGeneratingNote, "and it must always be cleared afterwards")
    }

    @MainActor
    func test_secondClickWhileRunning_isIgnored() async throws {
        let bin = try makeEchoBinary(sleepSeconds: 0.4)
        let (store, paths) = try makeStore(binary: bin)

        let first = Task { await store.regenerateActiveNote() }
        for _ in 0..<100 where !store.isGeneratingNote {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // Re-entrant click: must not spawn a second subprocess over the first.
        await store.regenerateActiveNote()
        XCTAssertTrue(store.isGeneratingNote,
                      "the re-entrant call must return immediately without tearing down the run")
        await first.value

        XCTAssertNil(store.generationError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.notesFile(.brief).path))
    }

    // MARK: - Error lifetime

    @MainActor
    func test_errorIsScopedToItsOwnTab() async throws {
        let (store, _) = try makeStore(binary: nil)
        await store.regenerateActiveNote()
        XCTAssertNotNil(store.generationError)

        store.setActiveNoteLevel(.synthese)
        XCTAssertNil(store.generationError,
                     "an error about the brief tab must not linger over the synthèse tab")

        store.setActiveNoteLevel(.brief)
        XCTAssertNotNil(store.generationError,
                        "…but it must still be there when the user comes back to brief: "
                        + "each level is an independent generation session")
    }

    // MARK: - Parallel sessions

    /// Each level is an independent session: launching brief must not block
    /// synthèse, and both subprocesses run at the same time.
    @MainActor
    func test_twoLevelsGenerateInParallel() async throws {
        let bin = try makeEchoBinary(sleepSeconds: 0.5)
        let (store, paths) = try makeStore(binary: bin)

        let brief = Task { await store.regenerateNote(level: .brief) }
        let synthese = Task { await store.regenerateNote(level: .synthese) }

        // Both must be observably in flight at once. If synthèse were queued
        // behind brief (the old global flag) it would never overlap the 0.5 s
        // window of the first subprocess.
        var sawBothRunning = false
        for _ in 0..<100 {
            if store.isGenerating(level: .brief) && store.isGenerating(level: .synthese) {
                sawBothRunning = true; break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await brief.value
        await synthese.value

        XCTAssertTrue(sawBothRunning,
                      "brief and synthèse must run as two parallel sessions, not a queue")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.notesFile(.brief).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.notesFile(.synthese).path))
        XCTAssertFalse(store.isGenerating(level: .brief))
        XCTAssertFalse(store.isGenerating(level: .synthese))
    }

    /// A generation finishing on a *backgrounded* tab must not clobber what the
    /// user is currently reading on another tab.
    @MainActor
    func test_backgroundedGenerationDoesNotClobberVisibleNote() async throws {
        let (store, _) = try makeStore(binary: try makeEchoBinary(sleepSeconds: 0.3))

        let run = Task { await store.regenerateNote(level: .brief) }
        store.setActiveNoteLevel(.synthese)
        store.currentNotes = "ce que je suis en train de lire"
        await run.value

        XCTAssertEqual(store.currentNotes, "ce que je suis en train de lire",
                       "finishing brief in the background must not reload the synthèse editor")
        XCTAssertEqual(store.activeNoteLevel, .synthese)
    }

    /// `.live` stays a silent no-op: its button is disabled everywhere, so an
    /// error message would only ever be reachable programmatically — and the
    /// invariant tests already pin that nothing is written.
    @MainActor
    func test_liveLevel_staysSilentNoOp() async throws {
        let (store, _) = try makeStore(binary: try makeEchoBinary())
        store.setActiveNoteLevel(.live)

        await store.regenerateActiveNote()

        XCTAssertNil(store.generationError)
        XCTAssertFalse(store.isGeneratingNote)
    }
}
