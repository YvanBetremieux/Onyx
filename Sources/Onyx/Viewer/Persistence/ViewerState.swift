import Foundation

/// Persisted snapshot of the viewer window (position/size handled by
/// NSWindowController's frameAutosaveName). Written to disk with a small
/// debounce on every user-visible change.
public struct ViewerState: Codable, Equatable {
    public var lastMeetingId: String?
    public var activeNoteLevel: String        // "live" | "brief" | "synthese" | "detaillee"
    public var notesToTranscriptRatio: Double // 0.3...0.85 of the main area
    public var transcriptPanelHidden: Bool
    public var lastSearchQuery: String
    /// Meetings whose *generated* notes have already been opened once — used to
    /// land on Synthèse only the first time. Optional so state files written
    /// before this field existed still decode instead of resetting everything.
    public var openedNoteMeetingIds: [String]?

    public init(lastMeetingId: String? = nil,
                activeNoteLevel: String = "synthese",
                notesToTranscriptRatio: Double = 0.6,
                transcriptPanelHidden: Bool = false,
                lastSearchQuery: String = "",
                openedNoteMeetingIds: [String]? = nil) {
        self.lastMeetingId = lastMeetingId
        self.activeNoteLevel = activeNoteLevel
        self.notesToTranscriptRatio = notesToTranscriptRatio
        self.transcriptPanelHidden = transcriptPanelHidden
        self.lastSearchQuery = lastSearchQuery
        self.openedNoteMeetingIds = openedNoteMeetingIds
    }
}
