import XCTest
@testable import RecorderCore

final class ClaudeAuthMonitorTests: XCTestCase {
    /// Compteur d'appels du callback de transition, thread-safe : l'actor peut
    /// l'appeler depuis n'importe quel contexte.
    private final class ChangeSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [ClaudeAuthStatus] = []
        func record(_ s: ClaudeAuthStatus) { lock.lock(); seen.append(s); lock.unlock() }
        var all: [ClaudeAuthStatus] { lock.lock(); defer { lock.unlock() }; return seen }
    }

    private func tempStateFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-auth-\(UUID().uuidString).json")
    }

    /// Writes an executable fake `claude` binary as a temp bash script.
    /// Mirrors the fixture pattern in `ClaudeNoteGeneratorTests`.
    private func makeFakeBinary(script body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-fake-claude-probe-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("claude")
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        return script
    }

    func testStartsUnknownWithNoStateFile() async {
        let monitor = ClaudeAuthMonitor(stateFile: tempStateFile())
        let status = await monitor.status
        XCTAssertEqual(status, .unknown)
    }

    func testAuthFailureBecomesDisconnectedAndPersists() async throws {
        let file = tempStateFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let spy = ChangeSpy()
        let monitor = ClaudeAuthMonitor(stateFile: file) { spy.record($0) }

        // Date à la seconde pleine, volontairement : `AtomicJSON` encode en
        // ISO-8601 sans fraction de seconde, donc un `Date()` quelconque ne
        // survit pas tel quel à l'aller-retour disque. Ce qui doit être
        // vérifié ici, c'est la persistance du statut — pas la précision
        // sous-seconde, que la couche de stockage ne prétend pas garder.
        let since = Date(timeIntervalSince1970: 1_757_000_000)
        let err = ClaudeNoteGenerator.GenerationError.authFailed(.sessionExpired, output: "x")
        await monitor.reportFailure(err, at: since)

        let status = await monitor.status
        guard case .disconnected(let failure, let at) = status else {
            return XCTFail("expected disconnected, got \(status)")
        }
        XCTAssertEqual(failure, .sessionExpired)
        XCTAssertEqual(at, since)
        XCTAssertEqual(spy.all.count, 1)
        // Persisté : la bannière doit être correcte dès le prochain lancement,
        // sans attendre une première réunion.
        let reread = ClaudeAuthMonitor(stateFile: file)
        let rereadStatus = await reread.status
        XCTAssertEqual(rereadStatus, status)
    }

    /// Onze réunions ont échoué d'affilée pendant l'incident. Le callback ne
    /// doit tirer qu'une fois, sinon c'est onze notifications macOS.
    func testRepeatedFailuresNotifyOnce() async {
        let file = tempStateFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let spy = ChangeSpy()
        let monitor = ClaudeAuthMonitor(stateFile: file) { spy.record($0) }
        let err = ClaudeNoteGenerator.GenerationError.authFailed(.notLoggedIn, output: "")

        for _ in 0..<11 { await monitor.reportFailure(err) }

        XCTAssertEqual(spy.all.count, 1)
    }

    func testSuccessAfterDisconnectionReconnects() async {
        let file = tempStateFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let spy = ChangeSpy()
        let monitor = ClaudeAuthMonitor(stateFile: file) { spy.record($0) }
        await monitor.reportFailure(
            ClaudeNoteGenerator.GenerationError.authFailed(.notLoggedIn, output: ""))

        await monitor.reportSuccess()

        let status = await monitor.status
        guard case .connected = status else {
            return XCTFail("expected connected, got \(status)")
        }
        XCTAssertEqual(spy.all.count, 2)
    }

    /// Un timeout ou un quota n'est pas une déconnexion : le statut ne bouge
    /// pas et aucune bannière ne s'affiche.
    func testNonAuthFailureLeavesStatusUntouched() async {
        let file = tempStateFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let spy = ChangeSpy()
        let monitor = ClaudeAuthMonitor(stateFile: file) { spy.record($0) }

        await monitor.reportFailure(ClaudeNoteGenerator.GenerationError.timedOut)
        await monitor.reportFailure(
            ClaudeNoteGenerator.GenerationError.nonZeroExit(code: 1, stdout: "quota",
                                                            stderr: ""))

        let status = await monitor.status
        XCTAssertEqual(status, .unknown)
        XCTAssertTrue(spy.all.isEmpty)
    }

    /// Deux succès consécutifs rafraîchissent l'horodatage mais ne sont pas une
    /// transition — pas de callback pour le second.
    func testSecondSuccessDoesNotNotifyButRefreshesTimestamp() async {
        let file = tempStateFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let spy = ChangeSpy()
        let monitor = ClaudeAuthMonitor(stateFile: file) { spy.record($0) }

        let early = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)
        await monitor.reportSuccess(at: early)
        await monitor.reportSuccess(at: later)

        let status = await monitor.status
        XCTAssertEqual(status, .connected(checkedAt: later))
        XCTAssertEqual(spy.all.count, 1)
    }

    func testCorruptStateFileDegradesToUnknown() async throws {
        let file = tempStateFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try "{ not json".write(to: file, atomically: true, encoding: .utf8)

        let monitor = ClaudeAuthMonitor(stateFile: file)
        let status = await monitor.status
        XCTAssertEqual(status, .unknown)
    }

    /// C1 regression: eleven meetings failed across two days during the
    /// incident. `since` must stay pinned to the FIRST failure so the banner
    /// can say "depuis deux jours" — not slide forward to "now" on every
    /// subsequent failure of the same kind.
    func testSinceStaysPinnedToFirstFailureOfARepeatedKind() async {
        let file = tempStateFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let spy = ChangeSpy()
        let monitor = ClaudeAuthMonitor(stateFile: file) { spy.record($0) }

        let first = Date(timeIntervalSince1970: 1_000)
        let second = Date(timeIntervalSince1970: 200_000) // ~2 days later
        let err = ClaudeNoteGenerator.GenerationError.authFailed(.notLoggedIn, output: "")
        await monitor.reportFailure(err, at: first)
        await monitor.reportFailure(err, at: second)

        let status = await monitor.status
        guard case .disconnected(let failure, let since) = status else {
            return XCTFail("expected disconnected, got \(status)")
        }
        XCTAssertEqual(failure, .notLoggedIn)
        XCTAssertEqual(since, first, "since must stay pinned to the first failure")
        XCTAssertEqual(spy.all.count, 1, "repeated failure of the same kind is not a transition")
    }

    // MARK: - probe (C3)

    func testProbeWithSuccessfulBinaryReportsConnectedAndUpdatesStatus() async throws {
        let binary = try makeFakeBinary(script: "#!/bin/bash\ncat > /dev/null\nexit 0\n")
        defer { try? FileManager.default.removeItem(at: binary.deletingLastPathComponent()) }
        let file = tempStateFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let monitor = ClaudeAuthMonitor(stateFile: file)

        let outcome = await monitor.probe(binary: binary)

        XCTAssertEqual(outcome, .connected)
        let status = await monitor.status
        guard case .connected = status else {
            return XCTFail("expected connected, got \(status)")
        }
    }

    func testProbeWithAuthFailingBinaryReportsDisconnectedAndUpdatesStatus() async throws {
        let binary = try makeFakeBinary(script: """
        #!/bin/bash
        cat > /dev/null
        echo 'Not logged in · Please run /login'
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: binary.deletingLastPathComponent()) }
        let file = tempStateFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let monitor = ClaudeAuthMonitor(stateFile: file)

        let outcome = await monitor.probe(binary: binary)

        XCTAssertEqual(outcome, .disconnected(.notLoggedIn))
        let status = await monitor.status
        guard case .disconnected(let failure, _) = status else {
            return XCTFail("expected disconnected, got \(status)")
        }
        XCTAssertEqual(failure, .notLoggedIn)
    }

    /// A broken binary path must never masquerade as a logout: the outcome is
    /// inconclusive and the status is left exactly as it was.
    func testProbeWithMissingBinaryIsInconclusiveAndLeavesStatusUnchanged() async {
        let file = tempStateFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let monitor = ClaudeAuthMonitor(stateFile: file)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-does-not-exist-\(UUID().uuidString)")

        let outcome = await monitor.probe(binary: missing)

        guard case .inconclusive = outcome else {
            return XCTFail("expected inconclusive, got \(outcome)")
        }
        let status = await monitor.status
        XCTAssertEqual(status, .unknown)
    }

    /// A hanging binary (network cut, stuck CLI) must not be classified as a
    /// disconnection, and the probe must still return promptly once the
    /// configured timeout elapses rather than hanging indefinitely.
    func testProbeWithHangingBinaryTimesOutInconclusiveAndReturnsPromptly() async throws {
        let binary = try makeFakeBinary(script: "#!/bin/bash\nsleep 30\n")
        defer { try? FileManager.default.removeItem(at: binary.deletingLastPathComponent()) }
        let file = tempStateFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let monitor = ClaudeAuthMonitor(stateFile: file, probeTimeout: 1)

        let start = Date()
        let outcome = await monitor.probe(binary: binary)
        let elapsed = Date().timeIntervalSince(start)

        guard case .inconclusive = outcome else {
            return XCTFail("expected inconclusive, got \(outcome)")
        }
        XCTAssertLessThan(elapsed, 10, "probe must return promptly after its timeout, not hang")
        let status = await monitor.status
        XCTAssertEqual(status, .unknown)
    }
}
