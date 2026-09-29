import XCTest
@testable import RecorderCore

/// A single missed poll (Slack window title flicker, JXA timeout under CPU
/// load) must not end a live recording. Observed 2026-08-05: a 37-minute
/// huddle fragmented into 7 segments because every title flicker emitted an
/// immediate .ended. Observed 2026-08-06: under heavy transcription load the
/// JXA probes timed out repeatedly, each failure was counted as absence, and
/// a continuous 1-hour meeting was chopped into 5 fragments. Hence the two
/// behaviors under test here: a failed probe (`nil` poll) carries no
/// information at all, and .ended requires >= `endedGraceSeconds` of genuine
/// absence measured in wall-clock time across successful polls.
final class CallDebouncerTests: XCTestCase {

    /// Manually-driven clock injected as the debouncer's `now`.
    private final class ManualClock {
        private var now = Date(timeIntervalSinceReferenceDate: 0)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
        func read() -> Date { now }
    }

    private func makeDebouncer(grace: TimeInterval = 60)
        -> (debouncer: CallDebouncer, advance: (TimeInterval) -> Void) {
        let clock = ManualClock()
        return (CallDebouncer(endedGraceSeconds: grace, now: clock.read),
                clock.advance)
    }

    func test_started_firesImmediately_andSteadyStateIsSilent() {
        var (d, _) = makeDebouncer()
        XCTAssertEqual(d.observe(["huddle"]), [.started(code: "huddle")])
        XCTAssertEqual(d.observe(["huddle"]), [], "steady state is silent")
    }

    func test_probeFailures_neverEnd_evenAfterMany() {
        var (d, advance) = makeDebouncer(grace: 60)
        _ = d.observe(["abc-defg-hij"])
        for _ in 0..<100 { // 100 failed polls spanning far beyond the grace
            advance(5)
            XCTAssertEqual(d.observe(nil), [], "a failed probe is no information")
        }
        advance(5)
        XCTAssertEqual(d.observe(["abc-defg-hij"]), [],
                       "call was live all along — no restart, no end")
    }

    func test_ended_firesOnlyAfterGraceOfGenuineAbsence() {
        var (d, advance) = makeDebouncer(grace: 60)
        _ = d.observe(["huddle"])
        advance(5)
        XCTAssertEqual(d.observe([]), [], "first absent poll starts the clock")
        advance(30)
        XCTAssertEqual(d.observe([]), [], "35 s absent < 60 s grace")
        advance(20)
        XCTAssertEqual(d.observe([]), [], "55 s absent < 60 s grace")
        advance(10)
        XCTAssertEqual(d.observe([]), [.ended(code: "huddle")], "65 s absent >= grace")
        XCTAssertEqual(d.observe([]), [], "already ended, stays silent")
        XCTAssertEqual(d.observe(["huddle"]), [.started(code: "huddle")],
                       "a real new call after a real end starts again")
    }

    func test_sighting_resetsAbsenceWindow() {
        var (d, advance) = makeDebouncer(grace: 60)
        _ = d.observe(["huddle"])
        advance(5)
        _ = d.observe([])
        advance(50)
        XCTAssertEqual(d.observe(["huddle"]), [],
                       "reappearance resets — no spurious restart")
        advance(55)
        XCTAssertEqual(d.observe([]), [], "absence clock restarted from the sighting")
        advance(65)
        XCTAssertEqual(d.observe([]), [.ended(code: "huddle")])
    }

    func test_started_firesOnFirstSightingAfterUnknownPolls() {
        var (d, advance) = makeDebouncer()
        XCTAssertEqual(d.observe(nil), [])
        advance(5)
        XCTAssertEqual(d.observe(nil), [])
        advance(5)
        XCTAssertEqual(d.observe(["abc-defg-hij"]), [.started(code: "abc-defg-hij")],
                       "a successful sighting fires immediately, unknowns notwithstanding")
    }

    func test_mixedUnknownAndAbsent_doesNotShortcutGrace() {
        var (d, advance) = makeDebouncer(grace: 60)
        _ = d.observe(["huddle"])
        advance(5)
        XCTAssertEqual(d.observe([]), [], "genuine absence at t=5 starts the clock")
        // Unknown polls while time passes: they neither confirm absence nor
        // reset the clock — but ended still needs a *successful* absent poll
        // past the grace to fire.
        advance(20)
        XCTAssertEqual(d.observe(nil), [])
        advance(20)
        XCTAssertEqual(d.observe(nil), [])
        advance(10)
        XCTAssertEqual(d.observe([]), [], "55 s since absence started — still inside grace")
        advance(3)
        XCTAssertEqual(d.observe(nil), [], "58 s, unknown: no event even near the edge")
        advance(7)
        XCTAssertEqual(d.observe([]), [.ended(code: "huddle")],
                       "65 s of absence, confirmed by a successful poll")
    }

    func test_independentCodes_trackedSeparately() {
        var (d, advance) = makeDebouncer(grace: 60)
        _ = d.observe(["a", "b"])
        advance(5)
        XCTAssertEqual(d.observe(["a"]), [])
        advance(65)
        XCTAssertEqual(d.observe(["a"]), [.ended(code: "b")])
    }
}
