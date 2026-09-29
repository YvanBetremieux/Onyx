import XCTest
@testable import RecorderCore

final class CalendarAccessFlowTests: XCTestCase {
    /// Faux TCC : un statut, et le journal des appels dans l'ordre.
    private final class FakeTCC: @unchecked Sendable {
        var status: CalendarAccess
        /// Statut après la demande (ce que l'utilisateur répond au dialogue).
        var answer: CalendarAccess
        var calls: [String] = []
        init(_ status: CalendarAccess, answer: CalendarAccess = .granted) {
            self.status = status; self.answer = answer
        }
        var flow: CalendarAccessFlow {
            CalendarAccessFlow(
                status: { self.status },
                resetDecision: { self.calls.append("reset"); self.status = .notDetermined },
                request: {
                    self.calls.append("request")
                    // Comme TCC : pas de dialogue si une décision est déjà enregistrée.
                    if self.status == .notDetermined { self.status = self.answer }
                    return self.status == .granted
                })
        }
    }

    func testAlreadyGrantedTouchesNothing() async {
        let tcc = FakeTCC(.granted)
        let result = await tcc.flow.ensureAccess()
        XCTAssertEqual(result, .granted)
        XCTAssertEqual(tcc.calls, [])
    }

    func testNeverAskedRequestsWithoutReset() async {
        let tcc = FakeTCC(.notDetermined)
        let result = await tcc.flow.ensureAccess()
        XCTAssertEqual(result, .granted)
        XCTAssertEqual(tcc.calls, ["request"])
    }

    /// Le cas qui bloque l'utilisateur : un refus enregistré ne redonne jamais
    /// de dialogue, et Onyx n'est pas ajoutable à la main dans les Réglages.
    /// Il faut effacer la décision AVANT de redemander.
    func testDeniedIsResetThenRequestedAgain() async {
        let tcc = FakeTCC(.denied)
        let result = await tcc.flow.ensureAccess()
        XCTAssertEqual(result, .granted)
        XCTAssertEqual(tcc.calls, ["reset", "request"])
    }

    func testUserRefusingAgainReportsDenied() async {
        let tcc = FakeTCC(.denied, answer: .denied)
        let result = await tcc.flow.ensureAccess()
        XCTAssertEqual(result, .denied)
    }

    /// Valeurs brutes d'EKAuthorizationStatus : 0 notDetermined, 1 restricted,
    /// 2 denied, 3 authorized/fullAccess, 4 writeOnly (macOS 14+). Un accès
    /// « écriture seule » ne permet pas de lire les événements : c'est un refus.
    func testMapsEventKitStatuses() {
        XCTAssertEqual(CalendarAccessFlow.map(rawStatus: 0), .notDetermined)
        XCTAssertEqual(CalendarAccessFlow.map(rawStatus: 1), .denied)
        XCTAssertEqual(CalendarAccessFlow.map(rawStatus: 2), .denied)
        XCTAssertEqual(CalendarAccessFlow.map(rawStatus: 3), .granted)
        XCTAssertEqual(CalendarAccessFlow.map(rawStatus: 4), .denied)
        XCTAssertEqual(CalendarAccessFlow.map(rawStatus: 99), .denied)
    }
}
