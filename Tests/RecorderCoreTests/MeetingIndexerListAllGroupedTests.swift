import XCTest
@testable import RecorderCore

final class MeetingIndexerListAllGroupedTests: XCTestCase {
    var dbPath: URL!
    override func setUp() {
        super.setUp()
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-idx-\(UUID().uuidString).sqlite")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dbPath); super.tearDown() }

    func test_listAllGrouped_returnsAllOrderedByStartedAtDesc() throws {
        let indexer = try MeetingIndexer(dbPath: dbPath)
        let d1 = Date(timeIntervalSince1970: 100)
        let d2 = Date(timeIntervalSince1970: 200)
        let d3 = Date(timeIntervalSince1970: 300)
        for (i, d) in [d1, d2, d3].enumerated() {
            let meta = MeetingMetadata(id: "m\(i)", startedAt: d, endedAt: nil,
                                       durationSeconds: 0, title: "T\(i)",
                                       source: .manual, appVersion: "0.1.0",
                                       models: .init(whisper: "w", diarization: "d"))
            try indexer.upsert(meta: meta, folderPath: URL(fileURLWithPath: "/tmp/m\(i)"),
                               transcriptState: "done", transcript: [])
        }
        let all = try indexer.listAllGrouped()
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all[0].id, "m2")
        XCTAssertEqual(all[1].id, "m1")
        XCTAssertEqual(all[2].id, "m0")
    }
}
