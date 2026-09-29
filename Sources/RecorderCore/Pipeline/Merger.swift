import Foundation

public struct WhisperSegment: Codable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public var confidence: Double?
    public init(start: Double, end: Double, text: String, confidence: Double? = nil) {
        self.start = start; self.end = end; self.text = text; self.confidence = confidence
    }
}

public struct DiarSegment: Codable, Equatable {
    public var start: Double
    public var end: Double
    public var speakerId: String
    public init(start: Double, end: Double, speakerId: String) {
        self.start = start; self.end = end; self.speakerId = speakerId
    }
    private enum CodingKeys: String, CodingKey { case start, end, speakerId = "speaker_id" }
}

public struct TranscriptSegment: Codable, Equatable {
    public var start: Double
    public var end: Double
    public var speaker: String
    public var text: String
    public init(start: Double, end: Double, speaker: String, text: String) {
        self.start = start; self.end = end; self.speaker = speaker; self.text = text
    }
}

public enum Merger {
    public static func merge(mic: [WhisperSegment],
                             system: [WhisperSegment],
                             diarization: [DiarSegment]) -> [TranscriptSegment] {
        // Echo bleed: without (or despite) acoustic echo cancellation, the
        // mic picks up the speakers' output, so remote speech shows up twice —
        // once on the system channel and once as "MOI", same timestamps,
        // slightly different wording (two independent Whisper passes). A mic
        // segment that near-duplicates a simultaneous system segment is echo:
        // system audio never contains the user's own voice, so the speech is
        // genuinely remote — keep the system copy (clean audio), drop the
        // mic one.
        let cleanMic = dropEchoDuplicates(mic: mic, system: system)

        var out: [TranscriptSegment] = []
        for m in cleanMic {
            out.append(.init(start: m.start, end: m.end, speaker: "MOI", text: m.text))
        }
        // Global guard: if diarization detected nothing but Whisper transcribed system audio,
        // do NOT drop 100% of remote speech — label SPEAKER_UNKNOWN instead.
        let fallbackToUnknown = diarization.isEmpty && !system.isEmpty
        for s in system {
            if fallbackToUnknown {
                out.append(.init(start: s.start, end: s.end,
                                 speaker: "SPEAKER_UNKNOWN", text: s.text))
                continue
            }
            // Per-segment drop for no-overlap: anti-hallucination (preserved when diarization has segments).
            guard let speaker = assignSpeaker(to: s, diar: diarization) else { continue }
            out.append(.init(start: s.start, end: s.end, speaker: speaker, text: s.text))
        }
        out.sort { $0.start < $1.start }
        return out
    }

    // MARK: - Echo dedup

    /// Mic segments that near-duplicate a simultaneous system segment.
    static func dropEchoDuplicates(mic: [WhisperSegment],
                                   system: [WhisperSegment]) -> [WhisperSegment] {
        guard !system.isEmpty else { return mic }
        return mic.filter { m in
            !system.contains { s in isEchoDuplicate(mic: m, system: s) }
        }
    }

    /// True when the two segments are close in time AND say (almost) the same
    /// thing. The time gate keeps the text comparison from ever pairing a
    /// sentence with its repetition minutes later.
    static func isEchoDuplicate(mic m: WhisperSegment,
                                system s: WhisperSegment) -> Bool {
        let overlap = min(m.end, s.end) - max(m.start, s.start)
        guard overlap > 0 || abs(m.start - s.start) <= 2.0 else { return false }
        return textSimilarity(m.text, s.text) >= 0.75
    }

    /// Normalized similarity in [0, 1]: 1 − levenshtein / max-length, on
    /// case/diacritics/punctuation-folded text — the mic copy of an echo is
    /// transcribed from degraded audio, so small wording drifts are expected
    /// ("qu'ils se laissent" vs "qu'ils se blessent").
    static func textSimilarity(_ a: String, _ b: String) -> Double {
        let x = normalizeForComparison(a)
        let y = normalizeForComparison(b)
        if x == y { return 1 }
        if x.isEmpty || y.isEmpty { return 0 }
        let dist = levenshtein(Array(x), Array(y))
        return 1 - Double(dist) / Double(max(x.count, y.count))
    }

    private static func normalizeForComparison(_ text: String) -> String {
        let folded = text.lowercased()
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR"))
        let kept = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    static func assignSpeaker(to segment: WhisperSegment, diar: [DiarSegment]) -> String? {
        var best: (id: String, overlap: Double)? = nil
        for d in diar {
            let ov = max(0, min(segment.end, d.end) - max(segment.start, d.start))
            if ov > (best?.overlap ?? 0) { best = (d.speakerId, ov) }
        }
        return best?.id
    }
}
