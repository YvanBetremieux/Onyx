import Foundation
import RecorderCore

public struct MeetingGroup: Equatable {
    public let title: String
    public let items: [MeetingListing]
}

public enum MeetingGroups {
    /// Bucketizes meetings into "Aujourd'hui / Hier / Cette semaine /
    /// [Month] [Year]". Meetings must already be sorted (most-recent first).
    public static func group(_ meetings: [MeetingListing],
                             now: Date = Date(),
                             calendar: Calendar = .current) -> [MeetingGroup] {
        var buckets: [String: [MeetingListing]] = [:]
        var order: [String] = []

        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        // "Cette semaine" = from the first day of the current week (inclusive)
        // to yesterday (exclusive).
        let weekStart = calendar.date(
            from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!

        let monthFmt = DateFormatter()
        monthFmt.calendar = calendar
        monthFmt.timeZone = calendar.timeZone
        monthFmt.locale = Locale(identifier: "fr_FR")
        monthFmt.dateFormat = "LLLL yyyy"

        for m in meetings {
            let key: String
            if calendar.isDate(m.startedAt, inSameDayAs: today) {
                key = "Aujourd'hui"
            } else if calendar.isDate(m.startedAt, inSameDayAs: yesterday) {
                key = "Hier"
            } else if m.startedAt >= weekStart {
                key = "Cette semaine"
            } else {
                key = monthFmt.string(from: m.startedAt).capitalized
            }
            if buckets[key] == nil { order.append(key); buckets[key] = [] }
            buckets[key]?.append(m)
        }
        return order.map { MeetingGroup(title: $0, items: buckets[$0] ?? []) }
    }
}
