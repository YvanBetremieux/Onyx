import XCTest
@testable import RecorderCore

final class ClaudeNoteGeneratorTests: XCTestCase {
    /// Creates a temporary bash script that reads stdin and echoes a marker
    /// wrapping it — makes it easy to assert the input was passed through.
    private func makeFakeBinary() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-fake-claude-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("claude")
        let body = """
        #!/bin/bash
        echo "# Test note"
        echo
        cat
        echo
        echo "END"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        return script
    }

    private func makeMeetingWithTranscript() throws -> MeetingPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-notegen-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        let storage = MeetingStorage(root: root)
        let paths = try storage.createMeeting(startedAt: Date())
        // Ensure the transcripts subdirectory exists before writing the .md.
        try FileManager.default.createDirectory(at: paths.transcripts,
                                                withIntermediateDirectories: true)
        try "MOI: hello\nSPEAKER_00: hi there".write(to: paths.transcriptMd,
                                                     atomically: true,
                                                     encoding: .utf8)
        return paths
    }

    func testGeneratesNotesFile() async throws {
        let binary = try makeFakeBinary()
        defer { try? FileManager.default.removeItem(at: binary.deletingLastPathComponent()) }
        let paths = try makeMeetingWithTranscript()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let gen = ClaudeNoteGenerator()
        try await gen.generate(paths: paths, level: .brief, binary: binary)

        let target = paths.notesFile(.brief)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        let out = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(out.contains("# Test note"))
        XCTAssertTrue(out.contains("hello"), "transcript must reach stdin")
        XCTAssertTrue(out.contains("END"))
    }

    func testCreatesNotesDirIfMissing() async throws {
        let binary = try makeFakeBinary()
        defer { try? FileManager.default.removeItem(at: binary.deletingLastPathComponent()) }
        let paths = try makeMeetingWithTranscript()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.notesDir.path))
        let gen = ClaudeNoteGenerator()
        try await gen.generate(paths: paths, level: .synthese, binary: binary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.notesDir.path))
    }

    func testTimesOutOnHangingBinary() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-hang-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("claude")
        try "#!/bin/bash\nsleep 30".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)

        let paths = try makeMeetingWithTranscript()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let gen = ClaudeNoteGenerator(timeoutSeconds: 1)
        do {
            try await gen.generate(paths: paths, level: .brief, binary: script)
            XCTFail("expected timeout error")
        } catch ClaudeNoteGenerator.GenerationError.timedOut {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testNonZeroExitRaisesError() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-fail-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("claude")
        try "#!/bin/bash\ncat > /dev/null\necho boom >&2\nexit 3".write(to: script, atomically: true,
                                                       encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)

        let paths = try makeMeetingWithTranscript()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let gen = ClaudeNoteGenerator()
        do {
            try await gen.generate(paths: paths, level: .brief, binary: script)
            XCTFail("expected error")
        } catch ClaudeNoteGenerator.GenerationError.nonZeroExit(let code, _) {
            XCTAssertEqual(code, 3)
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }
}
