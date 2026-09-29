import XCTest
import RecorderCore
@testable import Onyx

final class MeetingHeaderViewTests: XCTestCase {
    private func seg(_ speaker: String, _ start: Double = 0) -> TranscriptSegment {
        TranscriptSegment(start: start, end: start + 1, speaker: speaker, text: "x")
    }

    func test_participantInitials_areUniqueAndInFirstAppearanceOrder() {
        let segs = [seg("MOI"), seg("SPEAKER_00", 1), seg("MOI", 2), seg("SPEAKER_00", 3)]
        XCTAssertEqual(MeetingHeaderView.participantInitials(from: segs), ["M", "S0"])
    }

    func test_participantInitials_ignoresBlankSpeakers() {
        let segs = [seg(""), seg("   ", 1), seg("Sophie Martin", 2)]
        XCTAssertEqual(MeetingHeaderView.participantInitials(from: segs), ["SM"])
    }

    func test_participantInitials_emptyTranscript_yieldsNoParticipants() {
        XCTAssertEqual(MeetingHeaderView.participantInitials(from: []), [])
    }

    func test_humanDuration_secondsMinutesHours() {
        XCTAssertEqual(MeetingHeaderView.humanDuration(0), "0 s")
        XCTAssertEqual(MeetingHeaderView.humanDuration(59), "59 s")
        XCTAssertEqual(MeetingHeaderView.humanDuration(60), "1 min")
        XCTAssertEqual(MeetingHeaderView.humanDuration(3599), "59 min")
        XCTAssertEqual(MeetingHeaderView.humanDuration(3600), "1h00")
        XCTAssertEqual(MeetingHeaderView.humanDuration(5430), "1h30")
    }

    func test_humanDuration_negativeIsClampedNotFormattedAsGarbage() {
        XCTAssertEqual(MeetingHeaderView.humanDuration(-42), "0 s")
    }

    // MARK: - Regenerate affordance

    /// "Régénérer notes" was a silent no-op on the Direct tab:
    /// `ViewerStore.regenerateActiveNote()` correctly refuses `.live`, but the
    /// button still looked live and clicking it did nothing at all.
    func test_regenerateEnabled_isFalseForLive() {
        XCTAssertFalse(MeetingHeaderView.regenerateEnabled(for: .live),
                       "the Direct tab holds the user's own notes — never regenerable")
    }

    func test_regenerateEnabled_isTrueForEveryGeneratableLevel() {
        for level in NoteLevel.generatable {
            XCTAssertTrue(MeetingHeaderView.regenerateEnabled(for: level),
                          "\(level.rawValue) must stay regenerable")
        }
    }

    /// The header and the tab strip must not be able to drift apart about which
    /// levels are regenerable.
    func test_regenerateEnabled_matchesNotesPanelRules() {
        for level in NoteLevel.allCases {
            XCTAssertEqual(MeetingHeaderView.regenerateEnabled(for: level),
                           NotesPanelRules.canRegenerate(level))
        }
    }
}
