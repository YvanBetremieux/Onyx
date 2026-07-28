import Foundation

public struct MatchedEvent: Sendable, Equatable {
    public let id: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let meetURL: URL
    public let calendarId: String

    public init(id: String, title: String, startDate: Date, endDate: Date,
                meetURL: URL, calendarId: String) {
        self.id = id; self.title = title
        self.startDate = startDate; self.endDate = endDate
        self.meetURL = meetURL; self.calendarId = calendarId
    }
}

public struct CalendarEventInput: Sendable, Equatable {
    public let id: String
    public let title: String
    public let calendarId: String
    public let attendeeCount: Int
    public let notes: String?
    public let location: String?
    public let startDate: Date
    public let endDate: Date

    public init(id: String, title: String, calendarId: String,
                attendeeCount: Int, notes: String?, location: String?,
                startDate: Date, endDate: Date) {
        self.id = id; self.title = title; self.calendarId = calendarId
        self.attendeeCount = attendeeCount; self.notes = notes
        self.location = location; self.startDate = startDate; self.endDate = endDate
    }
}
