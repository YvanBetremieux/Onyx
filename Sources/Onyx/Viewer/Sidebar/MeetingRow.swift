import SwiftUI
import RecorderCore

struct MeetingRow: View {
    let meeting: MeetingListing
    let selected: Bool
    /// Status badge ("Enregistrement…", "Transcription…", "En attente de
    /// transcription", …), nil for a meeting fully processed.
    var status: (label: String, kind: ViewerStore.RowStatusKind)? = nil
    /// Non-nil only for the meeting currently being recorded: renders the stop
    /// button in place of the duration.
    var onStop: (() -> Void)? = nil
    /// Checkbox column state. `nil` outside the sidebar's selection mode — the
    /// row then has no leading checkbox at all.
    var check: Check? = nil
    let onSelect: () -> Void
    @State private var hovering = false

    /// A row's checkbox: ticked or not, and whether it can be ticked at all
    /// (a meeting being recorded or processed cannot be deleted, so it cannot
    /// be part of a batch either).
    struct Check {
        let isChecked: Bool
        let enabled: Bool
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "d MMM"; return f
    }()

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 0) {
                if let check {
                    // Part of the row button, not a nested one: the whole row
                    // toggles the box in selection mode, so a nested button
                    // would only shrink the hit area for no gain.
                    Image(systemName: checkSymbol(check))
                        .font(.system(size: 14))
                        .foregroundStyle(check.enabled
                                         ? (check.isChecked
                                            ? AnyShapeStyle(Color.accentColor)
                                            : AnyShapeStyle(.secondary))
                                         : AnyShapeStyle(.tertiary))
                        .frame(width: 22, alignment: .leading)
                        .accessibilityLabel(check.isChecked ? "Coché" : "Non coché")
                }
                Text(timeLabel)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 44, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title ?? "Untitled")
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        // Uses the (source, detectedApp) pair so Slack huddles
                        // don't render as MEET.
                        SourceBadge(meeting: meeting)
                        if let status {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Self.dotColor(status.kind))
                                    .frame(width: 5, height: 5)
                                Text(status.label)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.leading, 2)
                }
                Spacer(minLength: 0)
                if let onStop {
                    // Plain Button, not part of the row's own button: SwiftUI
                    // resolves the tap to the innermost button, so stopping
                    // does not also re-select the row.
                    Button(action: onStop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.red)
                            .padding(2)
                            .hoverHighlight(cornerRadius: 10)
                    }
                    .buttonStyle(.plain)
                    .help("Arrêter l'enregistrement")
                    .accessibilityLabel("Arrêter l'enregistrement")
                } else if let dur = durationLabel {
                    Text(dur)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 7).padding(.horizontal, 10)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// `slash.circle` for a row that cannot be ticked: the reason is the same
    /// one that greys out "Supprimer…" in the context menu (recording or
    /// pipeline running), and a plain empty circle would look merely unticked.
    private func checkSymbol(_ c: Check) -> String {
        guard c.enabled else { return "slash.circle" }
        return c.isChecked ? "checkmark.circle.fill" : "circle"
    }

    static func dotColor(_ kind: ViewerStore.RowStatusKind) -> Color {
        switch kind {
        case .recording:  return .red
        case .processing: return .orange
        case .waiting:    return .gray
        case .failed:     return .red
        }
    }

    private var timeLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(meeting.startedAt) || cal.isDateInYesterday(meeting.startedAt) {
            return Self.timeFmt.string(from: meeting.startedAt)
        }
        return Self.dayFmt.string(from: meeting.startedAt)
    }

    /// Task 27 populates this from the meeting metadata; `MeetingListing` does
    /// not carry a duration yet.
    private var durationLabel: String? { nil }

    @ViewBuilder private var rowBackground: some View {
        if selected {
            HStack(spacing: 0) {
                Rectangle().fill(Color.accentColor).frame(width: 2)
                Rectangle().fill(Color.accentColor.opacity(0.10))
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if hovering {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6))
        } else {
            Color.clear
        }
    }
}
