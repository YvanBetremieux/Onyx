import Foundation

public protocol RecordingSession: Sendable {
    func start(meta: MeetingMetadata) async throws
    func stop() async throws
    func cancel() async throws
    func patchMeta(_ mut: @Sendable (inout MeetingMetadata) -> Void) async throws
}

public actor AutoTriggerOrchestrator {
    public enum State: Equatable {
        case idle
        case recording(startedAt: Date, meta: MeetingMetadata)
    }

    private let session: any RecordingSession
    private let cancelWindowSeconds: TimeInterval
    private let matchLinkWindowSeconds: TimeInterval

    private var recentMatchedByMeetCode: [String: (event: MatchedEvent, at: Date)] = [:]

    public private(set) var state: State = .idle

    public init(session: any RecordingSession,
                cancelWindowSeconds: TimeInterval = 30,
                matchLinkWindowSeconds: TimeInterval = 300) {
        self.session = session
        self.cancelWindowSeconds = cancelWindowSeconds
        self.matchLinkWindowSeconds = matchLinkWindowSeconds
    }

    // MARK: - Entry points

    public func onCalendarEvent(_ match: MatchedEvent) async throws {
        registerRecentMatchedEvent(match)
        switch state {
        case .idle:
            let now = Date()
            let meta = MeetingMetadata(
                id: Self.slug(for: now),
                startedAt: now,
                title: match.title,
                source: .calendar,
                appVersion: "0.2.0",
                models: .init(whisper: "large-v3", diarization: "sherpa-pyannote-3.1"),
                calendarEventId: match.id
            )
            try await session.start(meta: meta)
            state = .recording(startedAt: now, meta: meta)
        case .recording:
            // Ignore; already recording.
            break
        }
    }

    public func onCallEvent(_ ev: CallEvent) async throws {
        switch (state, ev.kind) {
        case (.idle, .started):
            let now = Date()
            let meta: MeetingMetadata
            let code = ev.code
            if let linked = recentMatchedByMeetCode[code],
               abs(now.timeIntervalSince(linked.at)) <= matchLinkWindowSeconds {
                meta = MeetingMetadata(
                    id: Self.slug(for: now),
                    startedAt: now,
                    title: linked.event.title,
                    source: .calendar,
                    appVersion: "0.2.0",
                    models: .init(whisper: "large-v3", diarization: "sherpa-pyannote-3.1"),
                    calendarEventId: linked.event.id,
                    detectedApp: ev.app.rawValue,
                    detectedCode: ev.code
                )
            } else {
                meta = MeetingMetadata(
                    id: Self.slug(for: now),
                    startedAt: now,
                    source: .detected,
                    appVersion: "0.2.0",
                    models: .init(whisper: "large-v3", diarization: "sherpa-pyannote-3.1"),
                    detectedApp: ev.app.rawValue,
                    detectedCode: ev.code
                )
            }
            try await session.start(meta: meta)
            state = .recording(startedAt: now, meta: meta)

        case (.recording(let startedAt, var meta), .started):
            if meta.detectedApp == nil {
                let app = ev.app.rawValue
                let code = ev.code
                meta.detectedApp = app
                meta.detectedCode = code
                try await session.patchMeta { m in
                    m.detectedApp = app
                    m.detectedCode = code
                }
                state = .recording(startedAt: startedAt, meta: meta)
            }
            // else: already have a detection linked, ignore.

        case (.recording(_, let meta), .ended):
            if meta.detectedApp == ev.app.rawValue,
               meta.detectedCode == ev.code {
                try await session.stop()
                state = .idle
            }

        case (.idle, .ended):
            return
        }
    }

    public func manualStart() async throws {
        guard case .idle = state else { return }
        let now = Date()
        let meta = MeetingMetadata(
            id: Self.slug(for: now),
            startedAt: now,
            source: .manual,
            appVersion: "0.2.0",
            models: .init(whisper: "large-v3", diarization: "sherpa-pyannote-3.1")
        )
        try await session.start(meta: meta)
        state = .recording(startedAt: now, meta: meta)
    }

    public func manualStop() async throws {
        guard case .recording = state else { return }
        try await session.stop()
        state = .idle
    }

    public func optOut() async throws {
        guard case .recording(let startedAt, _) = state else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed <= cancelWindowSeconds {
            try await session.cancel()
        } else {
            try await session.stop()
        }
        state = .idle
    }

    public func registerRecentMatchedEvent(_ match: MatchedEvent) {
        let code = match.meetURL.lastPathComponent
        recentMatchedByMeetCode[code] = (match, Date())
        let cutoff = Date().addingTimeInterval(-matchLinkWindowSeconds)
        recentMatchedByMeetCode = recentMatchedByMeetCode.filter { $0.value.at >= cutoff }
    }

    // MARK: - Helpers

    private static func slug(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd_HH'h'mm"
        return fmt.string(from: date)
    }
}
