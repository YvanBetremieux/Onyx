import XCTest
import RecorderCore
@testable import Onyx

/// The rules the notes panel's chrome depends on, extracted from the view so
/// they are testable — this is where the `.live` invariant is enforced in the UI.
final class NotesPanelRulesTests: XCTestCase {

    // MARK: - Tab strip

    /// All four levels are shown: the user reads and edits their own live notes
    /// in this panel, so `.live` belongs in the strip even though it is never a
    /// generation target.
    func test_tabsCoverAllFourLevelsInReadingOrder() {
        XCTAssertEqual(NotesPanelRules.tabs.map(\.level),
                       [.live, .brief, .synthese, .detaillee])
        XCTAssertEqual(Set(NotesPanelRules.tabs.map(\.level)),
                       Set(NoteLevel.allCases))
    }

    func test_everyTabHasATitleAndAnIcon() {
        for tab in NotesPanelRules.tabs {
            XCTAssertFalse(tab.title.isEmpty)
            XCTAssertFalse(tab.icon.isEmpty)
        }
    }

    // MARK: - Regeneration availability

    func test_regenerateIsUnavailableForLiveAndAvailableForEveryGeneratableLevel() {
        XCTAssertFalse(NotesPanelRules.canRegenerate(.live))
        for level in NoteLevel.generatable {
            XCTAssertTrue(NotesPanelRules.canRegenerate(level), "\(level) should be regenerable")
        }
        // Keep the panel's rule and the domain's rule in lockstep.
        XCTAssertEqual(NoteLevel.allCases.filter(NotesPanelRules.canRegenerate),
                       NoteLevel.generatable)
    }

    // MARK: - Banner visibility

    func test_bannerShowsOnlyForAGeneratedLevelThatIsEditedAndNotDismissed() {
        XCTAssertTrue(NotesPanelRules.showsRegenerateBanner(
            level: .synthese, notesEdited: true, dismissed: false))
        XCTAssertFalse(NotesPanelRules.showsRegenerateBanner(
            level: .synthese, notesEdited: false, dismissed: false))
        XCTAssertFalse(NotesPanelRules.showsRegenerateBanner(
            level: .synthese, notesEdited: true, dismissed: true))
    }

    func test_bannerNeverShowsForLiveWhateverTheFlags() {
        for edited in [true, false] {
            for dismissed in [true, false] {
                XCTAssertFalse(NotesPanelRules.showsRegenerateBanner(
                    level: .live, notesEdited: edited, dismissed: dismissed),
                               "live notes are always user-authored: no banner")
            }
        }
    }

    // MARK: - Empty states

    /// A meeting whose pipeline is still running must say so rather than render
    /// an empty page that looks like a bug.
    func test_placeholderDistinguishesTranscribingFromNothingGenerated() {
        let running = NotesPanelRules.placeholder(for: .synthese, transcriptState: "in_progress")
        let done = NotesPanelRules.placeholder(for: .synthese, transcriptState: "done")
        let failed = NotesPanelRules.placeholder(for: .synthese, transcriptState: "failed")
        let unknown = NotesPanelRules.placeholder(for: .synthese, transcriptState: nil)

        for text in [running, done, failed, unknown] { XCTAssertFalse(text.isEmpty) }
        XCTAssertNotEqual(running, done)
        XCTAssertNotEqual(failed, done)
        XCTAssertEqual(unknown, running,
                       "an unknown state is treated as still-in-progress, not as failure")
    }

    /// The empty state's *action*. The placeholder copy already existed; what was
    /// missing (Task 40) is a button, and it must only appear when pressing it
    /// could actually work.
    func test_generateActionOnlyOfferedWhenTheNoteIsEmptyAndTheTranscriptIsDone() {
        XCTAssertTrue(NotesPanelRules.showsGenerateAction(
            level: .synthese, transcriptState: "done", noteIsEmpty: true))
        // Something is already on screen: the header's regenerate button owns
        // that case, an inline "Générer" would be an accidental overwrite.
        XCTAssertFalse(NotesPanelRules.showsGenerateAction(
            level: .synthese, transcriptState: "done", noteIsEmpty: false))
    }

    /// No transcript yet (or ever) ⇒ nothing to generate from. Offering the
    /// button would guarantee a `transcriptMissing` error.
    func test_generateActionNotOfferedWhileTranscribingOrAfterAFailure() {
        for state in ["in_progress", "failed", nil] {
            XCTAssertFalse(NotesPanelRules.showsGenerateAction(
                level: .brief, transcriptState: state, noteIsEmpty: true),
                           "state \(state ?? "nil") has no usable transcript")
        }
    }

    /// The `.live` invariant, once more: `notes/live.md` is the user's own text
    /// and a "Générer" button pointing at it would destroy it.
    func test_generateActionNeverOfferedForLive() {
        for state in ["done", "in_progress", "failed", nil] {
            for empty in [true, false] {
                XCTAssertFalse(NotesPanelRules.showsGenerateAction(
                    level: .live, transcriptState: state, noteIsEmpty: empty),
                               "live notes are never generated")
            }
        }
    }

    func test_generateActionAgreesWithCanRegenerate() {
        for level in NoteLevel.allCases {
            XCTAssertEqual(
                NotesPanelRules.showsGenerateAction(
                    level: level, transcriptState: "done", noteIsEmpty: true),
                NotesPanelRules.canRegenerate(level))
        }
    }

    /// `.live` is never generated, so its placeholder must invite typing rather
    /// than mention generation at all.
    func test_livePlaceholderIsTheSameWhateverThePipelineState() {
        let a = NotesPanelRules.placeholder(for: .live, transcriptState: "in_progress")
        let b = NotesPanelRules.placeholder(for: .live, transcriptState: "done")
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.isEmpty)
        XCTAssertFalse(a.lowercased().contains("régénér"))
    }
}
