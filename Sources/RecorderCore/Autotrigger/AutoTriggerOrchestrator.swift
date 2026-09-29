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
        case starting   // Claimed — await session.start() in progress
        case recording(startedAt: Date, meta: MeetingMetadata)
        case stopping   // await session.stop() or session.cancel() in progress
    }

    private let session: any RecordingSession
    private let cancelWindowSeconds: TimeInterval
    private let matchLinkWindowSeconds: TimeInterval
    private let autoStopGraceSeconds: TimeInterval
    private let overrunPollSeconds: TimeInterval

    private var recentMatchedByMeetCode: [String: (event: MatchedEvent, at: Date)] = [:]

    /// Live calls as seen by detection, keyed "app:lowercased-code". Updated on every
    /// CallEvent regardless of state, so the calendar auto-stop can tell whether the
    /// meeting is overrunning its scheduled end, and so the resync-on-idle path can
    /// reconstruct a `.started` for a call whose event was consumed while recording
    /// (the value keeps the original CallEvent, incl. the un-lowercased code).
    private var activeCalls: [String: CallEvent] = [:]

    public private(set) var state: State = .idle {
        didSet { onTransition?(state) }
    }

    /// Called on every state transition. Set once at wiring time (e.g. from AppState).
    public var onTransition: (@Sendable (_ newState: State) -> Void)?

    public func setTransitionHandler(_ h: @escaping @Sendable (_ newState: State) -> Void) {
        onTransition = h
    }

    public init(session: any RecordingSession,
                cancelWindowSeconds: TimeInterval = 30,
                matchLinkWindowSeconds: TimeInterval = 300,
                autoStopGraceSeconds: TimeInterval = 60,
                overrunPollSeconds: TimeInterval = 60) {
        self.session = session
        self.cancelWindowSeconds = cancelWindowSeconds
        self.matchLinkWindowSeconds = matchLinkWindowSeconds
        self.autoStopGraceSeconds = autoStopGraceSeconds
        self.overrunPollSeconds = overrunPollSeconds
    }

    // MARK: - Entry points

    public func onCalendarEvent(_ match: MatchedEvent) async throws {
        Log.recorder.info(
            "orchestrator.onCalendarEvent: title=\(match.title, privacy: .public), state=\(Self.describe(self.state), privacy: .public)")
        registerRecentMatchedEvent(match)
        guard case .idle = state else {
            // Retro-link: joining the Meet more than ~60s before its scheduled
            // start means detection fires first (CalendarWatcher only emits a
            // match ≤60s before startDate), so the recording began as
            // `.detected` with no title. When the calendar match for the very
            // call being recorded finally arrives, adopt it — event title,
            // `.calendar` source, event-end auto-stop — as if it had fired first.
            try await retroLinkCalendarEvent(match)
            return
        }
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
        // C1 fix: claim the actor with .starting BEFORE the suspension
        state = .starting
        do {
            try await session.start(meta: meta)
        } catch {
            state = .idle
            throw error
        }
        state = .recording(startedAt: now, meta: meta)
        Log.recorder.info(
            "orchestrator: → .recording (calendar) slug=\(meta.id, privacy: .public)")

        // H4 fix: schedule auto-stop at event end + grace period
        scheduleCalendarAutoStop(match: match, slug: meta.id)
    }

    private func scheduleCalendarAutoStop(match: MatchedEvent, slug: String) {
        let stopDelay = match.endDate.addingTimeInterval(autoStopGraceSeconds).timeIntervalSinceNow
        guard stopDelay > 0 else { return }
        Task { [weak self, overrunPollSeconds] in
            try? await Task.sleep(nanoseconds: UInt64(stopDelay * 1_000_000_000))
            // Overrun handling: if a detected call linked to this recording is still
            // live past the scheduled end, keep recording and re-check periodically.
            // The detection `.ended` path stops the recording as soon as the call
            // actually finishes; this loop is the fallback if it fires first.
            while let self {
                if await self.attemptCalendarAutoStop(slug: slug) { return }
                try? await Task.sleep(nanoseconds: UInt64(overrunPollSeconds * 1_000_000_000))
            }
        }
    }

    /// Attaches a late-arriving calendar match to the in-progress recording it
    /// belongs to, identified by meet code. No-op unless the recording is
    /// `.detected` (a calendar- or manual-sourced recording keeps its identity)
    /// and the codes agree. A title the user already typed by hand
    /// (`titleAutoDetected == false`, non-empty) is theirs and is preserved.
    private func retroLinkCalendarEvent(_ match: MatchedEvent) async throws {
        guard case .recording(_, let meta) = state,
              meta.source == .detected,
              meta.calendarEventId == nil,
              let code = meta.detectedCode?.lowercased(),
              code == match.meetURL.lastPathComponent.lowercased()
        else {
            Log.recorder.info("orchestrator.onCalendarEvent: ignored (not retro-linkable)")
            return
        }
        let slug = meta.id
        let userEditedTitle = meta.titleAutoDetected == false
            && !(meta.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        try await session.patchMeta { m in
            m.source = .calendar
            m.calendarEventId = match.id
            if !userEditedTitle {
                m.title = match.title
                m.titleAutoDetected = nil
            }
        }
        // Re-read the state: the call may have ended during the await above,
        // and resurrecting a finished recording here would corrupt the machine.
        guard case .recording(let startedAt, var current) = state, current.id == slug else {
            return
        }
        current.source = .calendar
        current.calendarEventId = match.id
        if !userEditedTitle {
            current.title = match.title
            current.titleAutoDetected = nil
        }
        state = .recording(startedAt: startedAt, meta: current)
        scheduleCalendarAutoStop(match: match, slug: slug)
        Log.recorder.info(
            "orchestrator: retro-linked calendar event \(match.id, privacy: .public) to recording slug=\(slug, privacy: .public)")
    }

    /// Returns true when the auto-stop task is done (stopped, or the recording is no
    /// longer the one it was scheduled for); false when the linked call is still live
    /// and the caller should re-check later.
    private func attemptCalendarAutoStop(slug: String) async -> Bool {
        guard case .recording(_, let meta) = state, meta.id == slug else { return true }
        if let app = meta.detectedApp,
           let detectedCode = meta.detectedCode?.lowercased(),
           activeCalls["\(app):\(detectedCode)"] != nil {
            Log.recorder.info(
                "orchestrator: calendar end passed but call still active, deferring auto-stop slug=\(slug, privacy: .public)")
            return false
        }
        Log.recorder.info(
            "orchestrator: auto-stop calendar recording slug=\(slug, privacy: .public)")
        try? await manualStop()
        // Resync fix (incident 2026-08-07): the auto-stop is machine-initiated, not a
        // user decision, so a call still live at this point deserves its own recording.
        try? await resyncStillActiveCall()
        return true
    }

    public func onCallEvent(_ ev: CallEvent) async throws {
        Log.recorder.info(
            "orchestrator.onCallEvent: app=\(ev.app.rawValue, privacy: .public), kind=\(String(describing: ev.kind), privacy: .public), state=\(Self.describe(self.state), privacy: .public)")
        // Step 6: normalize meet code to lowercase for all comparisons
        let code = ev.code.lowercased()
        switch ev.kind {
        case .started: activeCalls["\(ev.app.rawValue):\(code)"] = ev
        case .ended: activeCalls.removeValue(forKey: "\(ev.app.rawValue):\(code)")
        }
        switch (state, ev.kind) {
        case (.idle, .started):
            try await startDetectedRecording(app: ev.app, code: ev.code)

        case (.recording(let startedAt, var meta), .started):
            if meta.detectedApp == nil {
                let app = ev.app.rawValue
                meta.detectedApp = app
                meta.detectedCode = ev.code
                try await session.patchMeta { m in
                    m.detectedApp = app
                    m.detectedCode = ev.code
                }
                state = .recording(startedAt: startedAt, meta: meta)
                Log.recorder.info(
                    "orchestrator: patched detection into ongoing recording slug=\(meta.id, privacy: .public)")
            }
            // else: already have a detection linked, ignore.

        case (.recording(_, let meta), .ended):
            if meta.detectedApp == ev.app.rawValue,
               meta.detectedCode?.lowercased() == code {
                // Resync fix (incident 2026-08-07): the user joined the next Meet
                // seconds before the previous call's debounced `.ended` arrived. Its
                // `.started` was consumed while `.recording` (only patched metadata)
                // and the detector never re-emits `.started` for a continuously
                // visible call — so without the resync inside, a call still live in
                // `activeCalls` would never be recorded.
                try await stopThenResync(slug: meta.id)
            } else {
                Log.recorder.info(
                    "orchestrator.onCallEvent .ended: mismatch with current meta.detectedCode; ignored")
            }

        case (.idle, .ended):
            return

        // Transitional states: ignore concurrent events gracefully
        case (.starting, _), (.stopping, _):
            Log.recorder.info(
                "orchestrator.onCallEvent: ignored (transitional state \(Self.describe(self.state), privacy: .public))")
        }
    }

    /// Starts a `.detected` recording for `app`/`code`, linking it to a recent
    /// calendar match when one exists for the same meet code. Shared by the
    /// `(.idle, .started)` branch of `onCallEvent` and the resync-on-idle path.
    private func startDetectedRecording(app: MeetingApp, code: String) async throws {
        // Normal guarded path: a resync caller may race another trigger across
        // its own suspension points, so re-assert idleness here.
        guard case .idle = state else {
            Log.recorder.info("orchestrator.startDetectedRecording: ignored (not idle)")
            return
        }
        let now = Date()
        let meta: MeetingMetadata
        if let linked = recentMatchedByMeetCode[code.lowercased()],
           abs(now.timeIntervalSince(linked.at)) <= matchLinkWindowSeconds {
            meta = MeetingMetadata(
                id: Self.slug(for: now),
                startedAt: now,
                title: linked.event.title,
                source: .calendar,
                appVersion: "0.2.0",
                models: .init(whisper: "large-v3", diarization: "sherpa-pyannote-3.1"),
                calendarEventId: linked.event.id,
                detectedApp: app.rawValue,
                detectedCode: code
            )
        } else {
            meta = MeetingMetadata(
                id: Self.slug(for: now),
                startedAt: now,
                source: .detected,
                appVersion: "0.2.0",
                models: .init(whisper: "large-v3", diarization: "sherpa-pyannote-3.1"),
                detectedApp: app.rawValue,
                detectedCode: code
            )
        }
        // C1 fix: claim with .starting BEFORE the suspension
        state = .starting
        do {
            try await session.start(meta: meta)
        } catch {
            state = .idle
            throw error
        }
        state = .recording(startedAt: now, meta: meta)
        // Post-start recheck: this call's `.ended` may have arrived during the
        // `.starting` suspension above and been dropped by the transitional arm of
        // `onCallEvent` — the detector never re-emits it, so without this the
        // recording would run forever. Stop through the normal path (which also
        // resyncs any other call still live).
        if activeCalls["\(app.rawValue):\(code.lowercased())"] == nil {
            Log.recorder.info(
                "orchestrator: call \(app.rawValue, privacy: .public):\(code, privacy: .public) ended during .starting — stopping slug=\(meta.id, privacy: .public)")
            try await stopThenResync(slug: meta.id)
        }
    }

    /// Detection-driven stop: `.stopping` → `session.stop()` → `.idle`, then resync
    /// any other still-active call. A `stop()` failure is logged, not propagated:
    /// letting it skip the resync would recreate the 2026-08-07 incident through
    /// the error path (the still-live call's `.started` never re-fires).
    private func stopThenResync(slug: String) async throws {
        state = .stopping
        do {
            // C3 fix: defer so .idle is always restored even if stop() throws
            // (scoped in a `do` so the resync below runs after .idle is set)
            defer { state = .idle }
            try await session.stop()
        } catch {
            Log.recorder.error(
                "orchestrator: stop failed for slug=\(slug, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        Log.recorder.info(
            "orchestrator: → .idle (call ended) slug=\(slug, privacy: .public)")
        try await resyncStillActiveCall()
    }

    /// Resync fix (incident 2026-08-07): after a machine-initiated return to idle
    /// (detection `.ended` stop, calendar auto-stop), start recording one call that
    /// is still live in `activeCalls` — its `.started` was swallowed while a previous
    /// recording was running and will never be re-emitted by the debounced detector.
    ///
    /// Deliberately NOT called from `manualStop()`/`optOut()`: the user explicitly
    /// stopped, and auto-restarting would fight that intent. Since the detector never
    /// re-emits `.started` for a continuously-visible call, a manually-stopped call
    /// will not re-trigger recording until it disappears and reappears — intended.
    private func resyncStillActiveCall() async throws {
        // The `.ended` that triggered the stop already removed its own key from
        // `activeCalls` before we got here; whatever remains is another live call.
        guard case .idle = state,
              let key = activeCalls.keys.sorted().first,  // deterministic pick
              let ev = activeCalls[key] else { return }
        Log.recorder.info(
            "orchestrator: resync — call still active after stop, starting recording app=\(ev.app.rawValue, privacy: .public) code=\(ev.code, privacy: .public)")
        try await startDetectedRecording(app: ev.app, code: ev.code)
    }

    public func manualStart() async throws {
        Log.recorder.info(
            "orchestrator.manualStart: state=\(Self.describe(self.state), privacy: .public)")
        guard case .idle = state else {
            Log.recorder.info("orchestrator.manualStart: ignored (not idle)")
            return
        }
        let now = Date()
        let meta = MeetingMetadata(
            id: Self.slug(for: now),
            startedAt: now,
            source: .manual,
            appVersion: "0.2.0",
            models: .init(whisper: "large-v3", diarization: "sherpa-pyannote-3.1")
        )
        // C1 fix: claim with .starting BEFORE the suspension
        state = .starting
        do {
            try await session.start(meta: meta)
        } catch {
            state = .idle
            throw error
        }
        state = .recording(startedAt: now, meta: meta)
        Log.recorder.info(
            "orchestrator: → .recording (manual) slug=\(meta.id, privacy: .public)")
    }

    public func manualStop() async throws {
        Log.recorder.info(
            "orchestrator.manualStop: state=\(Self.describe(self.state), privacy: .public)")
        guard case .recording = state else {
            Log.recorder.info("orchestrator.manualStop: ignored (not recording)")
            return
        }
        // C3 fix: defer ensures we always land in .idle, even if stop() throws
        state = .stopping
        defer { state = .idle }
        try await session.stop()
        Log.recorder.info("orchestrator: → .idle (manual stop)")
    }

    public func optOut() async throws {
        Log.recorder.info(
            "orchestrator.optOut: state=\(Self.describe(self.state), privacy: .public)")
        guard case .recording(let startedAt, _) = state else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        // C3 fix: defer ensures we always land in .idle, even if cancel/stop throws
        state = .stopping
        defer { state = .idle }
        if elapsed <= cancelWindowSeconds {
            try await session.cancel()
            Log.recorder.info("orchestrator: → .idle (opt-out cancel, elapsed=\(elapsed)s)")
        } else {
            try await session.stop()
            Log.recorder.info("orchestrator: → .idle (opt-out stop, elapsed=\(elapsed)s)")
        }
    }

    public func registerRecentMatchedEvent(_ match: MatchedEvent) {
        // Step 6: store with lowercased key for case-insensitive matching
        let code = match.meetURL.lastPathComponent.lowercased()
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

    private static func describe(_ s: State) -> String {
        switch s {
        case .idle: return "idle"
        case .starting: return "starting"
        case .recording(_, let meta): return "recording(\(meta.id))"
        case .stopping: return "stopping"
        }
    }
}
