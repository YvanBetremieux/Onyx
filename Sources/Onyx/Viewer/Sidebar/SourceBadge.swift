import SwiftUI
import RecorderCore

/// Small monospaced pill telling the user how a recording got started.
///
/// `MeetingMetadata.Source` only has `manual / calendar / detected`, so the
/// four visual states are derived from `source` *plus* `detectedApp`
/// (`MeetingApp` rawValue): Google Meet and Slack huddles both arrive as
/// `.detected`.
struct SourceBadge: View {
    let kind: Kind

    init(kind: Kind) { self.kind = kind }

    init(source: MeetingMetadata.Source?, detectedApp: String? = nil) {
        self.kind = Kind(source: source, detectedApp: detectedApp)
    }

    init(meeting: MeetingListing) {
        self.init(source: meeting.source, detectedApp: meeting.detectedApp)
    }

    enum Kind: Equatable {
        case manual, calendar, meet, huddle, unknown

        init(source: MeetingMetadata.Source?, detectedApp: String?) {
            switch source {
            case .manual: self = .manual
            case .calendar: self = .calendar
            case .detected:
                // Unknown / missing app degrades to MEET rather than "—": a
                // detected call is never "unknown origin", and Meet is the
                // default detector.
                self = detectedApp == MeetingApp.slackHuddle.rawValue ? .huddle : .meet
            case nil: self = .unknown
            }
        }

        var label: String {
            switch self {
            case .manual: return "MANUAL"
            case .calendar: return "CAL"
            case .meet: return "MEET"
            case .huddle: return "HUDDLE"
            case .unknown: return "—"
            }
        }
    }

    var body: some View {
        Text(kind.label)
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .kerning(0.4)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .foregroundStyle(fg)
            .background(bg, in: RoundedRectangle(cornerRadius: 3))
    }

    private var bg: Color {
        switch kind {
        case .meet: return Color(red: 0.09, green: 0.50, blue: 0.22).opacity(0.10)
        case .huddle: return Color(red: 0.60, green: 0.24, blue: 0.78).opacity(0.10)
        case .calendar: return Color(red: 0.23, green: 0.23, blue: 0.78).opacity(0.10)
        case .manual, .unknown: return Color.primary.opacity(0.06)
        }
    }

    private var fg: Color {
        switch kind {
        case .meet: return Color(red: 0.09, green: 0.38, blue: 0.20)
        case .huddle: return Color(red: 0.42, green: 0.16, blue: 0.56)
        case .calendar: return Color(red: 0.16, green: 0.23, blue: 0.64)
        case .manual, .unknown: return Color.secondary
        }
    }
}
