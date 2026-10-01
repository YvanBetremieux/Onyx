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

    // Plus de repli « titre qui finit par 🎤 » : Slack 4.52 l'ajoute
    // brièvement au titre de la fenêtre PRINCIPALE au moment où l'on raccroche
    // (observé le 2026-09-30 à 17:52:23), ce qui démarrait un enregistrement
    // juste après l'appel au lieu de pendant.
    func testMicSuffixAloneNoLongerMatches() {
        XCTAssertFalse(SlackHuddleDetector.isHuddleTitle(
            "Paul Brochard (message direct) - papernest - 2 nouveaux éléments - Slack 🎤"))
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
