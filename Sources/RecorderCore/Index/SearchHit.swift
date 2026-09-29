import Foundation

public struct SearchHit: Equatable, Sendable {
    public let meetingId: String
    public let title: String?
    public let startedAt: Date
    public let speaker: String
    public let snippet: AttributedString
    public let approximateTimestamp: TimeInterval?

    public init(meetingId: String, title: String?, startedAt: Date,
                speaker: String, snippet: AttributedString,
                approximateTimestamp: TimeInterval?) {
        self.meetingId = meetingId
        self.title = title
        self.startedAt = startedAt
        self.speaker = speaker
        self.snippet = snippet
        self.approximateTimestamp = approximateTimestamp
    }
}
