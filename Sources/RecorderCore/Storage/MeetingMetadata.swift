import Foundation

public struct MeetingMetadata: Codable, Equatable {
    public enum Source: String, Codable, Equatable, Sendable {
        case manual, calendar, huddle, detected
    }

    public struct Models: Codable, Equatable {
        public var whisper: String
        public var diarization: String
        public init(whisper: String, diarization: String) {
            self.whisper = whisper; self.diarization = diarization
        }
    }

    public var id: String
    public var startedAt: Date
    public var endedAt: Date?
    public var durationSeconds: Int?
    public var title: String?
    public var source: Source
    public var appVersion: String
    public var models: Models
    // Chantier 2 additions for auto-trigger + calendar linkage:
    public var calendarEventId: String?
    public var detectedApp: String?
    public var detectedCode: String?

    public init(id: String, startedAt: Date, endedAt: Date? = nil, durationSeconds: Int? = nil,
                title: String? = nil, source: Source = .manual, appVersion: String, models: Models,
                calendarEventId: String? = nil, detectedApp: String? = nil, detectedCode: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.title = title
        self.source = source
        self.appVersion = appVersion
        self.models = models
        self.calendarEventId = calendarEventId
        self.detectedApp = detectedApp
        self.detectedCode = detectedCode
    }

    private enum CodingKeys: String, CodingKey {
        case id, startedAt, endedAt, durationSeconds, title, source, appVersion, models,
             calendarEventId, detectedApp, detectedCode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        durationSeconds = try c.decodeIfPresent(Int.self, forKey: .durationSeconds)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .manual
        appVersion = try c.decode(String.self, forKey: .appVersion)
        models = try c.decode(Models.self, forKey: .models)
        // Chantier 2 fields default to nil if not present (backwards compatibility)
        calendarEventId = try c.decodeIfPresent(String.self, forKey: .calendarEventId)
        detectedApp = try c.decodeIfPresent(String.self, forKey: .detectedApp)
        detectedCode = try c.decodeIfPresent(String.self, forKey: .detectedCode)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(endedAt, forKey: .endedAt)
        try c.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(source, forKey: .source)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encode(models, forKey: .models)
        try c.encodeIfPresent(calendarEventId, forKey: .calendarEventId)
        try c.encodeIfPresent(detectedApp, forKey: .detectedApp)
        try c.encodeIfPresent(detectedCode, forKey: .detectedCode)
    }
}
