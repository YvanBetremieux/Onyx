import XCTest
import GRDB
@testable import RecorderCore

final class RescanRunnerTests: XCTestCase {
    func testRescanRebuildsFromFolder() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rescan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("idx.sqlite")

        let storage = MeetingStorage(root: root.appendingPathComponent("Meetings"))
        let paths = try storage.createMeeting(startedAt: Date(timeIntervalSince1970: 1_784_819_535))
        try AtomicJSON.write([TranscriptSegment(start: 0, end: 1, speaker: "MOI", text: "hey")],
                             to: paths.transcriptJson)
        var job = try storage.loadJob(paths); job.state = .done
        try storage.saveJob(job, at: paths)

        let indexer = try MeetingIndexer(dbPath: dbPath)
        let runner = RescanRunner(storage: storage, indexer: indexer)
        try await runner.rescan()

        let count = try await indexer.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meetings") ?? 0
        }
        XCTAssertEqual(count, 1)
    }

    // MARK: - Helpers

    private func makeRoot(_ label: String) -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rescan-\(label)-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// Creates a database that only knows the v1 schema (no `start_ms` on the
    /// FTS table, no `source` / `detected_app` on `meetings`) and seeds it with
    /// one legacy row for `meetingId`, already marked as indexed.
    private func seedLegacyV1Database(at dbPath: URL, meetingId: String) throws {
        try FileManager.default.createDirectory(at: dbPath.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Scoped so the pool is released (and the file closed) before the real
        // MeetingIndexer opens the same path.
        let writer = try DatabasePool(path: dbPath.path)
        var v1 = DatabaseMigrator()
        v1.registerMigration("v1") { db in
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
        try v1.migrate(writer)
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO meetings(id, path, started_at, title, transcript_state, indexed_at)
                VALUES (?, '/legacy/path', '2026-01-01T00:00:00Z', 'legacy title', 'done',
                        '2026-01-02T00:00:00Z')
                """, arguments: [meetingId])
            try db.execute(sql: """
                INSERT INTO transcripts_fts(meeting_id, speaker, text)
                VALUES (?, 'MOI', 'legacy segment')
                """, arguments: [meetingId])
        }
        try writer.close()
    }

    // MARK: - Backfill

    /// The real point of Task 25: a database written before schema v2/v3 has no
    /// `start_ms` and no `source`. The migrations null out `indexed_at`; the
    /// rescan must then repopulate both from the on-disk meeting folder.
    func test_rescan_backfillsStartMsAndSourceOnLegacyDatabase() async throws {
        let root = makeRoot("backfill")
        let dbPath = root.appendingPathComponent("idx.sqlite")
        let storage = MeetingStorage(root: root.appendingPathComponent("Meetings"))

        let paths = try storage.createMeeting(startedAt: Date(timeIntervalSince1970: 1_784_819_535))
        let slug = paths.root.lastPathComponent
        try storage.patchMetadata({ m in
            m.title = "Weekly"
            m.source = .detected
            m.detectedApp = "slack_huddle"
        }, at: paths)
        try AtomicJSON.write([TranscriptSegment(start: 12.5, end: 14, speaker: "MOI",
                                                text: "backfilled segment")],
                             to: paths.transcriptJson)
        var job = try storage.loadJob(paths); job.state = .done
        try storage.saveJob(job, at: paths)

        try seedLegacyV1Database(at: dbPath, meetingId: slug)

        // Opening the indexer runs the v2 + v3 migrations (indexed_at -> NULL).
        let indexer = try MeetingIndexer(dbPath: dbPath)
        try await indexer.reader.read { db in
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT source FROM meetings") ?? nil,
                         "precondition: legacy row has no source yet")
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT indexed_at FROM meetings") ?? nil,
                         "precondition: migration marks the row stale")
        }

        try await RescanRunner(storage: storage, indexer: indexer).rescan()

        try await indexer.reader.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT source FROM meetings"), "detected")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT detected_app FROM meetings"),
                           "slack_huddle")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT title FROM meetings"), "Weekly")
            XCTAssertNotNil(try String.fetchOne(db, sql: "SELECT indexed_at FROM meetings") ?? nil)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT start_ms FROM transcripts_fts"), 12_500)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcripts_fts"), 1,
                           "the stale FTS row must be replaced, not duplicated")
        }

        // And the listing surface exposes the backfilled source.
        let listings = try indexer.listAllGrouped()
        XCTAssertEqual(listings.count, 1)
        XCTAssertEqual(listings[0].source, .detected)
        XCTAssertEqual(listings[0].detectedApp, "slack_huddle")
    }

    /// Running the rescan twice must be a no-op the second time (no duplicated
    /// meetings, no duplicated FTS rows).
    func test_rescan_isIdempotent() async throws {
        let root = makeRoot("idem")
        let dbPath = root.appendingPathComponent("idx.sqlite")
        let storage = MeetingStorage(root: root.appendingPathComponent("Meetings"))
        let paths = try storage.createMeeting(startedAt: Date(timeIntervalSince1970: 1_784_819_535))
        try AtomicJSON.write([TranscriptSegment(start: 1, end: 2, speaker: "MOI", text: "un"),
                              TranscriptSegment(start: 3, end: 4, speaker: "A", text: "deux")],
                             to: paths.transcriptJson)

        let indexer = try MeetingIndexer(dbPath: dbPath)
        let runner = RescanRunner(storage: storage, indexer: indexer)
        try await runner.rescan()
        try await runner.rescan()

        try await indexer.reader.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meetings"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcripts_fts"), 2)
        }
    }

    // MARK: - Staleness

    /// Boot path: `onlyStale` must skip meetings whose row is already fresh
    /// (non-null `indexed_at` *and* a non-null `source`), so a normal launch
    /// doesn't re-read every transcript on disk.
    func test_rescanOnlyStale_skipsAlreadyIndexedMeetings() async throws {
        let root = makeRoot("stale")
        let dbPath = root.appendingPathComponent("idx.sqlite")
        let storage = MeetingStorage(root: root.appendingPathComponent("Meetings"))
        let paths = try storage.createMeeting(startedAt: Date(timeIntervalSince1970: 1_784_819_535))
        try AtomicJSON.write([TranscriptSegment(start: 0, end: 1, speaker: "MOI", text: "hey")],
                             to: paths.transcriptJson)
        // Freshness requires a terminal state: an in_progress row is always
        // revisited at boot (see test below), so finish this meeting first.
        var job = try storage.loadJob(paths)
        job.state = .done
        try storage.saveJob(job, at: paths)

        let indexer = try MeetingIndexer(dbPath: dbPath)
        let runner = RescanRunner(storage: storage, indexer: indexer)
        XCTAssertTrue(try runner.needsRescan(), "nothing indexed yet")
        try await runner.rescan(onlyStale: true)
        XCTAssertFalse(try runner.needsRescan())

        // Change the transcript on disk, then ask for a stale-only rescan: the
        // meeting is fresh in the index, so the change must NOT be picked up.
        try AtomicJSON.write([TranscriptSegment(start: 0, end: 1, speaker: "MOI", text: "hey"),
                              TranscriptSegment(start: 2, end: 3, speaker: "MOI", text: "encore")],
                             to: paths.transcriptJson)
        try await runner.rescan(onlyStale: true)
        try await indexer.reader.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcripts_fts"), 1,
                           "stale-only rescan must have skipped the fresh meeting")
        }

        // A full rescan (the default, used by the manual "Reindex" action) does
        // pick it up.
        try await runner.rescan()
        try await indexer.reader.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcripts_fts"), 2)
        }
    }

    /// A row indexed while the meeting's pipeline was still running must be
    /// revisited at boot: if the app was killed mid-pipeline, the resume path
    /// finishes the work on disk, and the boot backfill is the safety net that
    /// keeps the sidebar from saying "waiting for transcription" forever.
    func test_rescanOnlyStale_revisitsInProgressRows() async throws {
        let root = makeRoot("stale-inprogress")
        let dbPath = root.appendingPathComponent("idx.sqlite")
        let storage = MeetingStorage(root: root.appendingPathComponent("Meetings"))
        let paths = try storage.createMeeting(startedAt: Date(timeIntervalSince1970: 1_784_819_535))
        try AtomicJSON.write([TranscriptSegment(start: 0, end: 1, speaker: "MOI", text: "hey")],
                             to: paths.transcriptJson)

        let indexer = try MeetingIndexer(dbPath: dbPath)
        let runner = RescanRunner(storage: storage, indexer: indexer)
        // Indexed mid-pipeline: job.json is still at its initial .recording state.
        try await runner.rescan(onlyStale: true)
        try await indexer.reader.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT transcript_state FROM meetings"),
                           "in_progress")
        }

        // The pipeline finishes on disk without anyone reindexing (app killed),
        // then the next boot's stale-only rescan must pick the change up.
        try storage.patchMetadata({ $0.title = "Titre enfin là" }, at: paths)
        var job = try storage.loadJob(paths)
        job.state = .done
        try storage.saveJob(job, at: paths)
        XCTAssertTrue(try runner.needsRescan(), "in_progress row must count as stale")
        try await runner.rescan(onlyStale: true)

        try await indexer.reader.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT transcript_state FROM meetings"),
                           "done")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT title FROM meetings"),
                           "Titre enfin là")
        }
    }

    /// A legacy row has `indexed_at` nulled by the migration → stale-only must
    /// still visit it.
    func test_rescanOnlyStale_visitsLegacyRows() async throws {
        let root = makeRoot("stale-legacy")
        let dbPath = root.appendingPathComponent("idx.sqlite")
        let storage = MeetingStorage(root: root.appendingPathComponent("Meetings"))
        let paths = try storage.createMeeting(startedAt: Date(timeIntervalSince1970: 1_784_819_535))
        let slug = paths.root.lastPathComponent
        try storage.patchMetadata({ $0.source = .calendar }, at: paths)
        try AtomicJSON.write([TranscriptSegment(start: 5, end: 6, speaker: "MOI", text: "ok")],
                             to: paths.transcriptJson)
        try seedLegacyV1Database(at: dbPath, meetingId: slug)

        let indexer = try MeetingIndexer(dbPath: dbPath)
        let runner = RescanRunner(storage: storage, indexer: indexer)
        XCTAssertTrue(try runner.needsRescan())
        try await runner.rescan(onlyStale: true)

        try await indexer.reader.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT source FROM meetings"), "calendar")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT start_ms FROM transcripts_fts"), 5_000)
        }
    }

    // MARK: - Robustness

    /// One unreadable `meta.json` must not abort the rescan nor wipe the rows of
    /// the healthy meetings.
    func test_rescan_corruptMetadataDoesNotWipeOtherMeetings() async throws {
        let root = makeRoot("corrupt")
        let dbPath = root.appendingPathComponent("idx.sqlite")
        let storage = MeetingStorage(root: root.appendingPathComponent("Meetings"))

        let bad = try storage.createMeeting(startedAt: Date(timeIntervalSince1970: 1_784_819_535))
        // Slug granularity is 1 minute; +120 s guarantees a distinct folder.
        let good = try storage.createMeeting(startedAt: Date(timeIntervalSince1970: 1_784_819_655))
        try storage.patchMetadata({ $0.title = "Good" }, at: good)
        try AtomicJSON.write([TranscriptSegment(start: 0, end: 1, speaker: "MOI", text: "survivor")],
                             to: good.transcriptJson)
        try Data("{ not json".utf8).write(to: bad.meta, options: .atomic)

        let indexer = try MeetingIndexer(dbPath: dbPath)
        try await RescanRunner(storage: storage, indexer: indexer).rescan()

        let listings = try indexer.listAllGrouped()
        XCTAssertEqual(listings.count, 1, "the corrupt meeting is skipped, the healthy one indexed")
        XCTAssertEqual(listings[0].title, "Good")
    }
}
