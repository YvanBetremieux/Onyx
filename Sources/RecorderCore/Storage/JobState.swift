import Foundation

public enum JobStep: String, CaseIterable, Codable {
    case normalize, whisperMic = "whisper_mic", whisperSystem = "whisper_system",
         diarize, merge, render, cleanup, notes
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

    public init(state: JobOverallState, steps: [JobStep: JobStepRecord], error: String? = nil) {
        self.state = state; self.steps = steps; self.error = error
    }

    public static func fresh() -> JobState {
        var s = [JobStep: JobStepRecord]()
        for step in JobStep.allCases { s[step] = JobStepRecord() }
        return JobState(state: .recording, steps: s)
    }

    public var isResumable: Bool { state != .done && state != .failed }
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

    private enum CodingKeys: String, CodingKey { case state, steps, error }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(JobOverallState.self, forKey: .state)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        let raw = try c.decode([String: JobStepRecord].self, forKey: .steps)
        var out = [JobStep: JobStepRecord]()
        for (k, v) in raw {
            guard let step = JobStep(rawValue: k) else {
                throw DecodingError.dataCorruptedError(forKey: .steps, in: c,
                    debugDescription: "unknown step \(k)")
            }
            out[step] = v
        }
        for step in JobStep.allCases where out[step] == nil { out[step] = JobStepRecord() }
        steps = out
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(error, forKey: .error)
        let raw = Dictionary(uniqueKeysWithValues: steps.map { ($0.key.rawValue, $0.value) })
        try c.encode(raw, forKey: .steps)
    }
}
