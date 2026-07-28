import Foundation
import UserNotifications
import RecorderCore

@MainActor
public final class OptOutNotificationCenter: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    public static let shared = OptOutNotificationCenter()
    private let stopActionId = "onyx.optout.stop"
    private let categoryId = "onyx.recording.optout"

    /// Provider closure resolved lazily so the orchestrator can be injected
    /// once at app startup.
    public var optOutHandler: (@Sendable () async -> Void)?

    private var configured = false

    public func configureIfNeeded() {
        guard !configured else { return }
        let stop = UNNotificationAction(identifier: stopActionId,
                                        title: "Stop",
                                        options: [.destructive])
        let cat = UNNotificationCategory(identifier: categoryId,
                                         actions: [stop],
                                         intentIdentifiers: [],
                                         options: [])
        UNUserNotificationCenter.current().setNotificationCategories([cat])
        UNUserNotificationCenter.current().delegate = self
        Task { await requestAuthorizationIfNeeded() }
        configured = true
    }

    public func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    public func showRecordingStarted(title: String, subtitle: String? = nil) {
        configureIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "Recording — \(title)"
        if let subtitle { content.subtitle = subtitle }
        content.body = "Click Stop to cancel or end early."
        content.categoryIdentifier = categoryId
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content,
                                        trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    public func showIgnored(title: String) {
        let content = UNMutableNotificationContent()
        content.title = "Event ignored"
        content.body = "\(title) — already recording."
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    public func showNotesFailed(slug: String) {
        let content = UNMutableNotificationContent()
        content.title = "Notes generation failed"
        content.body = "\(slug) — retry from menu."
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - UNUserNotificationCenterDelegate

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == stopActionId, let handler = optOutHandler {
            Task { await handler(); completionHandler() }
        } else {
            completionHandler()
        }
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler:
                                       @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
