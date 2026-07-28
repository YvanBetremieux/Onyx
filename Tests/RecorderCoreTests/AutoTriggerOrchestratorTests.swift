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

        func start(meta: MeetingMetadata) async throws {
            currentMeta = meta
            log.append(.init(op: .start, meta: meta))
        }
        func stop() async throws {
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
