import XCTest
@testable import RecorderCore

final class ClaudeAuthClassifierTests: XCTestCase {
    /// Message réel du 2026-09-07T11:12:35Z et des 10 réunions suivantes.
    func testNotLoggedInOnStdout() {
        let out = "Not logged in · Please run /login"
        XCTAssertEqual(ClaudeAuthClassifier.classify(exitCode: 1, stdout: out, stderr: ""),
                       .notLoggedIn)
    }

    /// Message réel du 2026-09-07T08:12:54Z — la toute première défaillance.
    func testSessionExpiredOnStdout() {
        let out = "Failed to authenticate: OAuth session expired and could not be refreshed"
        XCTAssertEqual(ClaudeAuthClassifier.classify(exitCode: 1, stdout: out, stderr: ""),
                       .sessionExpired)
    }

    /// Le CLI écrit sur stdout aujourd'hui. Parier sur ce seul canal est
    /// exactement l'hypothèse qui a causé l'incident : stderr doit marcher aussi.
    func testDetectedOnStderrToo() {
        XCTAssertEqual(ClaudeAuthClassifier.classify(exitCode: 1, stdout: "",
                                                     stderr: "not logged in, please run /login"),
                       .notLoggedIn)
    }

    /// Ces échecs ne sont PAS des déconnexions : proposer « reconnecte-toi »
    /// serait un faux diagnostic.
    func testNonAuthFailuresAreNotClassified() {
        XCTAssertNil(ClaudeAuthClassifier.classify(exitCode: 1,
                                                   stdout: "Invalid API key", stderr: ""))
        XCTAssertNil(ClaudeAuthClassifier.classify(exitCode: 1,
                                                   stdout: "Credit balance too low", stderr: ""))
        XCTAssertNil(ClaudeAuthClassifier.classify(exitCode: 1,
                                                   stdout: "Claude usage limit reached",
                                                   stderr: ""))
        XCTAssertNil(ClaudeAuthClassifier.classify(exitCode: 1, stdout: "", stderr: ""))
    }

    /// Un exit 0 est un succès, quel que soit le texte produit : une note qui
    /// *parle* de login ne doit pas déclencher la bannière.
    func testExitZeroIsNeverAnAuthFailure() {
        let out = "TITRE: Onboarding\n- l'utilisateur doit run /login, il n'est pas logged in"
        XCTAssertNil(ClaudeAuthClassifier.classify(exitCode: 0, stdout: out, stderr: ""))
    }

    func testCaseInsensitiveAndSurroundedByNoise() {
        let out = "\u{1B}[31mERROR\u{1B}[0m NOT LOGGED IN · PLEASE RUN /LOGIN\nbye\n"
        XCTAssertEqual(ClaudeAuthClassifier.classify(exitCode: 1, stdout: out, stderr: ""),
                       .notLoggedIn)
    }

    /// Le marqueur générique « Failed to authenticate: » est conservé
    /// volontairement : si le CLI dit avoir échoué à s'authentifier, c'est un
    /// problème d'auth même si la raison précise est inconnue — l'action de
    /// l'utilisateur (se reconnecter) reste la même.
    func testGenericFailedToAuthenticateIsSessionExpired() {
        let out = "Failed to authenticate: something we have never seen"
        XCTAssertEqual(ClaudeAuthClassifier.classify(exitCode: 1, stdout: out, stderr: ""),
                       .sessionExpired)
    }

    func testBacktickedLoginMarker() {
        let out = "Session invalid, please run `/login`"
        XCTAssertEqual(ClaudeAuthClassifier.classify(exitCode: 1, stdout: out, stderr: ""),
                       .notLoggedIn)
    }

    /// L'expiration est vérifiée en premier : un message qui contient les deux
    /// familles de marqueurs doit être classé comme expiration, pas comme
    /// déconnexion.
    func testExpiryTakesPrecedenceOverNotLoggedIn() {
        let out = "Failed to authenticate: not logged in, please run /login"
        XCTAssertEqual(ClaudeAuthClassifier.classify(exitCode: 1, stdout: out, stderr: ""),
                       .sessionExpired)
    }
}
