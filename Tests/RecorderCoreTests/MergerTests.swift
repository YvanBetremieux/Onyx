import XCTest
@testable import RecorderCore

final class MergerTests: XCTestCase {
    func testMicSegmentsAreTaggedMoi() {
        let mic = [WhisperSegment(start: 0, end: 2, text: "hello")]
        let out = Merger.merge(mic: mic, system: [], diarization: [])
        XCTAssertEqual(out, [.init(start: 0, end: 2, speaker: "MOI", text: "hello")])
    }

    func testSystemSegmentGetsMaxOverlapSpeaker() {
        let sys = [WhisperSegment(start: 5, end: 8, text: "hi")]
        let diar = [
            DiarSegment(start: 4, end: 6, speakerId: "SPEAKER_00"),
            DiarSegment(start: 6, end: 9, speakerId: "SPEAKER_01"),
        ]
        let out = Merger.merge(mic: [], system: sys, diarization: diar)
        XCTAssertEqual(out.first?.speaker, "SPEAKER_01")
    }

    func testMergedTimelineIsSortedByStart() {
        let mic = [WhisperSegment(start: 3, end: 4, text: "b")]
        let sys = [WhisperSegment(start: 1, end: 2, text: "a"),
                   WhisperSegment(start: 5, end: 6, text: "c")]
        let diar = [DiarSegment(start: 0, end: 10, speakerId: "SPEAKER_00")]
        let out = Merger.merge(mic: mic, system: sys, diarization: diar)
        XCTAssertEqual(out.map(\.text), ["a", "b", "c"])
    }

    func testSystemSegmentWithoutDiarizationIsDropped() {
        // When diarization has segments but none overlap this window,
        // the segment is still dropped (anti-hallucination guard).
        let sys = [WhisperSegment(start: 0, end: 1, text: "x")]
        let diar = [DiarSegment(start: 10, end: 20, speakerId: "SPEAKER_00")]
        XCTAssertTrue(Merger.merge(mic: [], system: sys, diarization: diar).isEmpty)
    }

    func testEmptyDiarizationFallsBackToUnknownSpeakerInsteadOfDroppingEverything() {
        let system = [WhisperSegment(start: 0, end: 5, text: "Bonjour à tous"),
                      WhisperSegment(start: 6, end: 9, text: "On commence ?")]
        let merged = Merger.merge(mic: [], system: system, diarization: [])
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.allSatisfy { $0.speaker == "SPEAKER_UNKNOWN" })
    }
}
