import Foundation

public enum JobStep: String, CaseIterable, Codable {
    case normalize, whisperMic = "whisper_mic", whisperSystem = "whisper_system",
         diarize, merge, render, cleanup, notes, absorb
}

public enum JobStepStatus: String, Codable {
    case pending, inProgress = "in_progress", done, failed
}

public enum JobOverallState: String, Codable {
    case recording, normalizing, transcribing, diarizing, merging, rendering, cleanup, generatingNotes, done, failed
}

public struct JobStepRecord: Codable, Equatable {
    public var status: JobStepStatus
    public var startedAt: Date?
    public var completedAt: Date?
    public var error: String?
    public init(status: JobStepStatus = .pending, startedAt: Date? = nil,
                completedAt: Date? = nil, error: String? = nil) {
        self.status = status; self.startedAt = startedAt
        self.completedAt = completedAt; self.error = error
    }
}

public struct JobState: Codable, Equatable {
    public var state: JobOverallState
    public var steps: [JobStep: JobStepRecord]
    public var error: String?
    /// Number of automatic retries already consumed by failed runs. A job
    /// that failed transiently (e.g. CoreML/ANE timeout under system load)
    /// stays resumable until `maxRetries` is exhausted.
    public var retryCount: Int

    /// Max automatic retries of a `.failed` job before it is left alone.
    public static let maxRetries = 2

    public init(state: JobOverallState, steps: [JobStep: JobStepRecord],
                error: String? = nil, retryCount: Int = 0) {
        self.state = state; self.steps = steps; self.error = error
        self.retryCount = retryCount
    }

    public static func fresh() -> JobState {
        var s = [JobStep: JobStepRecord]()
        for step in JobStep.allCases { s[step] = JobStepRecord() }
        return JobState(state: .recording, steps: s)
    }

    public var isResumable: Bool {
        guard state != .done else { return false }
        if state == .failed { return retryCount < Self.maxRetries }
        return true
    }
    public func stepStatus(_ step: JobStep) -> JobStepStatus { steps[step]?.status ?? .pending }

    public mutating func markStarted(_ step: JobStep, at date: Date = Date()) {
        var rec = steps[step] ?? JobStepRecord()
        rec.status = .inProgress; rec.startedAt = date; rec.error = nil
        steps[step] = rec
    }

    public mutating func markDone(_ step: JobStep, at date: Date = Date()) {
        var rec = steps[step] ?? JobStepRecord()
        rec.status = .done; rec.completedAt = date; rec.error = nil
        steps[step] = rec
    }

    public mutating func markFailed(_ step: JobStep, error: String, at date: Date = Date()) {
        var rec = steps[step] ?? JobStepRecord()
        rec.status = .failed; rec.completedAt = date; rec.error = error
        steps[step] = rec
        state = .failed
        self.error = error
    }

    /// Prepares a `.failed` job for another automatic run: consumes one
    /// retry, resets every failed step to `.pending` (clearing its error)
    /// and clears the job-level error. `.done` steps are untouched — the
    /// normal resume path skips them. No-op unless `state == .failed`.
    ///
    /// The overall state leaves `.failed` in the SAME mutation (it becomes
    /// the progress state of the first not-yet-done step): once the retry
    /// is prepared and persisted, a quit/crash before the run makes any
    /// progress (e.g. parked behind the recording gate for a whole meeting)
    /// resumes through the normal free resume path instead of consuming
    /// another retry. This also makes the call idempotent — a second
    /// `prepareRetry` sees a non-failed state and is a no-op.
    public mutating func prepareRetry() {
        guard state == .failed else { return }
        retryCount += 1
        for (step, var rec) in steps where rec.status == .failed {
            rec.status = .pending
            rec.error = nil
            steps[step] = rec
        }
        error = nil
        let firstPending = JobStep.allCases.first { steps[$0]?.status != .done }
        state = firstPending.map(Self.overallState(for:)) ?? .recording
    }

    /// The overall progress state a run would report while executing `step`.
    private static func overallState(for step: JobStep) -> JobOverallState {
        switch step {
        case .normalize: return .normalizing
        case .whisperMic, .whisperSystem: return .transcribing
        case .diarize: return .diarizing
        case .merge: return .merging
        case .render: return .rendering
        case .cleanup: return .cleanup
        case .notes, .absorb: return .generatingNotes
        }
    }

    private enum CodingKeys: String, CodingKey { case state, steps, error, retryCount }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(JobOverallState.self, forKey: .state)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        // Backward compat: job.json written before retry accounting existed.
        retryCount = try c.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
        let raw = try c.decode([String: JobStepRecord].self, forKey: .steps)
        var out = [JobStep: JobStepRecord]()
        for (k, v) in raw {
            guard let step = JobStep(rawValue: k) else { continue }
            out[step] = v
        }
        for step in JobStep.allCases where out[step] == nil { out[step] = JobStepRecord() }
        steps = out
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encode(retryCount, forKey: .retryCount)
        let raw = Dictionary(uniqueKeysWithValues: steps.map { ($0.key.rawValue, $0.value) })
        try c.encode(raw, forKey: .steps)
    }
}
