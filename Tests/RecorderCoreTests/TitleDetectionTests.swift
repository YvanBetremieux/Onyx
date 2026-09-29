import XCTest
@testable import RecorderCore

/// Auto-title rules: calendar meetings keep the event title (no debate);
/// huddles and wild meetings get titled by Claude at synthèse time, but a
/// user-typed title always wins.
final class TitleDetectionTests: XCTestCase {

    private func meta(title: String?, source: MeetingMetadata.Source,
                      auto: Bool? = nil) -> MeetingMetadata {
        var m = MeetingMetadata(id: "2026-08-01_10h00", startedAt: Date(),
                                title: title, source: source,
                                appVersion: "t", models: .init(whisper: "w", diarization: "d"))
        m.titleAutoDetected = auto
        return m
    }

    // MARK: - wantsTitleDetection

    func test_calendarMeeting_neverWantsDetection() {
        XCTAssertFalse(meta(title: "Weekly produit", source: .calendar).wantsTitleDetection)
        XCTAssertFalse(meta(title: nil, source: .calendar).wantsTitleDetection,
                       "even with a missing title, calendar stays Claude-free")
    }

    func test_untitledDetectedOrManual_wantsDetection() {
        XCTAssertTrue(meta(title: nil, source: .detected).wantsTitleDetection)
        XCTAssertTrue(meta(title: "  ", source: .manual).wantsTitleDetection)
    }

    func test_userTitle_disarmsDetection_butAutoTitleStaysRefreshable() {
        XCTAssertFalse(meta(title: "Mon titre", source: .detected, auto: false)
            .wantsTitleDetection, "a hand-typed title is the user's — never overwrite")
        XCTAssertTrue(meta(title: "Titre de Claude", source: .detected, auto: true)
            .wantsTitleDetection, "an auto title may be refreshed by the next synthèse")
        XCTAssertFalse(meta(title: "Legacy", source: .manual, auto: nil)
            .wantsTitleDetection, "pre-feature titles (nil flag) are treated as user-owned")
    }

    // MARK: - titleCarrier

    func test_titleCarrier_prefersSynthese_thenDetaillee_thenBrief() {
        XCTAssertEqual(NoteLevel.titleCarrier(among: [.brief, .synthese, .detaillee]), .synthese)
        XCTAssertEqual(NoteLevel.titleCarrier(among: [.brief, .detaillee]), .detaillee)
        XCTAssertEqual(NoteLevel.titleCarrier(among: [.brief]), .brief,
                       "brief-only config must still get an auto title")
        XCTAssertNil(NoteLevel.titleCarrier(among: []))
    }

    // MARK: - splitDetectedTitle

    func test_split_plainTitleLine() {
        let (title, body) = ClaudeNoteGenerator.splitDetectedTitle(
            from: "TITRE: Migration Salesforce Q3\n\n## Contexte\nBlah.")
        XCTAssertEqual(title, "Migration Salesforce Q3")
        XCTAssertEqual(body, "## Contexte\nBlah.")
    }

    func test_split_toleratesMarkdownWrappingAndLeadingBlank() {
        let (title, body) = ClaudeNoteGenerator.splitDetectedTitle(
            from: "\n**TITRE: Point recrutement**\n\n## Notes\nx")
        XCTAssertEqual(title, "Point recrutement")
        XCTAssertEqual(body, "## Notes\nx")
    }

    func test_split_missingTitle_returnsFullOutputUntouched() {
        let out = "## Contexte\nPas de ligne titre ici."
        let (title, body) = ClaudeNoteGenerator.splitDetectedTitle(from: out)
        XCTAssertNil(title)
        XCTAssertEqual(body, out)
    }

    func test_split_titreDeeperInBody_isContentNotMetadata() {
        let out = "## Notes\nOn a parlé du champ TITRE: machin dans le CRM."
        let (title, body) = ClaudeNoteGenerator.splitDetectedTitle(from: out)
        XCTAssertNil(title)
        XCTAssertEqual(body, out)
    }

    func test_split_emptyTitleAfterPrefix_returnsNilTitle() {
        let (title, _) = ClaudeNoteGenerator.splitDetectedTitle(from: "TITRE:   \n\ncorps")
        XCTAssertNil(title)
    }
}
