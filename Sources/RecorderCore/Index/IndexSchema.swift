import Foundation
import GRDB

public enum IndexSchema {
    public static let currentVersion = 4

    public static func migrator() -> DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS meetings (
                    id                TEXT PRIMARY KEY,
                    path              TEXT NOT NULL,
                    started_at        TEXT NOT NULL,
                    duration_seconds  INTEGER,
                    title             TEXT,
                    transcript_state  TEXT,
                    indexed_at        TEXT
                )
            """)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS transcripts_fts USING fts5(
                    meeting_id, speaker, text
                )
            """)
        }
        m.registerMigration("v2_fts_start_ms") { db in
            // FTS5 doesn't support ALTER TABLE ADD COLUMN. Drop + recreate,
            // then null out indexed_at so RescanRunner repopulates on next boot.
            //
            // Only `text` is indexed: `meeting_id` and `speaker` must be
            // UNINDEXED so a bare `transcripts_fts MATCH ?` can't match a
            // speaker label ("MOI") or a date fragment of a meeting-id slug
            // ("2026"). UNINDEXED columns are still stored, so they remain
            // readable in SELECTs and usable in ordinary WHERE clauses (e.g.
            // `DELETE FROM transcripts_fts WHERE meeting_id = ?`).
            // Column ORDER must stay (meeting_id, speaker, text, start_ms):
            // MeetingIndexer.search uses snippet(transcripts_fts, 2, …).
            try db.execute(sql: "DROP TABLE IF EXISTS transcripts_fts")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE transcripts_fts USING fts5(
                    meeting_id UNINDEXED, speaker UNINDEXED, text, start_ms UNINDEXED
                )
            """)
            try db.execute(sql: "UPDATE meetings SET indexed_at = NULL")
        }
        m.registerMigration("v3_meetings_source") { db in
            // `meetings` is a normal SQL table, so plain ADD COLUMN works — no
            // drop/recreate (it holds the only copy of indexed metadata between
            // rescans). The FTS table is deliberately left untouched here: its
            // column order and UNINDEXED markers are load-bearing.
            //
            // `detected_app` is stored alongside `source` because `.detected`
            // covers both Google Meet and Slack huddles; the sidebar badge needs
            // this second field to render MEET vs HUDDLE without a per-row read
            // of meta.json.
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN source TEXT")
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN detected_app TEXT")
            try db.execute(sql: "UPDATE meetings SET indexed_at = NULL")
        }
        m.registerMigration("v4_notes_fts") { db in
            // Search over titles and note bodies, not just transcripts.
            // One row per (meeting, kind) where kind ∈ {"title", "live",
            // "brief", "synthese", "detaillee"} — the title lives here too so
            // it gets FTS tokenization (diacritic-insensitive word matching),
            // which a LIKE on meetings.title cannot give.
            // Same UNINDEXED discipline as transcripts_fts: only `text` is
            // matchable; snippet() reads column 2.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
                    meeting_id UNINDEXED, kind UNINDEXED, text
                )
            """)
            try db.execute(sql: "UPDATE meetings SET indexed_at = NULL")
        }
        return m
    }
}
