import XCTest
@testable import RecorderCore

final class JobStateNotesStepTests: XCTestCase {
    func testFreshHasNotesStepPending() {
        let s = JobState.fresh()
        XCTAssertEqual(s.stepStatus(.notes), .pending)
    }

    func testAllCasesIncludesNotesLast() {
        // .notes must appear after .cleanup so the pipeline runs it last.
        let order = JobStep.allCases
        let cleanupIdx = order.firstIndex(of: .cleanup)!
        let notesIdx = order.firstIndex(of: .notes)!
        XCTAssertGreaterThan(notesIdx, cleanupIdx)
    }

    func testDecodesChantier1JobJSONWithMissingNotesStep() throws {
        let json = """
        {
          "state":"done",
          "steps":{
            "normalize":{"status":"done"},
            "whisper_mic":{"status":"done"},
            "whisper_system":{"status":"done"},
            "diarize":{"status":"done"},
            "merge":{"status":"done"},
            "render":{"status":"done"},
            "cleanup":{"status":"done"}
          }
        }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(JobState.self, from: json)
        XCTAssertEqual(s.stepStatus(.notes), .pending,
                       "missing .notes must default to .pending")
    }

    func testGeneratingNotesOverallState() {
        var s = JobState.fresh()
        s.state = .generatingNotes
        XCTAssertEqual(s.state, .generatingNotes)
    }
}
