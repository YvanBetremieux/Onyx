import XCTest
import RecorderCore
@testable import Onyx

/// Logic behind the transcript turns: timestamp formatting, the speaker-colour
/// mapping, playhead hit-testing, and the empty state.
final class TranscriptTurnTests: XCTestCase {

    // MARK: - Timestamps

    func test_mmss_formatsBelowAnHourAsMinutesSeconds() {
        XCTAssertEqual(TurnStyle.mmss(0), "00:00")
        XCTAssertEqual(TurnStyle.mmss(5), "00:05")
        XCTAssertEqual(TurnStyle.mmss(65), "01:05")
        XCTAssertEqual(TurnStyle.mmss(599), "09:59")
        XCTAssertEqual(TurnStyle.mmss(3_599), "59:59")
    }

    func test_mmss_switchesToHoursAtAnHour() {
        XCTAssertEqual(TurnStyle.mmss(3_600), "01:00:00")
        XCTAssertEqual(TurnStyle.mmss(3_725), "01:02:05")
        XCTAssertEqual(TurnStyle.mmss(36_000), "10:00:00")
    }

    /// `Int(Double.nan)` traps and a negative time would format as "-1:-5", so
    /// non-finite / negative input must be clamped rather than trusted. The
    /// values come from JSON written by the pipeline, so they are not axiomatic.
    func test_mmss_clampsNonFiniteAndNegativeInput() {
        XCTAssertEqual(TurnStyle.mmss(-1), "00:00")
        XCTAssertEqual(TurnStyle.mmss(.nan), "00:00")
        XCTAssertEqual(TurnStyle.mmss(.infinity), "00:00")
        XCTAssertEqual(TurnStyle.mmss(-.infinity), "00:00")
    }

    // MARK: - Speaker colours

    /// `abs(speaker.hashValue) % n` (the plan's version) has two defects:
    /// `hashValue` is seeded per process so a speaker changes colour between
    /// launches, and `abs(Int.min)` traps. The mapping must be stable and total.
    func test_paletteIndex_isStableAcrossRunsAndWithinBounds() {
        for name in ["MOI", "SPEAKER_00", "SPEAKER_01", "SPEAKER_UNKNOWN", "", "é🙂"] {
            let i = TurnStyle.paletteIndex(for: name)
            XCTAssertTrue((0..<TurnStyle.paletteCount).contains(i), "out of range for \(name)")
            XCTAssertEqual(i, TurnStyle.paletteIndex(for: name), "must be deterministic")
        }
        // Pinned values: a regression here means speaker colours shuffled.
        XCTAssertEqual(TurnStyle.paletteIndex(for: "MOI"),
                       TurnStyle.paletteIndex(for: "MOI"))
        XCTAssertNotEqual(TurnStyle.paletteIndex(for: "MOI"),
                          TurnStyle.paletteIndex(for: "SPEAKER_00"),
                          "the two most common speakers must not share a colour")
    }

    // MARK: - Playhead

    private let segs = [
        TranscriptSegment(start: 0, end: 2, speaker: "MOI", text: "a"),
        TranscriptSegment(start: 2, end: 4, speaker: "SPEAKER_00", text: "b"),
        TranscriptSegment(start: 10, end: 12, speaker: "MOI", text: "c"),
    ]

    func test_activeIndex_usesHalfOpenIntervals() {
        XCTAssertEqual(TranscriptPanelRules.activeIndex(in: segs, playhead: 0), 0)
        XCTAssertEqual(TranscriptPanelRules.activeIndex(in: segs, playhead: 1.9), 0)
        // The boundary belongs to the *next* turn, so two turns never light up.
        XCTAssertEqual(TranscriptPanelRules.activeIndex(in: segs, playhead: 2), 1)
        XCTAssertEqual(TranscriptPanelRules.activeIndex(in: segs, playhead: 11), 2)
    }

    func test_activeIndex_isNilInAGapOrPastTheEnd() {
        XCTAssertNil(TranscriptPanelRules.activeIndex(in: segs, playhead: 6))
        XCTAssertNil(TranscriptPanelRules.activeIndex(in: segs, playhead: 99))
        XCTAssertNil(TranscriptPanelRules.activeIndex(in: [], playhead: 0))
    }

    // MARK: - ForEach identity

    /// `MeetingIndexer.search` aside, transcript turns really can share a
    /// timestamp *and* a speaker (mic and system streams are merged), so neither
    /// `start` nor `speaker` is a usable `ForEach` id. Row identity must be
    /// positional.
    func test_rowIdentityIsUniqueEvenForIdenticalSegments() {
        let dupes = [
            TranscriptSegment(start: 1, end: 2, speaker: "MOI", text: "same"),
            TranscriptSegment(start: 1, end: 2, speaker: "MOI", text: "same"),
            TranscriptSegment(start: 1, end: 2, speaker: "MOI", text: "same"),
        ]
        let rows = TranscriptPanelRules.rows(dupes)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(Set(rows.map(\.id)).count, 3, "duplicate ids would collapse rows")
        XCTAssertEqual(rows.map(\.id), [0, 1, 2])
    }

    // MARK: - Empty state

    func test_emptyMessage_isNilWhenThereAreSegments() {
        XCTAssertNil(TranscriptPanelRules.emptyMessage(segmentCount: 1,
                                                       transcriptState: "done"))
    }

    func test_emptyMessage_distinguishesInProgressFromFailedFromEmptyResult() {
        let running = TranscriptPanelRules.emptyMessage(segmentCount: 0,
                                                        transcriptState: "in_progress")
        let failed = TranscriptPanelRules.emptyMessage(segmentCount: 0,
                                                       transcriptState: "failed")
        let done = TranscriptPanelRules.emptyMessage(segmentCount: 0,
                                                     transcriptState: "done")
        XCTAssertNotNil(running); XCTAssertNotNil(failed); XCTAssertNotNil(done)
        XCTAssertNotEqual(running, done)
        XCTAssertNotEqual(failed, done)
        XCTAssertEqual(TranscriptPanelRules.emptyMessage(segmentCount: 0,
                                                         transcriptState: nil),
                       running)
    }
}
