import Foundation
import EventKit

public final class CalendarWatcher {
    private let store: EKEventStore
    private let horizonMinutes: TimeInterval
    private let pollSeconds: TimeInterval

    public init(store: EKEventStore = EKEventStore(),
                horizonMinutes: TimeInterval = 15,
                pollSeconds: TimeInterval = 60) {
        self.store = store
        self.horizonMinutes = horizonMinutes
        self.pollSeconds = pollSeconds
    }

    /// Requests full access to events. Returns true if granted.
    public func requestAccess() async -> Bool {
        do {
            if #available(macOS 14.0, *) {
                return try await store.requestFullAccessToEvents()
            } else {
                return try await withCheckedThrowingContinuation { cont in
                    store.requestAccess(to: .event) { granted, error in
                        if let error { cont.resume(throwing: error) }
                        else { cont.resume(returning: granted) }
                    }
                }
            }
        } catch {
            return false
        }
    }

    public func matches(matcher: CalendarMatcher) -> AsyncStream<MatchedEvent> {
        AsyncStream { continuation in
            let task = Task.detached { [horizonMinutes, pollSeconds, store] in
                // key → endDate timestamp (for purge logic)
                var armed = [String: Int]()
                while !Task.isCancelled {
                    let now = Date()
                    let horizon = now.addingTimeInterval(horizonMinutes * 60)
                    let predicate = store.predicateForEvents(withStart: now,
                                                             end: horizon,
                                                             calendars: nil)
                    let events = store.events(matching: predicate)
                    for ekEvent in events {
                        guard let id = ekEvent.eventIdentifier else { continue }
                        let key = "\(id)|\(Int(ekEvent.startDate.timeIntervalSince1970))"
                        if armed[key] != nil { continue }
                        // Lead-time guard: don't fire more than 60s before start
                        let leadTime = ekEvent.startDate.timeIntervalSinceNow
                        guard leadTime <= 60 else { continue }
                        let input = CalendarEventInput(
                            id: id,
                            title: ekEvent.title ?? "",
                            calendarId: ekEvent.calendar.calendarIdentifier,
                            attendeeCount: (ekEvent.attendees?.count ?? 0) + 1,
                            notes: ekEvent.notes,
                            location: ekEvent.location,
                            startDate: ekEvent.startDate,
                            endDate: ekEvent.endDate,
                            isAllDay: ekEvent.isAllDay
                        )
                        if let matched = matcher.match(input) {
                            continuation.yield(matched)
                            armed[key] = Int(ekEvent.endDate.timeIntervalSince1970)
                        }
                    }
                    // Purge entries where endDate + 300s has passed
                    let cutoff = Int(Date().addingTimeInterval(-300).timeIntervalSince1970)
                    armed = armed.filter { _, endTs in endTs >= cutoff }
                    try? await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func availableCalendars() -> [EKCalendar] {
        store.calendars(for: .event)
    }
}
