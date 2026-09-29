import XCTest
import GRDB
@testable import RecorderCore

final class MeetingIndexerTests: XCTestCase {
    func testUpsertMeetingWritesRow() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("idx-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let indexer = try MeetingIndexer(dbPath: tmp)
        let started = Date(timeIntervalSince1970: 1_784_819_535)
        let meta = MeetingMetadata(id: "2026-07-22_14h32", startedAt: started,
                                   endedAt: nil, durationSeconds: 60, title: nil,
                                   source: .manual, appVersion: "0.1.0",
                                   models: .init(whisper: "large-v3", diarization: "sh-3.0"))
        try indexer.upsert(meta: meta, folderPath: URL(fileURLWithPath: "/tmp/x/2026-07-22_14h32"),
                           transcriptState: "done", transcript: [
            .init(start: 0, end: 1, speaker: "MOI", text: "bonjour"),
            .init(start: 1, end: 2, speaker: "SPEAKER_00", text: "salut"),
        ])
        let count = try indexer.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meetings") ?? 0
        }
        XCTAssertEqual(count, 1)
        let ftsCount = try indexer.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcripts_fts WHERE meeting_id = ?",
                             arguments: ["2026-07-22_14h32"]) ?? 0
        }
        XCTAssertEqual(ftsCount, 2)
    }
}
