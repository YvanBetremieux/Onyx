import XCTest
@testable import RecorderCore

final class DetectionCoordinatorTests: XCTestCase {

    /// Fake detector that replays a scripted sequence with delays, then stays open.
    final class FakeDetector: MeetingAppDetector, @unchecked Sendable {
        let app: MeetingApp
        private let script: [(TimeInterval, CallLifecycle)]
        init(app: MeetingApp, script: [(TimeInterval, CallLifecycle)]) {
            self.app = app; self.script = script
        }
        func events() -> AsyncStream<CallLifecycle> {
            AsyncStream { continuation in
                let s = script
                Task.detached {
                    for (delay, ev) in s {
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continuation.yield(ev)
                    }
                    // Keep stream open — do not finish, to avoid tearing down coordinator early.
                }
            }
        }
    }

    func testMergesEventsFromMultipleDetectors() async throws {
        let a = FakeDetector(app: .meet, script: [(0.05, .started(code: "meetA"))])
        let b = FakeDetector(app: .slackHuddle, script: [(0.10, .started(code: "hudB"))])
        let coord = DetectionCoordinator(detectors: [a, b], debounceEndedSeconds: 3)

        var seen: [CallEvent] = []
        let listener = Task {
            for await ev in coord.events() {
                seen.append(ev)
                if seen.count == 2 { break }
            }
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        listener.cancel()
        XCTAssertEqual(seen.count, 2)
        XCTAssertTrue(seen.contains { $0.app == .meet && $0.kind == .started && $0.code == "meetA" })
        XCTAssertTrue(seen.contains { $0.app == .slackHuddle && $0.kind == .started && $0.code == "hudB" })
    }

    func testDebounceCancelsEndedIfRestartedFast() async throws {
        let d = FakeDetector(app: .meet, script: [
            (0.00, .started(code: "M1")),
            (0.10, .ended(code: "M1")),
            (0.50, .started(code: "M1")),  // flicker restart before 3s window
        ])
        let coord = DetectionCoordinator(detectors: [d], debounceEndedSeconds: 3)

        var seen: [CallEvent] = []
        let listener = Task { for await ev in coord.events() { seen.append(ev) } }
        try await Task.sleep(nanoseconds: 4_000_000_000)
        listener.cancel()

        XCTAssertEqual(seen.filter { $0.kind == .started }.count, 1)
        XCTAssertEqual(seen.filter { $0.kind == .ended }.count, 0,
                       ".ended should have been cancelled by the flicker .started")
    }

    func testDebounceLetsEndedThroughIfStable() async throws {
        let d = FakeDetector(app: .meet, script: [
            (0.00, .started(code: "M2")),
            (0.10, .ended(code: "M2")),
        ])
        let coord = DetectionCoordinator(detectors: [d], debounceEndedSeconds: 1)

        var seen: [CallEvent] = []
        let listener = Task { for await ev in coord.events() { seen.append(ev) } }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        listener.cancel()

        XCTAssertEqual(seen.filter { $0.kind == .started }.count, 1)
        XCTAssertEqual(seen.filter { $0.kind == .ended }.count, 1)
    }
}
