import XCTest
@testable import RecorderCore

final class ClaudeNoteGeneratorLiveInjectionTests: XCTestCase {
    var tmp: URL!
    var echoBinary: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // Fake "claude" binary: echoes stdin to stdout.
        echoBinary = tmp.appendingPathComponent("fake-claude.sh")
        try? "#!/bin/sh\ncat\n".write(to: echoBinary, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: echoBinary.path)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    private func makePaths() throws -> MeetingPaths {
        let storage = MeetingStorage(root: tmp.appendingPathComponent("Meetings"))
        let p = try storage.createMeeting(startedAt: Date())
        try "MOI: transcript body".write(to: p.transcriptMd, atomically: true, encoding: .utf8)
        return p
    }

    func test_emptyLiveNotes_promptExcludesLiveBlock() async throws {
        let paths = try makePaths()
        // live.md is created empty by MeetingStorage.createMeeting (Task 2).
        let gen = ClaudeNoteGenerator()
        try await gen.generate(paths: paths, level: .synthese, binary: echoBinary)
        let out = try String(contentsOf: paths.notesFile(.synthese))
        XCTAssertFalse(out.contains("Notes prises par l'utilisateur"),
                       "no live block when live.md is empty")
    }

    func test_populatedLiveNotes_promptIncludesThem() async throws {
        let paths = try makePaths()
        try "- decision X\n- action Y".write(to: paths.liveNotes,
                                             atomically: true, encoding: .utf8)
        let gen = ClaudeNoteGenerator()
        try await gen.generate(paths: paths, level: .synthese, binary: echoBinary)
        let out = try String(contentsOf: paths.notesFile(.synthese))
        XCTAssertTrue(out.contains("Notes prises par l'utilisateur"))
        XCTAssertTrue(out.contains("- decision X"))
        XCTAssertTrue(out.contains("- action Y"))
    }

    func test_missingLiveFile_isSilentlyTreatedAsEmpty() async throws {
        let paths = try makePaths()
        try FileManager.default.removeItem(at: paths.liveNotes)
        let gen = ClaudeNoteGenerator()
        try await gen.generate(paths: paths, level: .brief, binary: echoBinary)
        // Should not throw, and prompt should not contain the live block.
        let out = try String(contentsOf: paths.notesFile(.brief))
        XCTAssertFalse(out.contains("Notes prises par l'utilisateur"))
    }
}
