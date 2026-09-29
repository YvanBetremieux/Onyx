import XCTest
@testable import RecorderCore

/// The notes the user types during a meeting live in `notes/live.md`. They must
/// still be there after the recording stops — the pipeline's notes step and the
/// indexing pass both run over the same folder, and either one silently
/// clobbering `live.md` would lose writing that cannot be reproduced.
final class LiveNotesSurviveIndexingTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-livesurvive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    private static let typed = "- décision : on garde le cache\n- TODO Yvan : brancher le retry\n"

    /// A rescan is what finally gives the meeting its index row (nothing indexes
    /// a meeting while it is being recorded). It must read the folder, not write
    /// to it.
    func test_rescan_doesNotTouchLiveNotes() async throws {
        let storage = MeetingStorage(root: tmp.appendingPathComponent("Meetings"))
        let paths = try storage.createMeeting(startedAt: Date())
        try Self.typed.write(to: paths.liveNotes, atomically: true, encoding: .utf8)
        var job = try storage.loadJob(paths)
        job.state = .done
        try storage.saveJob(job, at: paths)

        let indexer = try MeetingIndexer.inMemory()
        try await RescanRunner(storage: storage, indexer: indexer).rescan()

        XCTAssertEqual(try indexer.listAllGrouped().count, 1,
                       "the meeting must be indexed (otherwise this proves nothing)")
        XCTAssertEqual(try String(contentsOf: paths.liveNotes, encoding: .utf8),
                       Self.typed)
    }

    /// Re-creating paths for an existing meeting (`createMeeting` is the only
    /// place that ever writes `live.md` in RecorderCore) must not blank it.
    func test_createMeeting_neverOverwritesExistingLiveNotes() throws {
        let storage = MeetingStorage(root: tmp.appendingPathComponent("Meetings"))
        let paths = try storage.createMeeting(startedAt: Date())
        try Self.typed.write(to: paths.liveNotes, atomically: true, encoding: .utf8)

        // Same minute → collision suffix, i.e. a *different* folder. The first
        // meeting's live notes must be untouched either way.
        let second = try storage.createMeeting(startedAt: Date())
        XCTAssertNotEqual(second.slug, paths.slug)
        XCTAssertEqual(try String(contentsOf: paths.liveNotes, encoding: .utf8),
                       Self.typed)
    }

    /// `notesFile(.live)` resolves to the same file as `liveNotes`, so a
    /// generation targeting `.live` would overwrite the user's writing. The
    /// generator must refuse before it can.
    func test_generator_refusesLiveAndLeavesTheFileIntact() async throws {
        let storage = MeetingStorage(root: tmp.appendingPathComponent("Meetings"))
        let paths = try storage.createMeeting(startedAt: Date())
        try Self.typed.write(to: paths.liveNotes, atomically: true, encoding: .utf8)

        do {
            try await ClaudeNoteGenerator().generate(
                paths: paths, level: .live,
                binary: URL(fileURLWithPath: "/usr/bin/true"))
            XCTFail("generating .live must throw")
        } catch ClaudeNoteGenerator.GenerationError.liveIsNotGeneratable {
            // expected
        }
        XCTAssertEqual(try String(contentsOf: paths.liveNotes, encoding: .utf8),
                       Self.typed)
    }
}
