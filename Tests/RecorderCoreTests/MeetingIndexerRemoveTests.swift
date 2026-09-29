import XCTest
import GRDB
@testable import RecorderCore

final class MeetingIndexerRemoveTests: XCTestCase {
    private func makeMeta(id: String, title: String) -> MeetingMetadata {
        MeetingMetadata(id: id, startedAt: Date(timeIntervalSince1970: 1_784_819_535),
                        endedAt: nil, durationSeconds: 60, title: title,
                        source: .manual, appVersion: "0.1.0",
                        models: .init(whisper: "large-v3", diarization: "sh-3.0"))
    }

    func testRemoveMeetingDropsRowAndSearchHits() throws {
        let indexer = try MeetingIndexer.inMemory()
        try indexer.upsert(meta: makeMeta(id: "2026-07-22_14h32", title: "Budget 2026"),
                           folderPath: URL(fileURLWithPath: "/tmp/x/2026-07-22_14h32"),
                           transcriptState: "done",
                           transcript: [.init(start: 0, end: 1, speaker: "MOI", text: "bonjour")],
                           notes: [(kind: "synthese", text: "le budget est validé")])
        try indexer.upsert(meta: makeMeta(id: "2026-07-23_09h00", title: "Point produit"),
                           folderPath: URL(fileURLWithPath: "/tmp/x/2026-07-23_09h00"),
                           transcriptState: "done",
                           transcript: [.init(start: 0, end: 1, speaker: "MOI", text: "bonjour")])

        try indexer.removeMeeting(id: "2026-07-22_14h32")

        // Listing no longer contains the removed meeting, the other survives.
        XCTAssertEqual(try indexer.listAllGrouped().map(\.id), ["2026-07-23_09h00"])
        // No ghost search hits from its transcript, notes or title.
        XCTAssertTrue(try indexer.search("budget").isEmpty)
        XCTAssertEqual(try indexer.search("bonjour").map(\.meetingId), ["2026-07-23_09h00"])
        // FTS tables hold no orphan rows for the removed id.
        let orphans = try indexer.reader.read { db in
            try Int.fetchOne(db, sql: """
                SELECT (SELECT COUNT(*) FROM transcripts_fts WHERE meeting_id = ?)
                     + (SELECT COUNT(*) FROM notes_fts WHERE meeting_id = ?)
                """, arguments: ["2026-07-22_14h32", "2026-07-22_14h32"]) ?? -1
        }
        XCTAssertEqual(orphans, 0)
    }

    func testRemoveMeetingUnknownIdIsANoOp() throws {
        let indexer = try MeetingIndexer.inMemory()
        XCTAssertNoThrow(try indexer.removeMeeting(id: "does-not-exist"))
    }
}
