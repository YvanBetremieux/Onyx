import XCTest
import RecorderCore
@testable import Onyx

final class MeetingGroupsTests: XCTestCase {
    private func listing(_ id: String, _ date: Date) -> MeetingListing {
        MeetingListing(id: id, startedAt: date, title: id,
                       folderPath: URL(fileURLWithPath: "/tmp/\(id)"),
                       transcriptState: "done")
    }

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        return c
    }

    func test_todayYesterdayThisWeekMonthsSplit() {
        // Reference "now" = 2026-07-31 15:00 Europe/Paris.
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 31,
                                                hour: 15, minute: 0))!
        let today   = cal.date(byAdding: .hour, value: -2, to: now)!
        let yester  = cal.date(byAdding: .day,  value: -1, to: now)!
        let thisWk  = cal.date(byAdding: .day,  value: -4, to: now)!
        let julEarly = cal.date(from: DateComponents(year: 2026, month: 7, day: 5))!
        let june    = cal.date(from: DateComponents(year: 2026, month: 6, day: 12))!

        let all = [
            listing("today", today), listing("yester", yester),
            listing("thisWk", thisWk), listing("julEarly", julEarly),
            listing("june", june),
        ]
        let groups = MeetingGroups.group(all, now: now, calendar: cal)
        // Expect at least these headers in this order.
        let titles = groups.map(\.title)
        XCTAssertTrue(titles.contains("Aujourd'hui"))
        XCTAssertTrue(titles.contains("Hier"))
        XCTAssertTrue(titles.contains("Cette semaine"))
        XCTAssertTrue(titles.contains("Juillet 2026"))
        XCTAssertTrue(titles.contains("Juin 2026"))

        let today0 = groups.first { $0.title == "Aujourd'hui" }!
        XCTAssertEqual(today0.items.map(\.id), ["today"])
        let yest = groups.first { $0.title == "Hier" }!
        XCTAssertEqual(yest.items.map(\.id), ["yester"])
    }

    /// The month header must be rendered in the *calendar's* time zone, not the
    /// system one. Asserting a single hardcoded zone would pass vacuously on a
    /// machine whose system zone happens to be that zone, so this feeds the
    /// exact same instant through two calendars in zones 19 hours apart,
    /// straddling a month boundary, and asserts both the concrete headers and
    /// that they differ. At most one of the two can coincide with the system
    /// zone, so the assertion can never be vacuous.
    func test_monthHeaderUsesCalendarTimeZone() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var honolulu = Calendar(identifier: .gregorian)
        honolulu.timeZone = TimeZone(identifier: "Pacific/Honolulu")!

        // 2026-08-01 00:30 +09:00 == 2026-07-31 15:30 UTC == 2026-07-31 05:30 -10:00
        let instant = tokyo.date(from: DateComponents(year: 2026, month: 8, day: 1,
                                                     hour: 0, minute: 30))!
        let now = tokyo.date(from: DateComponents(year: 2026, month: 9, day: 15,
                                                 hour: 12, minute: 0))!

        let tokyoTitles = MeetingGroups.group([listing("x", instant)],
                                              now: now, calendar: tokyo).map(\.title)
        let honoluluTitles = MeetingGroups.group([listing("x", instant)],
                                                 now: now, calendar: honolulu).map(\.title)

        XCTAssertEqual(tokyoTitles, ["Août 2026"])
        XCTAssertEqual(honoluluTitles, ["Juillet 2026"])
        XCTAssertNotEqual(tokyoTitles, honoluluTitles,
                          "the same instant must bucket by the calendar's zone")
    }

    /// A meeting recorded just after midnight is "Aujourd'hui", and one just
    /// before it is "Hier" — in the calendar's time zone.
    func test_dayBoundary() {
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 31,
                                                hour: 9, minute: 0))!
        let justAfterMidnight = cal.date(from: DateComponents(year: 2026, month: 7, day: 31,
                                                             hour: 0, minute: 1))!
        let justBeforeMidnight = cal.date(from: DateComponents(year: 2026, month: 7, day: 30,
                                                              hour: 23, minute: 59))!
        let groups = MeetingGroups.group(
            [listing("after", justAfterMidnight), listing("before", justBeforeMidnight)],
            now: now, calendar: cal)
        XCTAssertEqual(groups.map(\.title), ["Aujourd'hui", "Hier"])
        XCTAssertEqual(groups[0].items.map(\.id), ["after"])
        XCTAssertEqual(groups[1].items.map(\.id), ["before"])
    }
}
