import Foundation

/// Turns raw per-poll call-presence snapshots into debounced lifecycle events.
///
/// `.started` fires on the first successful poll that sees a code; `.ended`
/// only fires once the code has been absent — across *successful* polls — for
/// at least `endedGraceSeconds`. Detection sources are inherently flappy: the
/// Slack huddle window title flickers empty during redraws, and the Meet JXA
/// probe times out under CPU load. A single missed poll used to end a live
/// recording on the spot (2026-08-05: a 37-minute huddle fragmented into 7
/// segments this way), and a consecutive-miss counter was still fooled by
/// probe *failures*: under heavy transcription load the osascript probes
/// timed out repeatedly, each timeout looked like "no call open", and 4 such
/// failures in a row fired false `.ended` events that chopped a continuous
/// 1-hour meeting into 5 fragments with unrecorded gaps (2026-08-06). Hence:
///
/// - A poll that *failed* (probe timed out, osascript killed or nonzero exit)
///   is passed in as `nil` — it carries no information, so it neither counts
///   toward absence nor resets it.
/// - Absence is measured in wall-clock time between successful polls, not in
///   poll counts, so a slow/backed-up polling loop can't shrink the grace.
///
/// The grace is per source (2026-09-30): a single 60 s grace for everyone let
/// ~70 s of post-call audio into recordings (a dictation right after a Meet, the
/// next huddle merged into the previous one). Meet uses 0 — a *successful*
/// probe no longer seeing the tab means it was closed or left the call URL —
/// and Slack a few seconds against its title flicker. A grace of 0 ends on the
/// first successful absent poll.
struct CallDebouncer {
    /// How a tracked code stood as of the last *successful* poll.
    private enum Presence {
        case seen
        /// First successful poll that no longer saw the code.
        case absent(since: Date)
    }

    private let endedGraceSeconds: TimeInterval
    /// Injected clock so tests can drive the grace window deterministically.
    /// Wall-clock trade-off: a sleep-wake or NTP forward jump can make the
    /// grace appear elapsed early, but `.ended` still requires a *successful*
    /// absent poll at that moment, which caps the damage.
    private let now: () -> Date
    private var calls: [String: Presence] = [:]

    init(endedGraceSeconds: TimeInterval = 60, now: @escaping () -> Date = Date.init) {
        self.endedGraceSeconds = endedGraceSeconds
        self.now = now
    }

    /// Feed one poll snapshot. `nil` means the probe failed (unknown state):
    /// no events are emitted and no absence clock starts or resets.
    mutating func observe(_ current: Set<String>?) -> [CallLifecycle] {
        guard let current else { return [] }
        var events: [CallLifecycle] = []
        let t = now()
        for code in current where calls[code] == nil {
            events.append(.started(code: code))
        }
        for code in current { calls[code] = .seen }
        for (code, presence) in calls where !current.contains(code) {
            switch presence {
            case .seen where endedGraceSeconds <= 0:
                calls[code] = nil
                events.append(.ended(code: code))
            case .seen:
                calls[code] = .absent(since: t)
            case .absent(let since):
                if t.timeIntervalSince(since) >= endedGraceSeconds {
                    calls[code] = nil
                    events.append(.ended(code: code))
                }
            }
        }
        return events
    }
}
