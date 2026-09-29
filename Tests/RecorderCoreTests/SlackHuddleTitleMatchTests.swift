import XCTest
@testable import RecorderCore

final class SlackHuddleTitleMatchTests: XCTestCase {
    func testEnglishHuddleTitleMatches() {
        XCTAssertTrue(SlackHuddleDetector.isHuddleTitle("Huddle: #general - Acme - Slack"))
        XCTAssertTrue(SlackHuddleDetector.isHuddleTitle("huddle in #general"))
    }

    // Real title observed on a French-localized Slack during a live huddle
    // (2026-08-03) — the bug that motivated this matcher: no "Huddle" anywhere.
    func testFrenchHuddleTitleMatches() {
        XCTAssertTrue(SlackHuddleDetector.isHuddleTitle(
            "Appel d’équipe : @Ambre Clemente - papernest - Slack 🎤"))
        // Straight apostrophe variant.
        XCTAssertTrue(SlackHuddleDetector.isHuddleTitle("Appel d'équipe : @Someone - X - Slack"))
        // Case-insensitive.
        XCTAssertTrue(SlackHuddleDetector.isHuddleTitle("appel d’équipe : @x - y - Slack"))
    }

    // Locale-independent fallback: Slack suffixes the active-call window's
    // title with 🎤, after the trailing "Slack".
    func testMicSuffixMatchesRegardlessOfLocale() {
        XCTAssertTrue(SlackHuddleDetector.isHuddleTitle("Gruppen-Call: @Jemand - Acme - Slack 🎤"))
    }

    func testOrdinaryWindowsDoNotMatch() {
        XCTAssertFalse(SlackHuddleDetector.isHuddleTitle(
            "t_support_providers (canal) - papernest - Slack"))
        XCTAssertFalse(SlackHuddleDetector.isHuddleTitle(
            "Ambre Clemente (message direct) - papernest - Slack [principal] 🏠🔊"))
        // A channel merely named with a mic emoji: 🎤 is not the title's suffix.
        XCTAssertFalse(SlackHuddleDetector.isHuddleTitle("karaoke-🎤 (canal) - papernest - Slack"))
        XCTAssertFalse(SlackHuddleDetector.isHuddleTitle(""))
    }
}
