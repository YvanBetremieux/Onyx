import Foundation

public enum MeetingApp: String, Codable, Sendable {
    case meet
    case slackHuddle = "slack_huddle"
}

public enum CallLifecycle: Sendable, Equatable {
    case started(code: String)
    case ended(code: String)
}

public struct CallEvent: Sendable, Equatable {
    public let app: MeetingApp
    public let kind: Kind
    public let code: String
    public let at: Date

    public enum Kind: Sendable, Equatable { case started, ended }

    public init(app: MeetingApp, kind: Kind, code: String, at: Date = Date()) {
        self.app = app; self.kind = kind; self.code = code; self.at = at
    }
}

public protocol MeetingAppDetector: Sendable {
    var app: MeetingApp { get }
    /// Async stream of `.started(code)` / `.ended(code)`. Must be idempotent —
    /// don't re-emit the same state without a change.
    func events() -> AsyncStream<CallLifecycle>
}
