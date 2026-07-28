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
                var active = Set<String>()
                while !Task.isCancelled {
                    let current = Self.currentHuddleWindowIDs(slackBundle: slackBundle)
                    for c in current.subtracting(active) { continuation.yield(.started(code: c)) }
                    for c in active.subtracting(current) { continuation.yield(.ended(code: c)) }
                    active = current
                    try? await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func currentHuddleWindowIDs(slackBundle: String) -> Set<String> {
        let slackRunning = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == slackBundle }
        guard slackRunning else { return [] }

        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        var codes = Set<String>()
        for w in windows {
            guard let owner = w[kCGWindowOwnerName as String] as? String,
                  owner == "Slack" else { continue }
            guard let title = w[kCGWindowName as String] as? String else { continue }
            if title.range(of: "Huddle", options: .caseInsensitive) != nil {
                if let id = w[kCGWindowNumber as String] as? Int {
                    codes.insert(String(id))
                }
            }
        }
        return codes
    }
}
