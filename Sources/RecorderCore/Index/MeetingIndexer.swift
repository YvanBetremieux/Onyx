import Foundation
import GRDB

public struct MeetingListing: Equatable, Sendable {
    public let id: String
    public let startedAt: Date
    public let title: String?
    public let folderPath: URL
    public let transcriptState: String?

    public init(id: String, startedAt: Date, title: String?,
                folderPath: URL, transcriptState: String?) {
        self.id = id
        self.startedAt = startedAt
        self.title = title
        self.folderPath = folderPath
        self.transcriptState = transcriptState
    }
}

public final class MeetingIndexer {
    public let writer: DatabaseWriter
    public var reader: DatabaseReader { writer }

    public init(dbPath: URL) throws {
        try FileManager.default.createDirectory(at: dbPath.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        writer = try DatabasePool(path: dbPath.path)
        try IndexSchema.migrator().migrate(writer)
    }

    public func upsert(meta: MeetingMetadata, folderPath: URL,
                       transcriptState: String,
                       transcript: [TranscriptSegment]) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO meetings (id, path, started_at, duration_seconds, title,
                                       transcript_state, indexed_at)
                VALUES (?, ?, ?, ?, ?, ?, datetime('now'))
                ON CONFLICT(id) DO UPDATE SET
                    path=excluded.path,
                    started_at=excluded.started_at,
                    duration_seconds=excluded.duration_seconds,
                    title=excluded.title,
                    transcript_state=excluded.transcript_state,
                    indexed_at=excluded.indexed_at
                """,
                arguments: [meta.id, folderPath.path,
                            ISO8601DateFormatter().string(from: meta.startedAt),
                            meta.durationSeconds, meta.title,
                            transcriptState])
            try db.execute(sql: "DELETE FROM transcripts_fts WHERE meeting_id = ?",
                           arguments: [meta.id])
            for seg in transcript {
                try db.execute(sql: """
                    INSERT INTO transcripts_fts (meeting_id, speaker, text) VALUES (?, ?, ?)
                    """, arguments: [meta.id, seg.speaker, seg.text])
            }
        }
    }

    public func recentMeetings(limit: Int = 5) throws -> [MeetingListing] {
        try reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, path, started_at, title, transcript_state
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
                let started = ISO8601DateFormatter().date(from: startedAtStr) ?? Date(timeIntervalSince1970: 0)
                return MeetingListing(id: id, startedAt: started, title: title,
                                      folderPath: URL(fileURLWithPath: path),
                                      transcriptState: state)
            }
        }
    }
}
