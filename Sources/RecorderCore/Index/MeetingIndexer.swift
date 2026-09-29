import Foundation
import GRDB
import SwiftUI  // for AttributedString foregroundColor / backgroundColor

public struct MeetingListing: Equatable, Sendable {
    public let id: String
    public let startedAt: Date
    /// `var`: renames and auto-detected titles are patched into the in-memory
    /// listings directly (ViewerStore.applyTitle) instead of re-querying SQLite.
    public var title: String?
    public let folderPath: URL
    /// `var` for the same reason as `title`: live pipeline transitions are
    /// patched into the in-memory listings (ViewerStore.setPipelineState).
    public var transcriptState: String?
    /// How the recording was started. `nil` for rows indexed before schema v3
    /// (RescanRunner backfills them because v3 nulls out `indexed_at`).
    public let source: MeetingMetadata.Source?
    /// Raw `MeetingApp` rawValue ("meet" / "slack_huddle") when `source ==
    /// .detected`. Needed to distinguish Meet from Slack huddle, which
    /// `source` alone cannot express.
    public let detectedApp: String?

    public init(id: String, startedAt: Date, title: String?,
                folderPath: URL, transcriptState: String?,
                source: MeetingMetadata.Source? = nil,
                detectedApp: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.title = title
        self.folderPath = folderPath
        self.transcriptState = transcriptState
        self.source = source
        self.detectedApp = detectedApp
    }
}

public final class MeetingIndexer {
    private static let iso = ISO8601DateFormatter()

    public let writer: DatabaseWriter
    public var reader: DatabaseReader { writer }

    public init(dbPath: URL) throws {
        try FileManager.default.createDirectory(at: dbPath.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        writer = try DatabasePool(path: dbPath.path)
        try IndexSchema.migrator().migrate(writer)
    }

    /// Creates a transient in-memory indexer used as a fallback when the on-disk
    /// SQLite database is corrupt and cannot be recovered.
    public static func inMemory() throws -> MeetingIndexer {
        let queue = try DatabaseQueue()
        try IndexSchema.migrator().migrate(queue)
        return MeetingIndexer(writer: queue)
    }

    private init(writer: DatabaseWriter) {
        self.writer = writer
    }

    /// Title-only update, for renames and auto-detected titles. A no-op when
    /// the meeting has no index row yet (e.g. its pipeline hasn't finished):
    /// the eventual `upsert` from RescanRunner reads `meta.json`, which the
    /// caller updates first, so the title is not lost.
    public func updateTitle(id: String, title: String?) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE meetings SET title = ? WHERE id = ?",
                           arguments: [title, id])
            try Self.replaceNoteRow(db, meetingId: id, kind: "title", text: title)
        }
    }

    /// Replaces one meeting's note body in the search index — called after
    /// each (debounced) editor save so hand-written notes are searchable
    /// without waiting for a rescan. `kind` is a NoteLevel rawValue or "live".
    public func updateNote(id: String, kind: String, text: String?) throws {
        try writer.write { db in
            try Self.replaceNoteRow(db, meetingId: id, kind: kind, text: text)
        }
    }

    private static func replaceNoteRow(_ db: Database, meetingId: String,
                                       kind: String, text: String?) throws {
        try db.execute(sql: "DELETE FROM notes_fts WHERE meeting_id = ? AND kind = ?",
                       arguments: [meetingId, kind])
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }
        try db.execute(sql: "INSERT INTO notes_fts (meeting_id, kind, text) VALUES (?, ?, ?)",
                       arguments: [meetingId, kind, trimmed])
    }

    /// Removes a meeting's row and every search entry pointing at it, so a
    /// deleted meeting can neither be listed nor produce ghost search hits.
    /// Idempotent: an id with no index row (e.g. deleted before its pipeline
    /// finished) is a no-op.
    public func removeMeeting(id: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM transcripts_fts WHERE meeting_id = ?",
                           arguments: [id])
            try db.execute(sql: "DELETE FROM notes_fts WHERE meeting_id = ?",
                           arguments: [id])
        }
    }

    /// - Parameter notes: note bodies to index, as (kind, text) pairs where
    ///   kind is a NoteLevel rawValue or "live". The title is indexed
    ///   automatically from `meta.title`.
    public func upsert(meta: MeetingMetadata, folderPath: URL,
                       transcriptState: String,
                       transcript: [TranscriptSegment],
                       notes: [(kind: String, text: String)] = []) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO meetings (id, path, started_at, duration_seconds, title,
                                       transcript_state, indexed_at, source, detected_app)
                VALUES (?, ?, ?, ?, ?, ?, datetime('now'), ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    path=excluded.path,
                    started_at=excluded.started_at,
                    duration_seconds=excluded.duration_seconds,
                    title=excluded.title,
                    transcript_state=excluded.transcript_state,
                    indexed_at=excluded.indexed_at,
                    source=excluded.source,
                    detected_app=excluded.detected_app
                """,
                arguments: [meta.id, folderPath.path,
                            Self.iso.string(from: meta.startedAt),
                            meta.durationSeconds, meta.title,
                            transcriptState, meta.source.rawValue, meta.detectedApp])
            try db.execute(sql: "DELETE FROM transcripts_fts WHERE meeting_id = ?",
                           arguments: [meta.id])
            for seg in transcript {
                try db.execute(sql: """
                    INSERT INTO transcripts_fts (meeting_id, speaker, text, start_ms)
                    VALUES (?, ?, ?, ?)
                    """,
                    arguments: [meta.id, seg.speaker, seg.text,
                                Int((seg.start * 1000.0).rounded())])
            }
            try db.execute(sql: "DELETE FROM notes_fts WHERE meeting_id = ?",
                           arguments: [meta.id])
            try Self.replaceNoteRow(db, meetingId: meta.id, kind: "title",
                                    text: meta.title)
            for note in notes {
                try Self.replaceNoteRow(db, meetingId: meta.id, kind: note.kind,
                                        text: note.text)
            }
        }
    }

    public func recentMeetings(limit: Int = 5) throws -> [MeetingListing] {
        try reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, path, started_at, title, transcript_state, source, detected_app
                FROM meetings
                ORDER BY started_at DESC
                LIMIT ?
                """, arguments: [limit])
            return rows.map { row -> MeetingListing in
                let id: String = row["id"]
                let path: String = row["path"]
                let startedAtStr: String = row["started_at"]
                let title: String? = row["title"]
                let state: String? = row["transcript_state"]
                let sourceRaw: String? = row["source"]
                let started = Self.iso.date(from: startedAtStr) ?? Date(timeIntervalSince1970: 0)
                return MeetingListing(id: id, startedAt: started, title: title,
                                      folderPath: URL(fileURLWithPath: path),
                                      transcriptState: state,
                                      source: sourceRaw.flatMap(MeetingMetadata.Source.init(rawValue:)),
                                      detectedApp: row["detected_app"])
            }
        }
    }

    /// Returns every indexed meeting, most recent first. The "grouped" name
    /// signals intent: consumers (viewer sidebar) bucketize by date on the
    /// client side. This method just sorts and returns raw listings.
    public func listAllGrouped() throws -> [MeetingListing] {
        try reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, path, started_at, title, transcript_state, source, detected_app
                FROM meetings
                ORDER BY started_at DESC
                """)
            let iso = ISO8601DateFormatter()
            return rows.map { row in
                let sourceRaw = row["source"] as String?
                return MeetingListing(
                    id: row["id"] as String,
                    startedAt: iso.date(from: row["started_at"] as String)
                        ?? Date(timeIntervalSince1970: 0),
                    title: row["title"] as String?,
                    folderPath: URL(fileURLWithPath: row["path"] as String),
                    transcriptState: row["transcript_state"] as String?,
                    source: sourceRaw.flatMap(MeetingMetadata.Source.init(rawValue:)),
                    detectedApp: row["detected_app"] as String?
                )
            }
        }
    }

    /// Builds the FTS5 MATCH expression: each word of the user's query becomes
    /// a quoted prefix term (`"budget"* "sal"*`), joined with implicit AND.
    /// Word-level matching, NOT exact-phrase — "budget salle" finds a meeting
    /// titled "Salle de réunion : budget 2026". Quoting each token keeps FTS
    /// operators (`OR`, `-`, `NEAR`) inert in user input.
    static func ftsMatchExpression(_ rawQuery: String) -> String? {
        let tokens = rawQuery
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    /// Searches transcripts, meeting titles and note bodies. Title hits come
    /// first (the most direct kind of match), then transcript passages, then
    /// notes — each group in FTS rank order.
    public func search(_ rawQuery: String, limit: Int = 100) throws -> [SearchHit] {
        guard let match = Self.ftsMatchExpression(rawQuery) else { return [] }

        return try reader.read { db in
            let iso = ISO8601DateFormatter()
            func date(_ s: String?) -> Date {
                s.flatMap { iso.date(from: $0) } ?? Date(timeIntervalSince1970: 0)
            }

            // Titles + notes.
            let metaRows = try Row.fetchAll(db, sql: """
                SELECT
                  f.meeting_id  AS mid,
                  f.kind        AS kind,
                  snippet(notes_fts, 2, '<<<', '>>>', '…', 12) AS snip,
                  m.title       AS title,
                  m.started_at  AS started_at
                FROM notes_fts AS f
                JOIN meetings AS m ON m.id = f.meeting_id
                WHERE notes_fts MATCH ?
                ORDER BY rank
                LIMIT ?
                """, arguments: [match, limit])
            var titleHits: [SearchHit] = []
            var noteHits: [SearchHit] = []
            for row in metaRows {
                let kind: String = row["kind"] ?? ""
                let hit = SearchHit(
                    meetingId: row["mid"],
                    title: row["title"],
                    startedAt: date(row["started_at"]),
                    speaker: Self.noteKindLabel(kind),
                    snippet: Self.parseHighlightedSnippet(row["snip"] ?? ""),
                    approximateTimestamp: nil)
                if kind == "title" { titleHits.append(hit) } else { noteHits.append(hit) }
            }

            // Transcript passages.
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                  f.meeting_id  AS mid,
                  f.speaker     AS speaker,
                  f.start_ms    AS start_ms,
                  snippet(transcripts_fts, 2, '<<<', '>>>', '…', 12) AS snip,
                  m.title       AS title,
                  m.started_at  AS started_at
                FROM transcripts_fts AS f
                JOIN meetings AS m ON m.id = f.meeting_id
                WHERE transcripts_fts MATCH ?
                ORDER BY rank
                LIMIT ?
                """, arguments: [match, limit])
            let transcriptHits = rows.map { row -> SearchHit in
                let startMs: Int? = row["start_ms"]
                return SearchHit(
                    meetingId: row["mid"],
                    title: row["title"],
                    startedAt: date(row["started_at"]),
                    speaker: row["speaker"] ?? "",
                    snippet: Self.parseHighlightedSnippet(row["snip"] ?? ""),
                    approximateTimestamp: startMs.map { Double($0) / 1000.0 })
            }

            return Array((titleHits + transcriptHits + noteHits).prefix(limit))
        }
    }

    /// Label shown in the search row's speaker slot for non-transcript hits.
    static func noteKindLabel(_ kind: String) -> String {
        switch kind {
        case "title":     return "Titre"
        case "live":      return "Notes · direct"
        case "brief":     return "Notes · brief"
        case "synthese":  return "Notes · synthèse"
        case "detaillee": return "Notes · détaillée"
        default:          return "Notes"
        }
    }

    /// Parses `snippet(...)` output where matched terms are wrapped in
    /// `<<<...>>>` (chosen because they won't collide with real transcript
    /// content) into an `AttributedString` with a highlighted background.
    static func parseHighlightedSnippet(_ raw: String) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(raw)
        while let openRange = rest.range(of: "<<<") {
            let before = rest[rest.startIndex..<openRange.lowerBound]
            if !before.isEmpty {
                out.append(AttributedString(String(before)))
            }
            let afterOpen = rest[openRange.upperBound...]
            guard let closeRange = afterOpen.range(of: ">>>") else {
                out.append(AttributedString(String(afterOpen)))
                return out
            }
            let matched = afterOpen[afterOpen.startIndex..<closeRange.lowerBound]
            var attr = AttributedString(String(matched))
            attr.backgroundColor = .yellow
            attr.foregroundColor = .primary
            out.append(attr)
            rest = afterOpen[closeRange.upperBound...]
        }
        if !rest.isEmpty { out.append(AttributedString(String(rest))) }
        return out
    }
}
