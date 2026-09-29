import Foundation

public struct MeetingMetadata: Codable, Equatable {
    public enum Source: String, Codable, Equatable, Sendable {
        case manual, calendar, detected
    }

    public struct Models: Codable, Equatable {
        public var whisper: String
        public var diarization: String
        public init(whisper: String, diarization: String) {
            self.whisper = whisper; self.diarization = diarization
        }
    }

    /// One audio+transcript segment of a manually merged meeting (see
    /// `mergedParts`). Part 0 is the carrier meeting itself, at offset 0.
    ///
    /// `offsetSeconds` and `durationSeconds` are frozen at merge time and are
    /// the single source of truth afterwards: the transcript was shifted by
    /// exactly this offset, and the player inserts this part's audio at exactly
    /// this offset. Recomputing either on the fly would let the two drift apart
    /// and desynchronise the playhead from the text.
    public struct MergedPart: Codable, Equatable, Sendable {
        public let slug: String
        /// Position of this part on the merged timeline. Parts are butted
        /// end-to-end (no silence between them), so this is the sum of the
        /// preceding parts' `durationSeconds`.
        public let offsetSeconds: Double
        /// Length of this part's slot on the timeline — its measured audio
        /// length, falling back to its recorded duration when it has no
        /// playable audio.
        public let durationSeconds: Double
        /// The part's real recording start, kept so the UI can still tell the
        /// user *when* this stretch was actually recorded even though the
        /// merged timeline no longer reflects wall-clock time.
        public let startedAt: Date
        public let title: String?

        public init(slug: String, offsetSeconds: Double, durationSeconds: Double,
                    startedAt: Date, title: String?) {
            self.slug = slug
            self.offsetSeconds = offsetSeconds
            self.durationSeconds = durationSeconds
            self.startedAt = startedAt
            self.title = title
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
    /// Slug of the meeting this one continues — set at recording start when the
    /// call being detected is the same one an *interrupted* recording (crash,
    /// app restart mid-meeting) was already capturing. The pipeline's absorb
    /// step merges this segment's transcript into that meeting and regenerates
    /// its notes.
    public var continuationOf: String?
    /// True once this segment's transcript has been merged into
    /// `continuationOf`'s meeting. An absorbed meeting is hidden everywhere:
    /// dropped from the index and skipped by the sidebar's on-disk fold-in.
    public var absorbed: Bool?
    /// True when `title` was produced by Claude during note generation rather
    /// than typed by the user or copied from a calendar event. It is what lets
    /// a later regeneration refresh an auto title while never touching one the
    /// user wrote — renaming by hand must reset it to false.
    public var titleAutoDetected: Bool?
    /// Ordered parts of a manually merged meeting, part 0 being this meeting
    /// itself. `nil` (or fewer than two entries) for an ordinary meeting.
    ///
    /// Distinct from `continuationOf`/`absorbed`, which is the *automatic*
    /// crash-recovery merge: that one is decided at recording time and keeps
    /// real wall-clock offsets, this one is decided by the user afterwards on
    /// meetings that have nothing in common but their order.
    public var mergedParts: [MergedPart]?
    /// Slug of the meeting this one was manually merged into. Set together with
    /// `absorbed = true`, which is what actually hides it from the index and
    /// the sidebar — reusing that flag rather than adding a second hiding rule.
    public var mergedInto: String?

    /// Whether the next synthèse generation should ask Claude for a title.
    ///
    /// - Calendar meetings: never — the event title is authoritative, no debate.
    /// - Detected (huddle) / manual (sauvage): yes while the title is still
    ///   empty or still the one Claude produced last time. A user-edited title
    ///   (`titleAutoDetected == false` with content) is theirs and stays.
    public var wantsTitleDetection: Bool {
        guard source != .calendar else { return false }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty || titleAutoDetected == true
    }

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
             calendarEventId, detectedApp, detectedCode, titleAutoDetected,
             continuationOf, absorbed, mergedParts, mergedInto
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
        titleAutoDetected = try c.decodeIfPresent(Bool.self, forKey: .titleAutoDetected)
        continuationOf = try c.decodeIfPresent(String.self, forKey: .continuationOf)
        absorbed = try c.decodeIfPresent(Bool.self, forKey: .absorbed)
        mergedParts = try c.decodeIfPresent([MergedPart].self, forKey: .mergedParts)
        mergedInto = try c.decodeIfPresent(String.self, forKey: .mergedInto)
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
        try c.encodeIfPresent(titleAutoDetected, forKey: .titleAutoDetected)
        try c.encodeIfPresent(continuationOf, forKey: .continuationOf)
        try c.encodeIfPresent(absorbed, forKey: .absorbed)
        try c.encodeIfPresent(mergedParts, forKey: .mergedParts)
        try c.encodeIfPresent(mergedInto, forKey: .mergedInto)
    }
}
