import XCTest
import GRDB
@testable import RecorderCore

final class MeetingIndexerStartMsTests: XCTestCase {
    var dbPath: URL!
    override func setUp() {
        super.setUp()
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-idx-\(UUID().uuidString).sqlite")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dbPath); super.tearDown() }

    func test_upsert_populatesStartMs() throws {
        let indexer = try MeetingIndexer(dbPath: dbPath)
        let meta = MeetingMetadata(
            id: "m1", startedAt: Date(), endedAt: nil, durationSeconds: 60,
            title: "Test", source: .manual, appVersion: "0.1.0",
            models: .init(whisper: "w", diarization: "d")
        )
        let seg = TranscriptSegment(start: 12.345, end: 15.0, speaker: "MOI",
                                    text: "hello world")
        try indexer.upsert(meta: meta, folderPath: URL(fileURLWithPath: "/tmp"),
                           transcriptState: "done", transcript: [seg])

        let rows = try indexer.reader.read { db in
            try Row.fetchAll(db,
                sql: "SELECT start_ms, text FROM transcripts_fts WHERE meeting_id = 'm1'")
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["start_ms"] as Int?, 12345)
        XCTAssertEqual(rows[0]["text"] as String?, "hello world")
    }
}
