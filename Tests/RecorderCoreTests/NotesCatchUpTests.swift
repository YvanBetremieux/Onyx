import XCTest
@testable import RecorderCore

final class NotesCatchUpTests: XCTestCase {
    private func makeStorage() throws -> (MeetingStorage, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-catchup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (MeetingStorage(root: root), root)
    }

    /// Crée une réunion au slug donné avec un `job.json` dont l'étape .notes
    /// porte le statut et l'erreur voulus.
    private func makeMeeting(_ storage: MeetingStorage, slug: String,
                             notesStatus: JobStepStatus,
                             notesError: String?) throws {
        let paths = MeetingPaths(root: storage.root, slug: slug)
        try FileManager.default.createDirectory(at: paths.root,
                                                withIntermediateDirectories: true)
        var job = JobState.fresh()
        for step in JobStep.allCases { job.markDone(step) }
        job.state = .done
        job.steps[.notes] = JobStepRecord(status: notesStatus, startedAt: Date(),
                                          completedAt: Date(), error: notesError)
        try storage.saveJob(job, at: paths)
    }

    func testSelectsOnlyAuthFailures() throws {
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }

        try makeMeeting(storage, slug: "2026-09-08_09h59", notesStatus: .failed,
                        notesError: "authFailed(RecorderCore.ClaudeAuthFailure.notLoggedIn, output: \"Not logged in\")")
        try makeMeeting(storage, slug: "2026-09-08_10h29", notesStatus: .failed,
                        notesError: "timedOut")
        try makeMeeting(storage, slug: "2026-09-08_11h01", notesStatus: .done,
                        notesError: nil)

        let pending = try NotesCatchUp.pendingSlugs(storage: storage)
        XCTAssertEqual(pending, ["2026-09-08_09h59"])
    }

    /// Les `job.json` écrits AVANT le correctif de la tâche 2 ne contiennent
    /// que `nonZeroExit(code: 1, stderr: "")` — aucun marqueur d'auth. Ils ne
    /// sont donc pas récupérables, et c'est assumé (voir le spec).
    func testLegacyErrorsWithoutMarkersAreNotSelected() throws {
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeMeeting(storage, slug: "2026-09-07_09h59", notesStatus: .failed,
                        notesError: "nonZeroExit(code: 1, stderr: \"\")")

        XCTAssertTrue(try NotesCatchUp.pendingSlugs(storage: storage).isEmpty)
    }

    /// Un `job.json` postérieur au correctif qui garde le message brut du CLI
    /// est reconnu par motif, même sans le nom du cas Swift.
    func testRawCliMessageIsRecognised() throws {
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeMeeting(storage, slug: "2026-09-08_14h46", notesStatus: .failed,
                        notesError: "nonZeroExit(code: 1, stdout: \"Not logged in · Please run /login\", stderr: \"\")")

        XCTAssertEqual(try NotesCatchUp.pendingSlugs(storage: storage),
                       ["2026-09-08_14h46"])
    }

    func testResultIsChronological() throws {
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let err = "authFailed(RecorderCore.ClaudeAuthFailure.notLoggedIn, output: \"\")"
        try makeMeeting(storage, slug: "2026-09-08_14h46", notesStatus: .failed, notesError: err)
        try makeMeeting(storage, slug: "2026-09-07_09h59", notesStatus: .failed, notesError: err)
        try makeMeeting(storage, slug: "2026-09-08_09h59", notesStatus: .failed, notesError: err)

        XCTAssertEqual(try NotesCatchUp.pendingSlugs(storage: storage),
                       ["2026-09-07_09h59", "2026-09-08_09h59", "2026-09-08_14h46"])
    }

    /// Un dossier sans `job.json` lisible est ignoré, sans faire échouer tout
    /// le balayage.
    func testUnreadableJobIsSkipped() throws {
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let orphan = root.appendingPathComponent("2026-09-08_16h00", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try "not json".write(to: orphan.appendingPathComponent("job.json"),
                             atomically: true, encoding: .utf8)

        XCTAssertNoThrow(try NotesCatchUp.pendingSlugs(storage: storage))
        XCTAssertTrue(try NotesCatchUp.pendingSlugs(storage: storage).isEmpty)
    }
}
