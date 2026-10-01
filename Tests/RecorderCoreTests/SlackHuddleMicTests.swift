import XCTest
@testable import RecorderCore

/// Détection d'un huddle par l'usage du micro (2026-10-01). Mesuré sur un vrai
/// huddle : le micro du helper Slack reste ouvert de bout en bout, muet compris,
/// et se ferme moins d'une seconde après avoir raccroché. La sortie son, elle,
/// démarre avant (sonnerie) et s'arrête ~10 s après (son de fin).
final class SlackHuddleMicTests: XCTestCase {
    private let slack = "com.tinyspeck.slackmacgap"

    private func active(_ processes: [AudioProcessUsage]) -> Bool {
        SlackHuddleDetector.isHuddleActive(processes, slackBundle: slack)
    }

    func testSlackHelperUsingMicIsAHuddle() {
        XCTAssertTrue(active([
            AudioProcessUsage(bundleID: "com.tinyspeck.slackmacgap.helper", isRunningInput: true),
        ]))
    }

    func testMainSlackProcessUsingMicIsAHuddle() {
        XCTAssertTrue(active([AudioProcessUsage(bundleID: slack, isRunningInput: true)]))
    }

    /// Sonnerie, son de fin de huddle, notification : de la sortie sans micro.
    func testSlackOutputWithoutMicIsNotAHuddle() {
        XCTAssertFalse(active([
            AudioProcessUsage(bundleID: "com.tinyspeck.slackmacgap.helper", isRunningInput: false),
        ]))
    }

    /// Un Meet dans Chrome (ou Onyx qui enregistre) n'est pas un huddle Slack.
    func testOtherAppsUsingMicAreIgnored() {
        XCTAssertFalse(active([
            AudioProcessUsage(bundleID: "com.google.Chrome.helper", isRunningInput: true),
            AudioProcessUsage(bundleID: "com.yvanbetremieux.onyx", isRunningInput: true),
        ]))
    }

    func testLookalikeBundleIsIgnored() {
        XCTAssertFalse(active([
            AudioProcessUsage(bundleID: "com.tinyspeck.slackmacgapfake", isRunningInput: true),
        ]))
    }

    func testNoAudioProcessesIsNotAHuddle() {
        XCTAssertFalse(active([]))
    }
}
