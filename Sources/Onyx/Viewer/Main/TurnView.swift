import SwiftUI
import RecorderCore

/// Presentation logic for a transcript turn, extracted from the view so the two
/// things that can actually be wrong — timestamp formatting and the
/// speaker→colour mapping — are testable.
enum TurnStyle {
    /// Muted speaker colours. Each pair is dark enough for the light appearance
    /// and light enough for the dark one, so no per-scheme table is needed.
    static let palette: [Color] = [
        Color(red: 0.72, green: 0.35, blue: 0.24),
        Color(red: 0.24, green: 0.48, blue: 0.66),
        Color(red: 0.35, green: 0.50, blue: 0.18),
        Color(red: 0.50, green: 0.35, blue: 0.64),
    ]
    static var paletteCount: Int { palette.count }

    /// Deterministic speaker→palette mapping.
    ///
    /// Deliberately NOT `abs(speaker.hashValue) % n`: `String.hashValue` is
    /// seeded per process, so a speaker would change colour on every launch, and
    /// `abs(Int.min)` traps. An FNV-1a walk over the UTF-8 bytes is stable and
    /// total.
    static func paletteIndex(for speaker: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in speaker.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return Int(hash % UInt64(paletteCount))
    }

    static func color(for speaker: String) -> Color {
        palette[paletteIndex(for: speaker)]
    }

    /// `mm:ss`, widening to `hh:mm:ss` past one hour.
    ///
    /// Clamps first: these values come from JSON written by the pipeline, and
    /// `Int(Double.nan)` is a trap, not a wrong answer.
    static func mmss(_ t: TimeInterval) -> String {
        let secs = (t.isFinite && t > 0) ? Int(t.rounded(.down)) : 0
        let hh = secs / 3600, mm = (secs % 3600) / 60, ss = secs % 60
        return hh > 0 ? String(format: "%02d:%02d:%02d", hh, mm, ss)
                      : String(format: "%02d:%02d", mm, ss)
    }
}

/// One timestamped speaker turn.
///
/// Read-only by design: the plan's transcript panel renders `Text`, and there is
/// no write-back path for individual segments (`transcript.json` is the
/// pipeline's output and also the FTS index's source, so editing a turn here
/// would silently desynchronise the index). Editing is not in this phase.
struct TurnView: View {
    let segment: TranscriptSegment
    /// Highlighted by the playhead.
    let isActive: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(TurnStyle.mmss(segment.start))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Circle().fill(TurnStyle.color(for: segment.speaker))
                        .frame(width: 8, height: 8)
                    Text(segment.speaker)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TurnStyle.color(for: segment.speaker))
                }
                Text(segment.text)
                    .font(.system(size: 14.5))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .background(isActive ? Color.accentColor.opacity(0.10) : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(segment.speaker), \(TurnStyle.mmss(segment.start))")
        .accessibilityValue(segment.text)
    }
}
