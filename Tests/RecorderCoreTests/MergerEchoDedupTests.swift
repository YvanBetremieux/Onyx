import XCTest
@testable import RecorderCore

/// Echo bleed: the mic hears the speakers, so remote speech lands on both
/// channels — same timestamps, slightly different wording. The Merger must
/// drop those mic copies while never touching genuine user speech.
/// Sample texts come from a real affected meeting (2026-08-03_00h32).
final class MergerEchoDedupTests: XCTestCase {

    private func seg(_ start: Double, _ end: Double, _ text: String) -> WhisperSegment {
        WhisperSegment(start: start, end: end, text: text)
    }

    func test_exactEcho_isDroppedFromMic() {
        let mic = [seg(24, 28, "Guizé, toi tu as eu la chance de pouvoir aller visiter plusieurs reprises, voir l'intérieur.")]
        let sys = [seg(24, 28, "Guizet, toi tu as eu la chance de pouvoir aller visiter plusieurs reprises, voir l'intérieur.")]
        XCTAssertTrue(Merger.dropEchoDuplicates(mic: mic, system: sys).isEmpty)
    }

    func test_echoWithWhisperDrift_isStillDropped() {
        // Two independent Whisper passes disagree on degraded audio.
        let mic = [seg(19, 22, "il faut que tu les nourrisses, il faut que tu les soignes quand ils se laissent,")]
        let sys = [seg(20, 23, "il faut que tu les nourrisses, il faut que tu les soignes quand ils se blessent,")]
        XCTAssertTrue(Merger.dropEchoDuplicates(mic: mic, system: sys).isEmpty)
    }

    func test_genuineUserSpeech_isKept() {
        let mic = [seg(10, 13, "Attends, je partage mon écran deux secondes.")]
        let sys = [seg(10, 14, "Et donc du coup, les momies étaient parties.")]
        XCTAssertEqual(Merger.dropEchoDuplicates(mic: mic, system: sys), mic,
                       "simultaneous but different speech is a real exchange, not echo")
    }

    func test_sameSentenceMinutesApart_isNotEcho() {
        let mic = [seg(10, 12, "On n'a jamais trouvé aucune momie.")]
        let sys = [seg(300, 302, "On n'a jamais trouvé aucune momie.")]
        XCTAssertEqual(Merger.dropEchoDuplicates(mic: mic, system: sys), mic,
                       "the time gate must keep repetitions from being merged")
    }

    func test_merge_endToEnd_dropsEchoAndKeepsRealTurns() {
        let mic = [
            seg(0, 3, "Et on dit mais qu'est-ce qui nous permet d'affirmer qu'il y avait des momies?"),  // écho
            seg(5, 7, "Attends, je reviens dans une minute."),                                            // vraie voix
        ]
        let sys = [
            seg(0, 3, "Et on dit, mais qu'est-ce qui nous permet d'affirmer qu'il y avait des momies?"),
        ]
        let diar = [DiarSegment(start: 0, end: 3, speakerId: "SPEAKER_00")]
        let out = Merger.merge(mic: mic, system: sys, diarization: diar)
        XCTAssertEqual(out.map(\.speaker), ["SPEAKER_00", "MOI"])
        XCTAssertEqual(out.last?.text, "Attends, je reviens dans une minute.")
    }

    func test_similarity_foldsCaseDiacriticsAndPunctuation() {
        XCTAssertEqual(Merger.textSimilarity("Ça n'a pas de sens.", "ca n'a pas de sens"), 1)
        XCTAssertLessThan(Merger.textSimilarity("On fait autre chose.", "Quelle est ton opinion à toi?"), 0.5)
    }
}
