import XCTest
@testable import RecorderCore

final class JobStateTests: XCTestCase {
    func testFreshJobHasAllPendingSteps() {
        let job = JobState.fresh()
        XCTAssertEqual(job.state, .recording)
        for step in JobStep.allCases {
            XCTAssertEqual(job.steps[step]?.status, .pending)
        }
    }

    func testMarkDoneUpdatesStep() {
        var job = JobState.fresh()
        job.markStarted(.normalize, at: Date(timeIntervalSince1970: 1))
        job.markDone(.normalize, at: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(job.steps[.normalize]?.status, .done)
        XCTAssertEqual(job.steps[.normalize]?.startedAt?.timeIntervalSince1970, 1)
        XCTAssertEqual(job.steps[.normalize]?.completedAt?.timeIntervalSince1970, 2)
    }

    func testIsResumableWhenNotTerminal() {
        var job = JobState.fresh()
        job.state = .transcribing
        XCTAssertTrue(job.isResumable)
        job.state = .done; XCTAssertFalse(job.isResumable)
    }

    func testIsResumableForFailedJobDependsOnRetryBudget() {
        var job = JobState.fresh()
        job.state = .failed
        job.retryCount = 0
        XCTAssertTrue(job.isResumable, "failed with retries left must be resumable")
        job.retryCount = JobState.maxRetries - 1
        XCTAssertTrue(job.isResumable)
        job.retryCount = JobState.maxRetries
        XCTAssertFalse(job.isResumable, "failed with exhausted retries must be left alone")
        job.retryCount = JobState.maxRetries + 1
        XCTAssertFalse(job.isResumable)
        // Retry budget must not resurrect a completed job.
        job.state = .done
        job.retryCount = 0
        XCTAssertFalse(job.isResumable)
    }

    func testOldJobJsonWithoutRetryCountDecodesWithZero() throws {
        // job.json written before retry accounting existed.
        let json = """
        {"state":"failed","error":"boom",
        "steps":{"whisper_mic":{"status":"failed","error":"boom"}}}
        """.data(using: .utf8)!
        let job = try AtomicJSON.decoder.decode(JobState.self, from: json)
        XCTAssertEqual(job.retryCount, 0)
        XCTAssertTrue(job.isResumable, "old failed jobs get the full retry budget")
    }

    func testRetryCountRoundTripsThroughCodable() throws {
        var job = JobState.fresh()
        job.state = .failed
        job.retryCount = 1
        let data = try JSONEncoder().encode(job)
        let decoded = try AtomicJSON.decoder.decode(JobState.self, from: data)
        XCTAssertEqual(decoded.retryCount, 1)
    }

    func testPrepareRetryResetsFailedStepsAndConsumesRetry() {
        var job = JobState.fresh()
        job.markDone(.normalize)
        job.markFailed(.whisperMic, error: "ANE timeout")
        XCTAssertEqual(job.state, .failed)

        job.prepareRetry()
        XCTAssertEqual(job.retryCount, 1)
        XCTAssertEqual(job.stepStatus(.whisperMic), .pending)
        XCTAssertNil(job.steps[.whisperMic]?.error)
        XCTAssertEqual(job.stepStatus(.normalize), .done, "done steps stay done")
        XCTAssertNil(job.error)
        // The state must leave .failed in the same mutation: a crash after
        // the prepared retry is persisted resumes for free instead of
        // consuming another retry.
        XCTAssertEqual(job.state, .transcribing,
                       "state maps to the first not-yet-done step")
        XCTAssertTrue(job.isResumable)

        // Idempotent: a second prepareRetry sees a non-failed state.
        job.prepareRetry()
        XCTAssertEqual(job.retryCount, 1, "must not double-consume the budget")
    }

    func testPrepareRetryIsNoOpUnlessFailed() {
        var job = JobState.fresh()
        job.state = .transcribing
        job.prepareRetry()
        XCTAssertEqual(job.retryCount, 0)
    }

    func testUnknownStepInJobJsonIsIgnoredNotFatal() throws {
        // job.json written by a future version of the app with an unknown step.
        let json = """
        {"state":"done","steps":{"normalize":{"status":"done"},
        "step_from_the_future":{"status":"done"}}}
        """.data(using: .utf8)!
        let job = try AtomicJSON.decoder.decode(JobState.self, from: json)
        XCTAssertEqual(job.state, .done)
        XCTAssertEqual(job.stepStatus(.normalize), .done)
        // Known steps absent are backfilled as .pending.
        XCTAssertEqual(job.stepStatus(.notes), .pending)
    }
}
