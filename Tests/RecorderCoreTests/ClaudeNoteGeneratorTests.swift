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

    /// The Settings model pick must reach the CLI as `--model <alias>`; no
    /// pick must add no flag at all (the CLI then uses its own default).
    func testModelFlagIsPassedToTheBinary() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-fake-claude-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("claude")
        try "#!/bin/bash\ncat > /dev/null\necho \"ARGS:$@\"\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try makeMeetingWithTranscript()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let gen = ClaudeNoteGenerator()
        try await gen.generate(paths: paths, level: .brief, binary: script, model: "haiku")
        var out = try String(contentsOf: paths.notesFile(.brief), encoding: .utf8)
        XCTAssertTrue(out.contains("--model haiku"), "got: \(out)")

        try await gen.generate(paths: paths, level: .synthese, binary: script, model: nil)
        out = try String(contentsOf: paths.notesFile(.synthese), encoding: .utf8)
        XCTAssertFalse(out.contains("--model"), "no pick must add no flag; got: \(out)")
    }

    func testCreatesNotesDirIfMissing() async throws {
        let binary = try makeFakeBinary()
        defer { try? FileManager.default.removeItem(at: binary.deletingLastPathComponent()) }
        let paths = try makeMeetingWithTranscript()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        // createMeeting pre-creates notes/ (for live.md) — remove it to exercise
        // the generator's own directory creation.
        try FileManager.default.removeItem(at: paths.notesDir)
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

    func testNonZeroExitRaisesErrorKeepingBothStreams() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-fail-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("claude")
        try "#!/bin/bash\ncat > /dev/null\necho out-boom\necho err-boom >&2\nexit 3"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)

        let paths = try makeMeetingWithTranscript()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let gen = ClaudeNoteGenerator()
        do {
            try await gen.generate(paths: paths, level: .brief, binary: script)
            XCTFail("expected error")
        } catch ClaudeNoteGenerator.GenerationError.nonZeroExit(let code, let out, let err) {
            XCTAssertEqual(code, 3)
            // stdout était jeté avant ce correctif : c'est ce qui a rendu
            // l'incident du 2026-09-07 indiagnosticable pendant deux jours.
            XCTAssertTrue(out.contains("out-boom"), "stdout must be preserved")
            XCTAssertTrue(err.contains("err-boom"), "stderr must be preserved")
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    /// Reproduction exacte de l'incident : le CLI sort en 1 et écrit son
    /// message d'auth sur stdout.
    func testAuthFailureOnStdoutIsClassified() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-auth-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("claude")
        try "#!/bin/bash\ncat > /dev/null\necho 'Not logged in · Please run /login'\nexit 1"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)

        let paths = try makeMeetingWithTranscript()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        do {
            try await ClaudeNoteGenerator().generate(paths: paths, level: .brief,
                                                     binary: script)
            XCTFail("expected authFailed")
        } catch ClaudeNoteGenerator.GenerationError.authFailed(let failure, let output) {
            XCTAssertEqual(failure, .notLoggedIn)
            XCTAssertTrue(output.contains("Not logged in"))
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    /// The stdout-only case above was already the working branch; this one
    /// covers the branch that used to be silently dropped (B1 review fix).
    func testAuthFailureOnStderrOnlyIsClassified() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-auth-err-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("claude")
        try "#!/bin/bash\ncat > /dev/null\necho 'Not logged in · Please run /login' >&2\nexit 1"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)

        let paths = try makeMeetingWithTranscript()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        do {
            try await ClaudeNoteGenerator().generate(paths: paths, level: .brief,
                                                     binary: script)
            XCTFail("expected authFailed")
        } catch ClaudeNoteGenerator.GenerationError.authFailed(let failure, let output) {
            XCTAssertEqual(failure, .notLoggedIn)
            XCTAssertTrue(output.contains("Not logged in"))
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    /// Regression guard for B1: when both streams carry distinct text, the
    /// joined output must contain both, not just whichever one used to win.
    func testAuthFailureJoinsBothStreamsWhenBothCarryText() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-auth-both-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("claude")
        try """
        #!/bin/bash
        cat > /dev/null
        echo 'Not logged in · Please run /login'
        echo 'http 401 detail' >&2
        exit 1
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)

        let paths = try makeMeetingWithTranscript()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        do {
            try await ClaudeNoteGenerator().generate(paths: paths, level: .brief,
                                                     binary: script)
            XCTFail("expected authFailed")
        } catch ClaudeNoteGenerator.GenerationError.authFailed(let failure, let output) {
            XCTAssertEqual(failure, .notLoggedIn)
            XCTAssertTrue(output.contains("Not logged in"), "got: \(output)")
            XCTAssertTrue(output.contains("http 401 detail"), "got: \(output)")
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    /// B3: captured output must be capped before it can land in `job.json` —
    /// an auth outage repeats this per meeting for as long as it lasts.
    func testNonZeroExitOutputIsTruncatedToTheCap() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-cap-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("claude")
        // Dump far more than the 4_000-char cap onto stdout.
        try """
        #!/bin/bash
        cat > /dev/null
        for i in $(seq 1 2000); do echo "line-$i-0123456789"; done
        exit 3
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)

        let paths = try makeMeetingWithTranscript()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        do {
            try await ClaudeNoteGenerator().generate(paths: paths, level: .brief,
                                                     binary: script)
            XCTFail("expected error")
        } catch ClaudeNoteGenerator.GenerationError.nonZeroExit(_, let out, _) {
            XCTAssertLessThanOrEqual(out.count, 4_000, "stdout must be capped")
            XCTAssertTrue(out.contains("line-2000"),
                          "the tail must be kept, not the head; got suffix: \(out.suffix(50))")
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    /// `.live` is the user's own hand-written notes. Refusing it must be a
    /// *thrown error*, not a `precondition` — preconditions are live in release
    /// builds, so a stale `defaultNoteLevel = "live"` reaching here would take
    /// the whole menu-bar app down instead of skipping one note.
    func testLiveLevelThrowsInsteadOfTrappingAndLeavesLiveNotesIntact() async throws {
        let binary = try makeFakeBinary()
        defer { try? FileManager.default.removeItem(at: binary.deletingLastPathComponent()) }
        let paths = try makeMeetingWithTranscript()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        try FileManager.default.createDirectory(at: paths.notesDir,
                                                withIntermediateDirectories: true)
        try "USER LIVE NOTES".write(to: paths.liveNotes, atomically: true, encoding: .utf8)

        do {
            try await ClaudeNoteGenerator().generate(paths: paths, level: .live,
                                                     binary: binary)
            XCTFail("expected GenerationError.liveIsNotGeneratable")
        } catch ClaudeNoteGenerator.GenerationError.liveIsNotGeneratable {
            // ok
        } catch {
            XCTFail("unexpected: \(error)")
        }

        XCTAssertEqual(try String(contentsOf: paths.liveNotes, encoding: .utf8),
                       "USER LIVE NOTES",
                       "the user's live notes must be untouched")
    }

    /// The refusal must happen before any other validation, so it is reported
    /// as "not generatable" rather than masked by e.g. a missing transcript.
    func testLiveLevelIsRefusedEvenWithoutATranscript() async throws {
        let binary = try makeFakeBinary()
        defer { try? FileManager.default.removeItem(at: binary.deletingLastPathComponent()) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-live-refuse-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = MeetingPaths(root: root, slug: "2026-08-01_10h00")

        do {
            try await ClaudeNoteGenerator().generate(paths: paths, level: .live,
                                                     binary: binary)
            XCTFail("expected GenerationError.liveIsNotGeneratable")
        } catch ClaudeNoteGenerator.GenerationError.liveIsNotGeneratable {
            // ok
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }
}
