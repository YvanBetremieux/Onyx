import SwiftUI
import RecorderCore

/// Title block at the top of the main panel: id + origin badge, title, the
/// regenerate action, then date / duration / participants.
struct MeetingHeaderView: View {
    let meeting: MeetingListing
    let duration: Int?
    /// Already-extracted initials — see `participantInitials(from:)`.
    let participants: [String]
    /// Whether "Régénérer notes" can do anything for the active note level.
    /// `ViewerStore.regenerateActiveNote()` refuses `.live` (those notes are the
    /// user's own), so without this the button was a silent no-op on the Direct
    /// tab. See `regenerateEnabled(for:)`.
    let regenerateEnabled: Bool
    let onRegenerate: () -> Void
    /// Commit of a manual title edit (empty string clears the title). Default
    /// keeps existing call sites and tests source-compatible.
    var onRename: (String) -> Void = { _ in }
    /// Parts of a manually merged meeting (`ViewerStore.currentMergedParts`),
    /// empty for an ordinary one. Drives the "N parties" badge.
    var mergedParts: [MeetingMetadata.MergedPart] = []

    /// Non-nil while the title is being edited; holds the draft text.
    @State private var titleDraft: String?
    @FocusState private var titleFieldFocused: Bool
    @State private var regenerateHovering = false

    /// Single source of truth for the header's regenerate affordance. Delegates
    /// to `NotesPanelRules.canRegenerate` so the button and the tab strip can
    /// never disagree about the `.live` invariant.
    static func regenerateEnabled(for level: NoteLevel) -> Bool {
        NotesPanelRules.canRegenerate(level)
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f
    }()

    // MARK: - Derived data

    /// Unique speakers in order of first appearance, as initials.
    static func participantInitials(from segments: [TranscriptSegment]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for s in segments {
            let key = s.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            if let i = AvatarStack.initials(for: key) { out.append(i) }
        }
        return out
    }

    /// "Partie 1 : 12 août 10h02 · Partie 2 : 12 août 13h59" — where each stretch
    /// of the timeline was actually recorded.
    private var mergedPartsTooltip: String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "fr_FR")
        fmt.dateFormat = "d MMM HH'h'mm"
        return mergedParts.enumerated()
            .map { "Partie \($0.offset + 1) : \(fmt.string(from: $0.element.startedAt))" }
            .joined(separator: "\n")
    }

    static func humanDuration(_ s: Int) -> String {
        let s = max(0, s)
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return String(format: "%dh%02d", s / 3600, (s % 3600) / 60)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(meeting.id)
                    .font(.system(size: 10.5, design: .monospaced))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("·").foregroundStyle(.tertiary)
                // Reuse the sidebar mapping: source alone can't tell Meet from
                // Slack huddle, `detectedApp` does.
                SourceBadge(meeting: meeting)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                titleView
                Spacer(minLength: 8)
                regenerateButton
            }
            // A draft in flight belongs to the meeting it was typed on: switching
            // meetings must drop it, not commit it onto the new selection.
            .onChange(of: meeting.id) { _ in titleDraft = nil }
            HStack(spacing: 10) {
                Text(Self.dateFmt.string(from: meeting.startedAt).capitalized)
                if let d = duration {
                    Text("·").foregroundStyle(.tertiary)
                    Text(Self.humanDuration(d))
                }
                if mergedParts.count > 1 {
                    Text("·").foregroundStyle(.tertiary)
                    // A merged meeting's timeline is several recordings butted
                    // together, so its own date/duration no longer tells the
                    // whole story — the parts' real times do, and they live only
                    // here and in transcript.md.
                    Text("\(mergedParts.count) parties")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.primary.opacity(0.07),
                                    in: Capsule())
                        .help(mergedPartsTooltip)
                }
                if !participants.isEmpty {
                    Spacer().frame(width: 4)
                    AvatarStack(initials: participants)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    /// The title, click-to-edit. The auto-detected title (huddles, meetings
    /// sauvages) is a starting point, never a lock: clicking it opens a plain
    /// TextField in the same type style, ⏎ commits, Échap annule.
    @ViewBuilder private var titleView: some View {
        if titleDraft != nil {
            TextField("Sans titre", text: Binding(
                get: { titleDraft ?? "" },
                set: { titleDraft = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 28, weight: .semibold))
            .kerning(-0.6)
            .focused($titleFieldFocused)
            .onSubmit {
                if let draft = titleDraft { onRename(draft) }
                titleDraft = nil
            }
            .onExitCommand { titleDraft = nil }
            .onAppear { titleFieldFocused = true }
        } else {
            Text(meeting.title ?? "Sans titre")
                .font(.system(size: 28, weight: .semibold))
                .kerning(-0.6)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(meeting.title == nil ? .secondary : .primary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .hoverHighlight()
                .padding(.horizontal, -6).padding(.vertical, -2)
                .contentShape(Rectangle())
                .onTapGesture { titleDraft = meeting.title ?? "" }
                .help("Cliquer pour renommer")
        }
    }

    private var regenerateButton: some View {
        Button(action: onRegenerate) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                Text("Régénérer notes")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(regenerateEnabled ? Color.accentColor : Color.gray,
                        in: RoundedRectangle(cornerRadius: 6))
            // Hover: lighten the accent fill — the quaternary highlight the
            // other controls use would be invisible on a filled button.
            .overlay(RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(regenerateHovering && regenerateEnabled ? 0.15 : 0)))
            // `.disabled` alone does not dim a `.plain` button with a custom
            // background, so the unavailability has to be drawn explicitly.
            .opacity(regenerateEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .onHover { regenerateHovering = $0 }
        .disabled(!regenerateEnabled)
        .help(regenerateEnabled
              ? "Régénérer la note active à partir du transcript"
              : "Les notes du direct sont les tiennes — elles ne sont jamais régénérées.")
    }
}
