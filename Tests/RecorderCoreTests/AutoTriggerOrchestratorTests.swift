import XCTest
@testable import RecorderCore

final class AutoTriggerOrchestratorTests: XCTestCase {

    actor FakeSession: RecordingSession {
        struct Log: Equatable {
            enum Op { case start, stop, cancel, patch }
            let op: Op
            let meta: MeetingMetadata?
        }
        private(set) var log: [Log] = []
        private(set) var currentMeta: MeetingMetadata?
        private var stopError: Error?
        // Deterministic gate: when armed, the next start() parks until releaseStart().
        private var holdStart = false
        private var startGate: CheckedContinuation<Void, Never>?
        var isStartParked: Bool { startGate != nil }

        func holdNextStart() { holdStart = true }
        func releaseStart() { startGate?.resume(); startGate = nil }
        func setStopError(_ e: Error?) { stopError = e }

        func start(meta: MeetingMetadata) async throws {
            if holdStart {
                holdStart = false
                await withCheckedContinuation { startGate = $0 }
            }
            currentMeta = meta
            log.append(.init(op: .start, meta: meta))
        }
        func stop() async throws {
            if let e = stopError { throw e }
            log.append(.init(op: .stop, meta: currentMeta))
            currentMeta = nil
        }
        func cancel() async throws {
            log.append(.init(op: .cancel, meta: currentMeta))
            currentMeta = nil
        }
        func patchMeta(_ mut: @Sendable (inout MeetingMetadata) -> Void) async throws {
            guard var m = currentMeta else { return }
            mut(&m); currentMeta = m
            log.append(.init(op: .patch, meta: m))
        }
    }

    private func now() -> Date { Date() }

    /// Spins until the gated start() call is actually parked on the session,
    /// so a subsequent event deterministically lands during `.starting`.
    private func waitUntilStartParked(_ session: FakeSession) async {
        while await !session.isStartParked { await Task.yield() }
    }

    func testCalendarStartTriggersRecording() async throws {
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session)
        let match = MatchedEvent(id: "e1", title: "Design review",
                                 startDate: now(), endDate: now().addingTimeInterval(1800),
                                 meetURL: URL(string: "https://meet.google.com/aaa-bbbb-ccc")!,
                                 calendarId: "cal-work")
        try await orch.onCalendarEvent(match)
        let log = await session.log
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log.first?.op, .start)
        XCTAssertEqual(log.first?.meta?.source, .calendar)
        XCTAssertEqual(log.first?.meta?.title, "Design review")
        XCTAssertEqual(log.first?.meta?.calendarEventId, "e1")
    }

    func testCallStartedWithNoMatchingEventStartsAsDetected() async throws {
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session)
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "xyz"))
        let log = await session.log
        XCTAssertEqual(log.first?.meta?.source, .detected)
        XCTAssertEqual(log.first?.meta?.detectedApp, "meet")
        XCTAssertEqual(log.first?.meta?.detectedCode, "xyz")
    }

    func testCallStartedLinksToRecentCalendarEvent() async throws {
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session)
        let match = MatchedEvent(id: "e1", title: "Team sync",
                                 startDate: now(), endDate: now().addingTimeInterval(1800),
                                 meetURL: URL(string: "https://meet.google.com/xxx-yyyy-zzz")!,
                                 calendarId: "cal-work")
        await orch.registerRecentMatchedEvent(match)
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "xxx-yyyy-zzz"))
        let log = await session.log
        XCTAssertEqual(log.first?.meta?.source, .calendar)
        XCTAssertEqual(log.first?.meta?.calendarEventId, "e1")
        XCTAssertEqual(log.first?.meta?.detectedApp, "meet")
    }

    func testSecondCalendarEventIgnoredWhileRecording() async throws {
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session)
        let m1 = MatchedEvent(id: "e1", title: "A", startDate: now(),
                              endDate: now().addingTimeInterval(1800),
                              meetURL: URL(string: "https://meet.google.com/aaa-bbbb-ccc")!,
                              calendarId: "cal-work")
        let m2 = MatchedEvent(id: "e2", title: "B", startDate: now(),
                              endDate: now().addingTimeInterval(1800),
                              meetURL: URL(string: "https://meet.google.com/ddd-eeee-fff")!,
                              calendarId: "cal-work")
        try await orch.onCalendarEvent(m1)
        try await orch.onCalendarEvent(m2)
        let log = await session.log
        XCTAssertEqual(log.filter { $0.op == .start }.count, 1)
    }

    func testCallEndedForTrackedAppStops() async throws {
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session)
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "M"))
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .ended, code: "M"))
        let log = await session.log
        XCTAssertEqual(log.map { $0.op }, [.start, .stop])
    }

    func testCallEndedForOtherAppIgnored() async throws {
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session)
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "M"))
        try await orch.onCallEvent(CallEvent(app: .slackHuddle, kind: .ended, code: "OTHER"))
        let log = await session.log
        XCTAssertEqual(log.map { $0.op }, [.start])
    }

    func testDetectionLinksToCurrentCalendarRecording() async throws {
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session)
        let match = MatchedEvent(id: "e1", title: "T", startDate: now(),
                                 endDate: now().addingTimeInterval(1800),
                                 meetURL: URL(string: "https://meet.google.com/aaa-bbbb-ccc")!,
                                 calendarId: "cal-work")
        try await orch.onCalendarEvent(match)
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "aaa-bbbb-ccc"))
        let log = await session.log
        XCTAssertEqual(log.count, 2)
        XCTAssertEqual(log[1].op, .patch)
        XCTAssertEqual(log[1].meta?.detectedApp, "meet")
        XCTAssertEqual(log[1].meta?.detectedCode, "aaa-bbbb-ccc")
    }

    func testLateCalendarEventRetroLinksDetectedRecording() async throws {
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session)
        // Joined the Meet early: detection fires before any calendar match.
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "xxx-yyyy-zzz"))
        let match = MatchedEvent(id: "e1", title: "Elliot/Yvan",
                                 startDate: now().addingTimeInterval(240),
                                 endDate: now().addingTimeInterval(2040),
                                 meetURL: URL(string: "https://meet.google.com/xxx-yyyy-zzz")!,
                                 calendarId: "cal-work")
        try await orch.onCalendarEvent(match)
        let log = await session.log
        XCTAssertEqual(log.map { $0.op }, [.start, .patch])
        XCTAssertEqual(log[1].meta?.source, .calendar)
        XCTAssertEqual(log[1].meta?.title, "Elliot/Yvan")
        XCTAssertEqual(log[1].meta?.calendarEventId, "e1")
        // The in-memory state must carry the patched meta too, or the next
        // transition would resurrect the anonymous .detected version.
        guard case .recording(_, let meta) = await orch.state else {
            return XCTFail("expected .recording")
        }
        XCTAssertEqual(meta.source, .calendar)
        XCTAssertEqual(meta.title, "Elliot/Yvan")
    }

    func testLateCalendarEventForOtherCodeDoesNotRetroLink() async throws {
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session)
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "xxx-yyyy-zzz"))
        let match = MatchedEvent(id: "e1", title: "Autre réunion",
                                 startDate: now(), endDate: now().addingTimeInterval(1800),
                                 meetURL: URL(string: "https://meet.google.com/ddd-eeee-fff")!,
                                 calendarId: "cal-work")
        try await orch.onCalendarEvent(match)
        let log = await session.log
        XCTAssertEqual(log.map { $0.op }, [.start])
        guard case .recording(_, let meta) = await orch.state else {
            return XCTFail("expected .recording")
        }
        XCTAssertEqual(meta.source, .detected)
        XCTAssertNil(meta.title)
    }

    func testManualStopWorksFromRecording() async throws {
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session)
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "M"))
        try await orch.manualStop()
        let log = await session.log
        XCTAssertEqual(log.map { $0.op }, [.start, .stop])
    }

    func testOptOutWithinCancelWindowCallsCancel() async throws {
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session, cancelWindowSeconds: 999)
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "M"))
        try await orch.optOut()
        let log = await session.log
        XCTAssertEqual(log.map { $0.op }, [.start, .cancel])
    }

    func testCalendarAutoStopDeferredWhileDetectedCallStillActive() async throws {
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session,
                                           autoStopGraceSeconds: 0.05,
                                           overrunPollSeconds: 0.05)
        let match = MatchedEvent(id: "e1", title: "Overrun",
                                 startDate: now(), endDate: now().addingTimeInterval(0.05),
                                 meetURL: URL(string: "https://meet.google.com/aaa-bbbb-ccc")!,
                                 calendarId: "cal-work")
        try await orch.onCalendarEvent(match)
        // The Meet is joined and linked to the ongoing recording
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "aaa-bbbb-ccc"))
        // Wait well past endDate + grace: auto-stop must NOT fire while the call is live
        try await Task.sleep(nanoseconds: 400_000_000)
        var log = await session.log
        XCTAssertFalse(log.contains { $0.op == .stop },
                       "recording stopped at calendar end while the call was still active")
        // The call actually ends → recording stops
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .ended, code: "aaa-bbbb-ccc"))
        // Give the deferred auto-stop loop a chance to double-stop (it must not)
        try await Task.sleep(nanoseconds: 200_000_000)
        log = await session.log
        XCTAssertEqual(log.filter { $0.op == .stop }.count, 1)
    }

    func testCalendarAutoStopFiresWhenNoCallDetected() async throws {
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session,
                                           autoStopGraceSeconds: 0.05,
                                           overrunPollSeconds: 0.05)
        let match = MatchedEvent(id: "e1", title: "No call",
                                 startDate: now(), endDate: now().addingTimeInterval(0.05),
                                 meetURL: URL(string: "https://meet.google.com/aaa-bbbb-ccc")!,
                                 calendarId: "cal-work")
        try await orch.onCalendarEvent(match)
        try await Task.sleep(nanoseconds: 400_000_000)
        let log = await session.log
        XCTAssertEqual(log.map { $0.op }, [.start, .stop])
    }

    func testCalendarAutoStopFiresAfterLinkedCallEndedEarly() async throws {
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session,
                                           autoStopGraceSeconds: 0.15,
                                           overrunPollSeconds: 0.05)
        let match = MatchedEvent(id: "e1", title: "Ended early",
                                 startDate: now(), endDate: now().addingTimeInterval(0.0),
                                 meetURL: URL(string: "https://meet.google.com/aaa-bbbb-ccc")!,
                                 calendarId: "cal-work")
        try await orch.onCalendarEvent(match)
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "aaa-bbbb-ccc"))
        // Call ends (and stops the recording) before the auto-stop timer fires
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .ended, code: "aaa-bbbb-ccc"))
        try await Task.sleep(nanoseconds: 400_000_000)
        let log = await session.log
        XCTAssertEqual(log.filter { $0.op == .stop }.count, 1)
    }

    // MARK: - Resync of still-active calls on return to idle (incident 2026-08-07)

    func testEndedResyncsToOtherStillActiveCall() async throws {
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session)
        // Recording call A; B starts while recording (its .started is consumed
        // without starting anything, and the detector never re-emits it).
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "aaa"))
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "bbb"))
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .ended, code: "aaa"))
        let log = await session.log
        XCTAssertEqual(log.map { $0.op }, [.start, .stop, .start])
        XCTAssertEqual(log[0].meta?.detectedCode, "aaa")
        XCTAssertEqual(log[2].meta?.detectedCode, "bbb")
        XCTAssertEqual(log[2].meta?.source, .detected)
        guard case .recording(_, let meta) = await orch.state else {
            return XCTFail("expected .recording after resync")
        }
        XCTAssertEqual(meta.detectedCode, "bbb")
    }

    func testEndedWithNoOtherActiveCallStaysIdle() async throws {
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session)
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "aaa"))
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .ended, code: "aaa"))
        let log = await session.log
        XCTAssertEqual(log.map { $0.op }, [.start, .stop])
        let state = await orch.state
        XCTAssertEqual(state, .idle)
    }

    func testManualStopDoesNotResyncToActiveCall() async throws {
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session)
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "aaa"))
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "bbb"))
        // The user explicitly stopped: auto-restarting would fight them.
        try await orch.manualStop()
        let log = await session.log
        XCTAssertEqual(log.map { $0.op }, [.start, .stop])
        let state = await orch.state
        XCTAssertEqual(state, .idle)
    }

    func testResyncLinksToRecentCalendarEvent() async throws {
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session)
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "aaa"))
        let match = MatchedEvent(id: "e-next", title: "Next meeting",
                                 startDate: now(), endDate: now().addingTimeInterval(1800),
                                 meetURL: URL(string: "https://meet.google.com/bbb")!,
                                 calendarId: "cal-work")
        await orch.registerRecentMatchedEvent(match)
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "bbb"))
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .ended, code: "aaa"))
        let log = await session.log
        XCTAssertEqual(log.map { $0.op }, [.start, .stop, .start])
        XCTAssertEqual(log[2].meta?.source, .calendar)
        XCTAssertEqual(log[2].meta?.calendarEventId, "e-next")
        XCTAssertEqual(log[2].meta?.title, "Next meeting")
        XCTAssertEqual(log[2].meta?.detectedCode, "bbb")
    }

    func testCalendarAutoStopResyncsToStillActiveCall() async throws {
        let session = FakeSession()
        // Gate session.start so a call deterministically appears while the calendar
        // recording is still .starting — it lands in activeCalls but is never linked
        // to the recording, so the calendar auto-stop fires and must resync it.
        await session.holdNextStart()
        let orch = AutoTriggerOrchestrator(session: session,
                                           autoStopGraceSeconds: 0.05,
                                           overrunPollSeconds: 0.05)
        let match = MatchedEvent(id: "e1", title: "Standup",
                                 startDate: now(), endDate: now().addingTimeInterval(0.2),
                                 meetURL: URL(string: "https://meet.google.com/aaa")!,
                                 calendarId: "cal-work")
        let calTask = Task { try await orch.onCalendarEvent(match) }
        await waitUntilStartParked(session)
        // Arrives during .starting: recorded in activeCalls, otherwise ignored.
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "bbb"))
        await session.releaseStart()
        try await calTask.value
        // Wait past endDate + grace for the auto-stop timer to fire and resync.
        try await Task.sleep(nanoseconds: 500_000_000)
        let log = await session.log
        XCTAssertEqual(log.map { $0.op }, [.start, .stop, .start])
        XCTAssertEqual(log[0].meta?.source, .calendar)
        XCTAssertEqual(log[2].meta?.source, .detected)
        XCTAssertEqual(log[2].meta?.detectedCode, "bbb")
    }

    func testResyncStillRunsWhenStopThrows() async throws {
        struct StopBoom: Error {}
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session)
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "aaa"))
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "bbb"))
        await session.setStopError(StopBoom())
        // stop() throwing must not skip the resync — B would otherwise never
        // be recorded (its .started is never re-emitted).
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .ended, code: "aaa"))
        let log = await session.log
        XCTAssertEqual(log.map { $0.op }, [.start, .start])
        XCTAssertEqual(log[1].meta?.detectedCode, "bbb")
        guard case .recording(_, let meta) = await orch.state else {
            return XCTFail("expected .recording after resync despite stop error")
        }
        XCTAssertEqual(meta.detectedCode, "bbb")
    }

    func testCallEndedDuringStartingStopsAfterStartCompletes() async throws {
        let session = FakeSession()
        await session.holdNextStart()
        let orch = AutoTriggerOrchestrator(session: session)
        let startTask = Task {
            try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "aaa"))
        }
        await waitUntilStartParked(session)
        // .ended lands during .starting: dropped by the transitional arm, but it
        // removes A from activeCalls — the post-start recheck must stop.
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .ended, code: "aaa"))
        await session.releaseStart()
        try await startTask.value
        let log = await session.log
        XCTAssertEqual(log.map { $0.op }, [.start, .stop])
        let state = await orch.state
        XCTAssertEqual(state, .idle)
    }

    func testOptOutOutsideCancelWindowActsAsStop() async throws {
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session, cancelWindowSeconds: 0)
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "M"))
        try await Task.sleep(nanoseconds: 20_000_000)
        try await orch.optOut()
        let log = await session.log
        XCTAssertEqual(log.map { $0.op }, [.start, .stop])
    }
}
