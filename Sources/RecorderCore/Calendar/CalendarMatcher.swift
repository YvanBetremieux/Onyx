import Foundation

public struct CalendarMatcher: Sendable {
    public let whitelistedCalendarIds: Set<String>

    public init(whitelistedCalendarIds: [String]) {
        self.whitelistedCalendarIds = Set(whitelistedCalendarIds)
    }

    private static let meetRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"meet\.google\.com/([a-z]{3}-[a-z]{4}-[a-z]{3})"#,
            options: [.caseInsensitive])
    }()

    public func match(_ ev: CalendarEventInput) -> MatchedEvent? {
        guard whitelistedCalendarIds.contains(ev.calendarId) else { return nil }
        guard ev.attendeeCount > 1 else { return nil }
        if ev.title.range(of: "[no-rec]", options: .caseInsensitive) != nil { return nil }

        let haystack = (ev.notes ?? "") + " " + (ev.location ?? "")
        let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
        guard let m = Self.meetRegex.firstMatch(in: haystack, range: range),
              let codeRange = Range(m.range(at: 1), in: haystack)
        else { return nil }
        let code = String(haystack[codeRange])
        guard let url = URL(string: "https://meet.google.com/\(code)") else { return nil }

        return MatchedEvent(id: ev.id, title: ev.title,
                            startDate: ev.startDate, endDate: ev.endDate,
                            meetURL: url, calendarId: ev.calendarId)
    }
}
