import XCTest
@testable import RecorderCore

/// 2026-10-02 : sur un MacBook Pro Apple Silicon, le traitement de la voix
/// d'Apple (AEC) baissait le micro de TOUTES les apps — les participants du
/// Meet ne l'entendaient plus — et l'effet persistait jusqu'à quitter Onyx.
/// Il ne doit plus être actif sans que l'utilisateur l'ait choisi.
final class MicRecorderConfigTests: XCTestCase {
    func testEchoCancellationIsOffByDefault() {
        XCTAssertFalse(MicRecorder.Config().echoCancellation)
    }

    func testEchoCancellationSettingIsOffWhenNeverSet() {
        let defaults = UserDefaults(suiteName: "MicRecorderConfigTests-\(UUID().uuidString)")!
        XCTAssertFalse(MicRecorder.echoCancellationEnabled(in: defaults))
        defaults.set(true, forKey: MicRecorder.echoCancellationDefaultsKey)
        XCTAssertTrue(MicRecorder.echoCancellationEnabled(in: defaults))
    }
}
