import XCTest
import GRDB
@testable import RecorderCore

final class MeetingIndexerSourceTests: XCTestCase {
    var dbPath: URL!
    override func setUp() {
        super.setUp()
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-\(UUID().uuidString).sqlite")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dbPath); super.tearDown() }

    private func meta(_ id: String, source: MeetingMetadata.Source,
                      detectedApp: String? = nil) -> MeetingMetadata {
        MeetingMetadata(id: id, startedAt: Date(), endedAt: nil,
                        durationSeconds: 0, title: "T",
                        source: source, appVersion: "0.1.0",
                        models: .init(whisper: "w", diarization: "d"),
                        detectedApp: detectedApp)
    }

    func test_upsert_persistsSource_readableInListing() throws {
        let idx = try MeetingIndexer(dbPath: dbPath)
        try idx.upsert(meta: meta("m1", source: .detected),
                       folderPath: URL(fileURLWithPath: "/tmp/m1"),
                       transcriptState: "done", transcript: [])
        let all = try idx.listAllGrouped()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].source, .detected)
    }

    func test_upsert_persistsDetectedApp_soBadgeCanTellMeetFromHuddle() throws {
        let idx = try MeetingIndexer(dbPath: dbPath)
        try idx.upsert(meta: meta("m1", source: .detected, detectedApp: "meet"),
                       folderPath: URL(fileURLWithPath: "/tmp/m1"),
                       transcriptState: "done", transcript: [])
        try idx.upsert(meta: meta("m2", source: .detected, detectedApp: "slack_huddle"),
                       folderPath: URL(fileURLWithPath: "/tmp/m2"),
                       transcriptState: "done", transcript: [])
        let all = try idx.listAllGrouped()
        let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        XCTAssertEqual(byId["m1"]?.detectedApp, "meet")
        XCTAssertEqual(byId["m2"]?.detectedApp, "slack_huddle")
    }

    func test_recentMeetings_exposesSourceAndDetectedApp() throws {
        let idx = try MeetingIndexer(dbPath: dbPath)
        try idx.upsert(meta: meta("m1", source: .calendar),
                       folderPath: URL(fileURLWithPath: "/tmp/m1"),
                       transcriptState: "done", transcript: [])
        let recent = try idx.recentMeetings(limit: 5)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent[0].source, .calendar)
        XCTAssertNil(recent[0].detectedApp)
    }

    /// Re-upserting an existing row must overwrite the source, not keep the old one.
    func test_upsert_updatesSourceOnConflict() throws {
        let idx = try MeetingIndexer(dbPath: dbPath)
        try idx.upsert(meta: meta("m1", source: .manual),
                       folderPath: URL(fileURLWithPath: "/tmp/m1"),
                       transcriptState: "done", transcript: [])
        try idx.upsert(meta: meta("m1", source: .detected, detectedApp: "meet"),
                       folderPath: URL(fileURLWithPath: "/tmp/m1"),
                       transcriptState: "done", transcript: [])
        let all = try idx.listAllGrouped()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].source, .detected)
        XCTAssertEqual(all[0].detectedApp, "meet")
    }

    func test_currentVersion_is4() {
        XCTAssertEqual(IndexSchema.currentVersion, 4)
    }

    /// A real pre-v2 database (v1 schema only, populated) must migrate all the
    /// way to v3 without losing the meetings row, and must end up with the new
    /// columns while indexed_at is nulled so RescanRunner repopulates.
    func test_v3_migratesFromV1OnlyDatabase() throws {
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
                INSERT INTO meetings(id, path, started_at, title, indexed_at)
                VALUES ('m1', '/tmp/m1', '2026-01-01T00:00:00Z', 'old', '2026-01-02T00:00:00Z')
                """)
            try db.execute(sql: """
                INSERT INTO transcripts_fts(meeting_id, speaker, text)
                VALUES ('m1', 'MOI', 'legacy segment')
                """)
        }

        try IndexSchema.migrator().migrate(writer)

        try writer.read { db in
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(meetings)")
                .compactMap { $0["name"] as String? }
            XCTAssertTrue(cols.contains("source"))
            XCTAssertTrue(cols.contains("detected_app"))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM meetings"), 1,
                           "the meetings row must survive the v3 migration")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT title FROM meetings WHERE id='m1'"),
                           "old")
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT indexed_at FROM meetings WHERE id='m1'") ?? nil)
            // FTS shape must be untouched by v3.
            let ftsCols = try Row.fetchAll(db, sql: "PRAGMA table_info(transcripts_fts)")
                .compactMap { $0["name"] as String? }
            XCTAssertEqual(ftsCols, ["meeting_id", "speaker", "text", "start_ms"])
        }
    }

    /// Running the full migrator twice must not throw nor duplicate columns.
    func test_v3_isIdempotent() throws {
        let writer = try DatabasePool(path: dbPath.path)
        try IndexSchema.migrator().migrate(writer)
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO meetings(id, path, started_at, source)
                VALUES ('m1', '/tmp/m1', '2026-01-01T00:00:00Z', 'detected')
                """)
        }
        XCTAssertNoThrow(try IndexSchema.migrator().migrate(writer))
        try writer.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT source FROM meetings WHERE id='m1'"),
                           "detected")
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(meetings)")
                .compactMap { $0["name"] as String? }
            XCTAssertEqual(cols.filter { $0 == "source" }.count, 1)
        }
    }
}
