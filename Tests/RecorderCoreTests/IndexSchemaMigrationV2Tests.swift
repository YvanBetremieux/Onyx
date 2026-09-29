import XCTest
import GRDB
@testable import RecorderCore

final class IndexSchemaMigrationV2Tests: XCTestCase {
    var dbPath: URL!

    override func setUp() {
        super.setUp()
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-idx-\(UUID().uuidString).sqlite")
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: dbPath)
        super.tearDown()
    }

    func test_v2_addsStartMsColumnToFts() throws {
        let writer = try DatabasePool(path: dbPath.path)
        try IndexSchema.migrator().migrate(writer)
        try writer.read { db in
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(transcripts_fts)")
                .compactMap { $0["name"] as String? }
            XCTAssertTrue(cols.contains("start_ms"),
                          "FTS table should have start_ms column after v2 migration")
        }
    }

    func test_v2_resetsIndexedAtToNullOnExistingMeetings() throws {
        // Simulate a pre-v2 DB by running only v1 first.
        let writer = try DatabasePool(path: dbPath.path)
        var v1Only = DatabaseMigrator()
        v1Only.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE meetings (
                    id TEXT PRIMARY KEY, path TEXT NOT NULL, started_at TEXT NOT NULL,
                    duration_seconds INTEGER, title TEXT, transcript_state TEXT,
                    indexed_at TEXT
                )
                """)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE transcripts_fts USING fts5(meeting_id, speaker, text)
                """)
        }
        try v1Only.migrate(writer)
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO meetings(id, path, started_at, indexed_at)
                VALUES ('m1', '/tmp', '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z')
                """)
            // Real FTS content under the v1 schema: the drop-and-recreate must
            // survive an already-populated index, not just an empty one.
            for i in 0..<3 {
                try db.execute(sql: """
                    INSERT INTO transcripts_fts(meeting_id, speaker, text)
                    VALUES ('m1', 'MOI', ?)
                    """, arguments: ["segment number \(i)"])
            }
        }
        XCTAssertEqual(try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM transcripts_fts")
        }, 3, "precondition: v1 FTS table is populated")

        // Now apply v2 on top.
        try IndexSchema.migrator().migrate(writer)
        let val = try writer.read { db in
            try String.fetchOne(db, sql: "SELECT indexed_at FROM meetings WHERE id='m1'")
        }
        XCTAssertNil(val ?? nil, "indexed_at should be NULL to trigger rescan")

        // Old FTS rows are intentionally discarded (RescanRunner repopulates),
        // but the table must be usable with the new 4-column schema.
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO transcripts_fts(meeting_id, speaker, text, start_ms)
                VALUES ('m1', 'MOI', 'rebuilt segment', 1234)
                """)
        }
        XCTAssertEqual(try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM transcripts_fts")
        }, 1, "table was rebuilt empty and accepts the new schema")
    }

    func test_migrator_isIdempotent() throws {
        let writer = try DatabasePool(path: dbPath.path)
        try IndexSchema.migrator().migrate(writer)
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO meetings(id, path, started_at)
                VALUES ('m1', '/tmp', '2026-01-01T00:00:00Z')
                """)
            try db.execute(sql: """
                INSERT INTO transcripts_fts(meeting_id, speaker, text, start_ms)
                VALUES ('m1', 'MOI', 'hello world', 0)
                """)
        }
        // Second run must be a no-op, not a re-drop of the FTS table.
        XCTAssertNoThrow(try IndexSchema.migrator().migrate(writer))

        try writer.read { db in
            let ftsCols = try Row.fetchAll(db, sql: "PRAGMA table_info(transcripts_fts)")
                .compactMap { $0["name"] as String? }
            XCTAssertEqual(ftsCols, ["meeting_id", "speaker", "text", "start_ms"])
            let meetingCols = try Row.fetchAll(db, sql: "PRAGMA table_info(meetings)")
                .compactMap { $0["name"] as String? }
            XCTAssertTrue(meetingCols.contains("indexed_at"))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM meetings"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM transcripts_fts"), 1,
                           "re-running the migrator must not wipe indexed content")
        }
    }

    // Updated by Task 20: v3 adds the `source` / `detected_app` columns.
    func test_currentVersion_is4() {
        XCTAssertEqual(IndexSchema.currentVersion, 4)
    }
}
