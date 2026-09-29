import XCTest
@testable import RecorderCore

final class NotePromptTemplatesLiveNotesTests: XCTestCase {
    func test_nilLiveNotes_promptUnchangedFromChantier2() {
        let p = NotePromptTemplates.prompt(
            for: .synthese, transcript: "MOI: hello", liveNotes: nil
        )
        XCTAssertFalse(p.contains("Notes prises par l'utilisateur"),
                       "no live-notes block when liveNotes is nil")
        XCTAssertTrue(p.contains("Transcript :"))
        XCTAssertTrue(p.contains("MOI: hello"))
    }

    func test_emptyLiveNotes_treatedAsNil() {
        let p1 = NotePromptTemplates.prompt(for: .brief, transcript: "x", liveNotes: "")
        let p2 = NotePromptTemplates.prompt(for: .brief, transcript: "x", liveNotes: "   \n  ")
        XCTAssertFalse(p1.contains("Notes prises par l'utilisateur"))
        XCTAssertFalse(p2.contains("Notes prises par l'utilisateur"))
    }

    func test_liveNotesPresent_blockInjectedBeforeTranscript() {
        let p = NotePromptTemplates.prompt(
            for: .synthese,
            transcript: "MOI: transcript body",
            liveNotes: "- decision X\n- action Y"
        )
        XCTAssertTrue(p.contains("Notes prises par l'utilisateur en direct pendant le meeting"))
        XCTAssertTrue(p.contains("- decision X"))
        XCTAssertTrue(p.contains("- action Y"))
        // The live block must appear before the transcript block.
        let iLive = p.range(of: "Notes prises par l'utilisateur")!.lowerBound
        let iTr   = p.range(of: "Transcript :")!.lowerBound
        XCTAssertLessThan(iLive, iTr)
    }

    func test_liveNotesInstruction_mentionsIntegration() {
        let p = NotePromptTemplates.prompt(
            for: .synthese, transcript: "x", liveNotes: "note"
        )
        XCTAssertTrue(p.lowercased().contains("intègre"))
    }
}
