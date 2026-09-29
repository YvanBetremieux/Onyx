import Foundation
import AppKit
import CoreGraphics

public final class SlackHuddleDetector: MeetingAppDetector {
    public let app: MeetingApp = .slackHuddle

    private let pollSeconds: TimeInterval
    private let slackBundle = "com.tinyspeck.slackmacgap"

    public init(pollSeconds: TimeInterval = 5) {
        self.pollSeconds = pollSeconds
    }

    public func events() -> AsyncStream<CallLifecycle> {
        AsyncStream { continuation in
            let task = Task.detached { [pollSeconds, slackBundle] in
                // `.notice` (not .info): notice is persisted by the unified log,
                // so a missed detection can be diagnosed after the fact with
                // `log show` instead of having had a live `log stream` running.
                Log.recorder.notice(
                    "SlackHuddleDetector: polling started (screenRecording=\(CGPreflightScreenCaptureAccess()))")
                var debouncer = CallDebouncer()
                while !Task.isCancelled {
                    let current = Self.currentHuddleWindowIDs(slackBundle: slackBundle)
                    for ev in debouncer.observe(current) { continuation.yield(ev) }
                    try? await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Last diagnostic summary logged, to log only on change. Only touched
    /// from the single polling task, so unsynchronized access is fine.
    private static var lastLoggedSummary: String?
    /// Same single-task-only access pattern for the nil-title warning.
    private static var lastLoggedNilTitleCount = 0

    /// Current huddle codes, or `nil` if the probe itself failed (the
    /// CGWindowList API returned nothing) — "unknown", not "no huddle", so a
    /// failed probe can't count toward the debouncer's absence grace.
    /// Slack not running is a genuine, successful empty probe.
    static func currentHuddleWindowIDs(slackBundle: String) -> Set<String>? {
        let slackRunning = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == slackBundle }
        guard slackRunning else { return [] }

        // NOT `.optionOnScreenOnly`: a minimized huddle window (or one on
        // another Space / behind a fullscreen app) drops out of the on-screen
        // list, which ended a recording 3 minutes into a live call the moment
        // the user minimized the little call window (observed 2026-08-03).
        // Scanning all windows keeps it visible to the detector; Slack closes
        // the window for real on hang-up, which is what ends the recording.
        let opts: CGWindowListOption = [.excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        var found = false
        var titles: [String] = []
        var nilTitleCount = 0
        for w in windows {
            guard let owner = w[kCGWindowOwnerName as String] as? String,
                  owner == "Slack" else { continue }
            // kCGWindowName may be nil if Screen Recording permission is missing.
            guard let title = w[kCGWindowName as String] as? String else {
                nilTitleCount += 1
                continue
            }
            titles.append(title)
            if Self.isHuddleTitle(title) {
                found = true
            }
        }
        // Nil-title warning only on change, same discipline as the summary
        // notice below — one warning per window per 5 s poll would flood the
        // persisted unified log for as long as the permission is missing.
        if nilTitleCount != lastLoggedNilTitleCount {
            lastLoggedNilTitleCount = nilTitleCount
            if nilTitleCount > 0 {
                Log.recorder.warning(
                    "SlackHuddleDetector: kCGWindowName is nil for \(nilTitleCount) Slack window(s) — Screen Recording permission may be missing")
            }
        }
        // Slack windows exist but every title is unreadable (Screen Recording
        // permission revoked mid-call): we can't tell whether a huddle is
        // live, so this is a failed probe — "unknown", not "no huddle".
        if titles.isEmpty && nilTitleCount > 0 { return nil }
        // Diagnostic: what the detector actually sees, to explain a missed
        // huddle after the fact (title wording, permission, off-screen window).
        // Only on change — at one poll per 5 s an unconditional notice would
        // flood the persisted unified log.
        let summary = "huddle=\(found): \(titles.joined(separator: " | "))"
        if summary != lastLoggedSummary {
            lastLoggedSummary = summary
            Log.recorder.notice(
                "SlackHuddleDetector: poll saw \(titles.count) Slack window(s), \(summary, privacy: .public)")
        }
        // Use a stable constant code rather than the volatile window ID.
        return found ? ["huddle"] : []
    }

    /// Whether a Slack window title belongs to an active huddle.
    ///
    /// Slack localizes the huddle window's title — "Huddle: …" in English but
    /// « Appel d’équipe : … » in French (observed live, 2026-08-03), so
    /// matching the English word alone silently missed every huddle on a
    /// French-localized Slack. Known localized names are matched first; the
    /// fallback for other locales is the 🎤 suffix Slack appends to the
    /// active-call window's title (suffix only: an emoji elsewhere in the
    /// title is just a channel name).
    static func isHuddleTitle(_ title: String) -> Bool {
        let localizedNames = ["huddle", "appel d’équipe", "appel d'équipe"]
        for name in localizedNames
        where title.range(of: name, options: .caseInsensitive) != nil {
            return true
        }
        return title.trimmingCharacters(in: .whitespaces).hasSuffix("🎤")
    }
}
