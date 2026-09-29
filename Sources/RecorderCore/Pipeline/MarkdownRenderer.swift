import Foundation

public enum MarkdownRenderer {
    /// A "Partie N" heading to insert in the transcript at `offsetSeconds`.
    ///
    /// Only ever non-empty for a manually merged meeting, whose parts are butted
    /// end-to-end: the rendered `HH:mm:ss` stamps of parts 2+ no longer match
    /// the wall clock, so the real recording time of each part has to be stated
    /// somewhere. It also gives Claude an explicit boundary — without it, two
    /// unrelated conversations read as one continuous discussion.
    public struct PartBoundary: Equatable, Sendable {
        public let offsetSeconds: Double
        public let label: String
        public init(offsetSeconds: Double, label: String) {
            self.offsetSeconds = offsetSeconds
            self.label = label
        }
    }

    public static func render(segments: [TranscriptSegment], meetingStart: Date,
                              slug: String, timeZone: TimeZone = .current,
                              partBoundaries: [PartBoundary] = []) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = timeZone
        fmt.dateFormat = "HH:mm:ss"

        var out = "# Meeting \(slug)\n\n"
        // Emitted in order as the segments cross their offsets. A boundary at or
        // before the first segment still lands before it, and any boundary past
        // the last segment is flushed at the end, so no part heading is lost
        // even when a part transcribed to nothing.
        var pending = partBoundaries.sorted { $0.offsetSeconds < $1.offsetSeconds }
        for seg in segments {
            while let next = pending.first, next.offsetSeconds <= seg.start {
                out += "---\n\n### \(next.label)\n\n"
                pending.removeFirst()
            }
            let abs = meetingStart.addingTimeInterval(seg.start)
            out += "## \(fmt.string(from: abs)) — \(seg.speaker)\n"
            out += "\(seg.text)\n\n"
        }
        for boundary in pending {
            out += "---\n\n### \(boundary.label)\n\n"
        }
        return out
    }
}
