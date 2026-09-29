import XCTest
@testable import RecorderCore

final class ContinuationAbsorberTests: XCTestCase {

    private func makeStorage() throws -> MeetingStorage {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-absorb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return MeetingStorage(root: root)
    }

    /// Parent: crashed mid-recording (endedAt nil), pipeline resumed and done.
    /// Child: clean recording of the same call, marked continuationOf.
    private func makePair(storage: MeetingStorage,
                          parentStart: Date,
                          childStart: Date,
                          parentJobState: JobOverallState = .done)
        throws -> (parent: MeetingPaths, child: MeetingPaths) {
        let parent = try storage.createMeeting(startedAt: parentStart)
        try storage.patchMetadata({ m in
            m.detectedApp = "meet"; m.detectedCode = "xxx-yyyy-zzz"
            m.title = "Elliot/Yvan"; m.source = .calendar
        }, at: parent)
        try AtomicJSON.write([
            TranscriptSegment(start: 0, end: 5, speaker: "MOI", text: "début"),
            TranscriptSegment(start: 5, end: 9, speaker: "SPEAKER_00", text: "réponse"),
        ], to: parent.transcriptJson)
        var parentJob = try storage.loadJob(parent)
        parentJob.state = parentJobState
        try storage.saveJob(parentJob, at: parent)

        let child = try storage.createMeeting(startedAt: childStart)
        try storage.patchMetadata({ m in
            m.detectedApp = "meet"; m.detectedCode = "xxx-yyyy-zzz"
            m.continuationOf = parent.slug
            m.endedAt = childStart.addingTimeInterval(300)
            m.durationSeconds = 300
        }, at: child)
        try AtomicJSON.write([
            TranscriptSegment(start: 0, end: 4, speaker: "MOI", text: "on reprend"),
            TranscriptSegment(start: 4, end: 8, speaker: "SPEAKER_00", text: "suite"),
        ], to: child.transcriptJson)
        var childJob = try storage.loadJob(child)
        childJob.state = .done
        try storage.saveJob(childJob, at: child)
        return (parent, child)
    }

    func testAbsorbMergesShiftedTranscriptAndHidesChild() async throws {
        let storage = try makeStorage()
        let t0 = Date(timeIntervalSince1970: 1_784_819_535)
        let (parent, child) = try makePair(storage: storage,
                                           parentStart: t0,
                                           childStart: t0.addingTimeInterval(600))
        let absorber = ContinuationAbsorber(storage: storage, notes: nil)
        try await absorber.absorbIfContinuation(child: child)

        let merged = try AtomicJSON.read([TranscriptSegment].self, from: parent.transcriptJson)
        XCTAssertEqual(merged.count, 4)
        // Child segments shifted by the 600s wall-clock offset, in order.
        XCTAssertEqual(merged.map(\.start), [0, 5, 600, 604])
        // MOI stays MOI; remote diarization labels are namespaced per segment.
        XCTAssertEqual(merged.map(\.speaker),
                       ["MOI", "SPEAKER_00", "MOI", "SPEAKER_00 (2)"])

        let md = try String(contentsOf: parent.transcriptMd, encoding: .utf8)
        XCTAssertTrue(md.contains("on reprend"))

        let parentMeta = try storage.loadMetadata(parent)
        XCTAssertEqual(parentMeta.endedAt, t0.addingTimeInterval(900))
        XCTAssertEqual(parentMeta.durationSeconds, 900)
        XCTAssertEqual(parentMeta.title, "Elliot/Yvan")

        let childMeta = try storage.loadMetadata(child)
        XCTAssertEqual(childMeta.absorbed, true)
    }

    func testAbsorbIsIdempotentOnRetry() async throws {
        let storage = try makeStorage()
        let t0 = Date(timeIntervalSince1970: 1_784_819_535)
        let (parent, child) = try makePair(storage: storage,
                                           parentStart: t0,
                                           childStart: t0.addingTimeInterval(600))
        let absorber = ContinuationAbsorber(storage: storage, notes: nil)
        try await absorber.absorbIfContinuation(child: child)
        // Simulate a crash after the transcript write but before the absorbed
        // flag: clear it and run again — segments must not duplicate.
        try storage.patchMetadata({ $0.absorbed = nil }, at: child)
        try await absorber.absorbIfContinuation(child: child)

        let merged = try AtomicJSON.read([TranscriptSegment].self, from: parent.transcriptJson)
        XCTAssertEqual(merged.count, 4)
    }

    func testAbsorbAdoptsChildIdentityWhenParentHasNone() async throws {
        let storage = try makeStorage()
        let t0 = Date(timeIntervalSince1970: 1_784_819_535)
        let (parent, child) = try makePair(storage: storage,
                                           parentStart: t0,
                                           childStart: t0.addingTimeInterval(600))
        // Parent was a bare detected recording; the child got the calendar
        // retro-link after the relaunch.
        try storage.patchMetadata({ m in
            m.title = nil; m.source = .detected; m.calendarEventId = nil
        }, at: parent)
        try storage.patchMetadata({ m in
            m.title = "Point hebdo"; m.source = .calendar; m.calendarEventId = "e42"
        }, at: child)

        try await ContinuationAbsorber(storage: storage, notes: nil)
            .absorbIfContinuation(child: child)

        let parentMeta = try storage.loadMetadata(parent)
        XCTAssertEqual(parentMeta.title, "Point hebdo")
        XCTAssertEqual(parentMeta.source, .calendar)
        XCTAssertEqual(parentMeta.calendarEventId, "e42")
    }

    func testAbsorbThrowsWhenParentPipelineFailed() async throws {
        let storage = try makeStorage()
        let t0 = Date(timeIntervalSince1970: 1_784_819_535)
        let (_, child) = try makePair(storage: storage,
                                      parentStart: t0,
                                      childStart: t0.addingTimeInterval(600),
                                      parentJobState: .failed)
        let absorber = ContinuationAbsorber(storage: storage, notes: nil,
                                            pollSeconds: 0.01, timeoutSeconds: 0.1)
        do {
            try await absorber.absorbIfContinuation(child: child)
            XCTFail("expected parentPipelineFailed")
        } catch let e as ContinuationAbsorber.AbsorbError {
            guard case .parentPipelineFailed = e else {
                return XCTFail("unexpected error \(e)")
            }
        }
        let childMeta = try storage.loadMetadata(child)
        XCTAssertNil(childMeta.absorbed)
    }

    func testAbsorbNoOpForRegularMeeting() async throws {
        let storage = try makeStorage()
        let paths = try storage.createMeeting(startedAt: Date())
        // Must not throw, must not touch anything — no transcript even exists.
        try await ContinuationAbsorber(storage: storage, notes: nil)
            .absorbIfContinuation(child: paths)
    }

    // MARK: - Continuation detection (RecorderSession.findInterruptedParent)

    func testFindsInterruptedRecordingOfSameCall() throws {
        let storage = try makeStorage()
        let now = Date(timeIntervalSince1970: 1_784_819_535)
        let crashed = try storage.createMeeting(startedAt: now.addingTimeInterval(-1800))
        try storage.patchMetadata({ m in
            m.detectedApp = "meet"; m.detectedCode = "XXX-yyyy-zzz"
        }, at: crashed)

        let found = RecorderSession.findInterruptedParent(
            storage: storage, detectedCode: "xxx-yyyy-zzz",
            excludingSlug: "other", now: now)
        XCTAssertEqual(found?.id, crashed.slug)
    }

    func testIgnoresCleanlyEndedAndOldAndOtherCodeMeetings() throws {
        let storage = try makeStorage()
        let now = Date(timeIntervalSince1970: 1_784_819_535)
        // Cleanly stopped meeting of the same call: endedAt written.
        let ended = try storage.createMeeting(startedAt: now.addingTimeInterval(-1800))
        try storage.patchMetadata({ m in
            m.detectedCode = "xxx-yyyy-zzz"; m.endedAt = now.addingTimeInterval(-600)
        }, at: ended)
        // Crash from a previous day on a reused personal link: outside window.
        let stale = try storage.createMeeting(startedAt: now.addingTimeInterval(-30 * 3600))
        try storage.patchMetadata({ m in m.detectedCode = "xxx-yyyy-zzz" }, at: stale)
        // Interrupted, but a different call.
        let other = try storage.createMeeting(startedAt: now.addingTimeInterval(-900))
        try storage.patchMetadata({ m in m.detectedCode = "aaa-bbbb-ccc" }, at: other)

        XCTAssertNil(RecorderSession.findInterruptedParent(
            storage: storage, detectedCode: "xxx-yyyy-zzz",
            excludingSlug: "current", now: now))
    }
}
