import XCTest
@testable import RecorderCore

final class MeetingIndexerRecentTests: XCTestCase {

    private func makeMeta(id: String, startedAt: Date, title: String? = nil) -> MeetingMetadata {
        MeetingMetadata(
            id: id,
            startedAt: startedAt,
            endedAt: nil,
            durationSeconds: nil,
            title: title,
            source: .manual,
            appVersion: "0.1.0",
            models: .init(whisper: "large-v3", diarization: "sherpa-pyannote-3.0")
        )
    }

    func testRecentMeetingsReturnsMostRecentFirst() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-idx-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let idx = try MeetingIndexer(dbPath: dbURL)

        let earlier = makeMeta(id: "2026-07-27_10h00",
                               startedAt: Date(timeIntervalSince1970: 1),
                               title: "Earlier")
        let later = makeMeta(id: "2026-07-28_10h00",
                             startedAt: Date(timeIntervalSince1970: 2),
                             title: "Later")

        try idx.upsert(meta: earlier,
                       folderPath: URL(fileURLWithPath: "/tmp/e"),
                       transcriptState: "done", transcript: [])
        try idx.upsert(meta: later,
                       folderPath: URL(fileURLWithPath: "/tmp/l"),
                       transcriptState: "done", transcript: [])

        let listings = try idx.recentMeetings(limit: 5)
        XCTAssertEqual(listings.count, 2)
        XCTAssertEqual(listings.first?.id, "2026-07-28_10h00")
        XCTAssertEqual(listings.first?.title, "Later")
    }

    func testRecentMeetingsRespectsLimit() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-idx-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let idx = try MeetingIndexer(dbPath: dbURL)
        for i in 0..<10 {
            let meta = makeMeta(id: "m\(i)",
                                startedAt: Date(timeIntervalSince1970: TimeInterval(i)),
                                title: "t\(i)")
            try idx.upsert(meta: meta,
                           folderPath: URL(fileURLWithPath: "/tmp/m\(i)"),
                           transcriptState: "done", transcript: [])
        }
        let listings = try idx.recentMeetings(limit: 3)
        XCTAssertEqual(listings.count, 3)
        XCTAssertEqual(listings.map(\.id), ["m9", "m8", "m7"])
    }
}
