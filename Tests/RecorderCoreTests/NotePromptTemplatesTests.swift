import XCTest
@testable import RecorderCore

final class NotePromptTemplatesTests: XCTestCase {
    func testHasOnePromptPerLevel() {
        for level in NoteLevel.allCases {
            let prompt = NotePromptTemplates.prompt(for: level, transcript: "T")
            XCTAssertFalse(prompt.isEmpty, "prompt missing for \(level)")
        }
    }

    func testTranscriptPlaceholderIsReplaced() {
        let p = NotePromptTemplates.prompt(for: .synthese,
                                           transcript: "MOI: hello world")
        XCTAssertTrue(p.contains("MOI: hello world"),
                      "transcript must be inlined")
        XCTAssertFalse(p.contains("{{TRANSCRIPT}}"),
                       "placeholder must be replaced")
    }

    func testPromptsAreDistinctPerLevel() {
        let b = NotePromptTemplates.prompt(for: .brief, transcript: "X")
        let s = NotePromptTemplates.prompt(for: .synthese, transcript: "X")
        let d = NotePromptTemplates.prompt(for: .detaillee, transcript: "X")
        XCTAssertNotEqual(b, s)
        XCTAssertNotEqual(s, d)
        XCTAssertNotEqual(b, d)
    }

    func testPromptMentionsSpeakerConvention() {
        for level in NoteLevel.allCases {
            let p = NotePromptTemplates.prompt(for: level, transcript: "")
            XCTAssertTrue(p.contains("MOI"), "\(level) prompt missing MOI marker")
            XCTAssertTrue(p.contains("SPEAKER"), "\(level) prompt missing SPEAKER marker")
        }
    }
}
