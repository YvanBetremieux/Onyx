import XCTest
@testable import RecorderCore

final class MeetingIndexerSearchTests: XCTestCase {
    var dbPath: URL!
    var indexer: MeetingIndexer!

    override func setUp() {
        super.setUp()
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-idx-\(UUID().uuidString).sqlite")
        indexer = try! MeetingIndexer(dbPath: dbPath)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dbPath); super.tearDown() }

    private func upsert(id: String, title: String, startedAt: Date,
                        segments: [TranscriptSegment]) throws {
        let meta = MeetingMetadata(
            id: id, startedAt: startedAt, endedAt: nil, durationSeconds: nil,
            title: title, source: .manual, appVersion: "0.1.0",
            models: .init(whisper: "w", diarization: "d"))
        try indexer.upsert(meta: meta, folderPath: URL(fileURLWithPath: "/tmp/\(id)"),
                           transcriptState: "done", transcript: segments)
    }

    func test_search_returnsHitsWithTitleAndStart() throws {
        try upsert(id: "m1", title: "Debug pipeline",
                   startedAt: Date(timeIntervalSince1970: 100),
                   segments: [
                     TranscriptSegment(start: 3.5, end: 5.0, speaker: "MOI",
                                       text: "whisper hangs on first run")
                   ])
        let hits = try indexer.search("whisper", limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].meetingId, "m1")
        XCTAssertEqual(hits[0].title, "Debug pipeline")
        XCTAssertEqual(hits[0].speaker, "MOI")
        let ts = try XCTUnwrap(hits[0].approximateTimestamp)
        XCTAssertEqual(ts, 3.5, accuracy: 0.01)
    }

    func test_search_snippetContainsHighlightMarker() throws {
        try upsert(id: "m1", title: "T",
                   startedAt: Date(),
                   segments: [
                     TranscriptSegment(start: 0, end: 1, speaker: "MOI",
                                       text: "the whisper transcriber hangs")
                   ])
        let hits = try indexer.search("whisper", limit: 10)
        let plain = String(hits[0].snippet.characters)
        XCTAssertTrue(plain.lowercased().contains("whisper"),
                      "snippet should contain the matched term")
        // AttributedString: at least one run with background color set.
        var sawHighlight = false
        for run in hits[0].snippet.runs where run.backgroundColor != nil {
            sawHighlight = true
        }
        XCTAssertTrue(sawHighlight, "snippet should have highlighted runs")
    }

    func test_search_emptyQueryReturnsEmpty() throws {
        try upsert(id: "m1", title: "T", startedAt: Date(),
                   segments: [TranscriptSegment(start: 0, end: 1, speaker: "MOI",
                                                text: "hello")])
        XCTAssertEqual(try indexer.search("", limit: 10).count, 0)
        XCTAssertEqual(try indexer.search("   ", limit: 10).count, 0)
    }

    func test_search_specialCharsAreEscaped() throws {
        try upsert(id: "m1", title: "T", startedAt: Date(),
                   segments: [TranscriptSegment(start: 0, end: 1, speaker: "MOI",
                                                text: "quote'apostrophe")])
        // Must not throw; matches on tokenized "quote" or "apostrophe".
        XCTAssertEqual(try indexer.search("quote", limit: 10).count, 1,
                       "single token of the segment should match")
        XCTAssertEqual(try indexer.search("quote'apostrophe", limit: 10).count, 1,
                       "the apostrophe-separated phrase should still match as a phrase")
        XCTAssertEqual(try indexer.search("say \"hi\" OR", limit: 10).count, 0,
                       "FTS operators must be escaped into a literal phrase, matching nothing")
    }

    // MARK: - Only `text` is searchable (meeting_id / speaker are UNINDEXED)

    func test_search_doesNotMatchSpeakerName() throws {
        try upsert(id: "m1", title: "T", startedAt: Date(),
                   segments: [TranscriptSegment(start: 0, end: 1, speaker: "MOI",
                                                text: "bonjour tout le monde")])
        XCTAssertEqual(try indexer.search("MOI", limit: 10).count, 0,
                       "speaker column must not be searchable")
    }

    func test_search_doesNotMatchMeetingIdFragment() throws {
        try upsert(id: "2026-07-31_15h10", title: "T", startedAt: Date(),
                   segments: [TranscriptSegment(start: 0, end: 1, speaker: "MOI",
                                                text: "bonjour tout le monde")])
        XCTAssertEqual(try indexer.search("2026", limit: 10).count, 0,
                       "meeting_id column must not be searchable")
        XCTAssertEqual(try indexer.search("15h10", limit: 10).count, 0,
                       "meeting_id column must not be searchable")
    }

    func test_search_stillMatchesTranscriptText() throws {
        try upsert(id: "2026-07-31_15h10", title: "T", startedAt: Date(),
                   segments: [TranscriptSegment(start: 0, end: 1, speaker: "MOI",
                                                text: "bonjour tout le monde")])
        let hits = try indexer.search("monde", limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].meetingId, "2026-07-31_15h10")
        XCTAssertEqual(hits[0].speaker, "MOI",
                       "UNINDEXED columns are still stored and returned")
    }

    func test_search_respectsLimit() throws {
        let segs = (0..<10).map {
            TranscriptSegment(start: Double($0), end: Double($0) + 1,
                              speaker: "MOI", text: "widget number \($0)")
        }
        try upsert(id: "m1", title: "T", startedAt: Date(), segments: segs)
        XCTAssertEqual(try indexer.search("widget", limit: 100).count, 10)
        XCTAssertEqual(try indexer.search("widget", limit: 3).count, 3)
        XCTAssertEqual(try indexer.search("widget", limit: 1).count, 1)
    }
}
