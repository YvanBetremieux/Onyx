import XCTest
@testable import RecorderCore

final class CalendarMatchRulesTests: XCTestCase {
    private func input(title: String = "Team sync",
                       calendarId: String = "cal-work",
                       attendeeCount: Int = 2,
                       notes: String? = nil,
                       location: String? = nil,
                       start: Date = .init(timeIntervalSince1970: 1_700_000_000),
                       end: Date = .init(timeIntervalSince1970: 1_700_003_600),
                       id: String = "e-1") -> CalendarEventInput {
        CalendarEventInput(id: id, title: title, calendarId: calendarId,
                           attendeeCount: attendeeCount, notes: notes,
                           location: location, startDate: start, endDate: end)
    }

    func testMatchesEventInWhitelistWithMeetLinkInNotes() {
        let m = CalendarMatcher(whitelistedCalendarIds: ["cal-work"])
        let ev = input(notes: "Join at https://meet.google.com/abc-defg-hij")
        let matched = m.match(ev)
        XCTAssertNotNil(matched)
        XCTAssertEqual(matched?.meetURL.absoluteString,
                       "https://meet.google.com/abc-defg-hij")
    }

    func testRejectsEventFromOtherCalendar() {
        let m = CalendarMatcher(whitelistedCalendarIds: ["cal-work"])
        let ev = input(calendarId: "cal-perso",
                       notes: "https://meet.google.com/aaa-bbbb-ccc")
        XCTAssertNil(m.match(ev))
    }

    func testRejectsEventWithNoOtherAttendees() {
        let m = CalendarMatcher(whitelistedCalendarIds: ["cal-work"])
        let ev = input(attendeeCount: 1,
                       notes: "https://meet.google.com/aaa-bbbb-ccc")
        XCTAssertNil(m.match(ev))
    }

    func testRejectsEventTaggedNoRec() {
        let m = CalendarMatcher(whitelistedCalendarIds: ["cal-work"])
        let ev = input(title: "Standup [no-rec]",
                       notes: "https://meet.google.com/aaa-bbbb-ccc")
        XCTAssertNil(m.match(ev))
    }

    func testRejectsEventWithoutMeetLink() {
        let m = CalendarMatcher(whitelistedCalendarIds: ["cal-work"])
        let ev = input(notes: "Zoom link: https://zoom.us/j/12345")
        XCTAssertNil(m.match(ev))
    }

    func testAcceptsMeetLinkInLocationField() {
        let m = CalendarMatcher(whitelistedCalendarIds: ["cal-work"])
        let ev = input(location: "meet.google.com/qrs-tuvw-xyz")
        XCTAssertNotNil(m.match(ev))
    }

    func testCaseInsensitiveNoRecMarker() {
        let m = CalendarMatcher(whitelistedCalendarIds: ["cal-work"])
        let ev = input(title: "Standup [NO-REC]",
                       notes: "https://meet.google.com/aaa-bbbb-ccc")
        XCTAssertNil(m.match(ev))
    }
}
