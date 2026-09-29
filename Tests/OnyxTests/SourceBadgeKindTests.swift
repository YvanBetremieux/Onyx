import XCTest
import RecorderCore
@testable import Onyx

final class SourceBadgeKindTests: XCTestCase {
    func test_manualSource_mapsToManual() {
        XCTAssertEqual(SourceBadge.Kind(source: .manual, detectedApp: nil), .manual)
    }

    func test_calendarSource_mapsToCalendar_evenIfAppWasAlsoDetected() {
        XCTAssertEqual(SourceBadge.Kind(source: .calendar, detectedApp: nil), .calendar)
        // A calendar-triggered recording can later learn its app; the badge still
        // reports the trigger origin.
        XCTAssertEqual(SourceBadge.Kind(source: .calendar, detectedApp: "meet"), .calendar)
    }

    func test_detected_meet_mapsToMeet() {
        XCTAssertEqual(SourceBadge.Kind(source: .detected,
                                        detectedApp: MeetingApp.meet.rawValue), .meet)
    }

    func test_detected_slackHuddle_mapsToHuddle() {
        XCTAssertEqual(SourceBadge.Kind(source: .detected,
                                        detectedApp: MeetingApp.slackHuddle.rawValue), .huddle)
    }

    func test_detected_withUnknownOrMissingApp_fallsBackToMeet() {
        XCTAssertEqual(SourceBadge.Kind(source: .detected, detectedApp: nil), .meet)
        XCTAssertEqual(SourceBadge.Kind(source: .detected, detectedApp: "zoom"), .meet)
    }

    func test_nilSource_mapsToUnknown() {
        XCTAssertEqual(SourceBadge.Kind(source: nil, detectedApp: nil), .unknown)
    }

    func test_labels_areTheFourDistinctBadgeStates() {
        XCTAssertEqual(SourceBadge.Kind.manual.label, "MANUAL")
        XCTAssertEqual(SourceBadge.Kind.calendar.label, "CAL")
        XCTAssertEqual(SourceBadge.Kind.meet.label, "MEET")
        XCTAssertEqual(SourceBadge.Kind.huddle.label, "HUDDLE")
        XCTAssertEqual(SourceBadge.Kind.unknown.label, "—")
    }
}
