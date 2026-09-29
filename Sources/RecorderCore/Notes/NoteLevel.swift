import Foundation

public enum NoteLevel: String, Codable, CaseIterable, Sendable {
    /// `notes/live.md` — notes the *user* types during the meeting. Never a
    /// generation target: the pipeline `.notes` step and
    /// `ClaudeNoteGenerator` refuse it, and it is only ever injected into the
    /// prompt as *context*. It lives in this enum so the viewer's note tabs
    /// and `ViewerStore.activeNoteLevel` can enumerate uniformly.
    case live
    case brief
    case synthese
    case detaillee

    /// The levels Claude can actually generate. Use this — never `allCases` —
    /// anywhere the user picks a generation target (menus, settings pickers).
    public static var generatable: [NoteLevel] {
        allCases.filter { $0 != .live }
    }

    /// The level whose `claude -p` session carries title auto-detection.
    /// Richer levels give Claude more room to infer a good title, so synthèse
    /// wins over détaillée over brief — but any configured level qualifies:
    /// a brief-only config must still produce a title for wild meetings.
    public static func titleCarrier(among levels: [NoteLevel]) -> NoteLevel? {
        let priority: [NoteLevel] = [.synthese, .detaillee, .brief]
        return priority.first { levels.contains($0) }
    }
}
