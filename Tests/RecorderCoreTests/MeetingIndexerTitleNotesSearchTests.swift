import XCTest
@testable import RecorderCore

/// Search must cover meeting titles and note bodies, word-by-word (prefix
/// match, diacritic-insensitive) — not exact-phrase only.
final class MeetingIndexerTitleNotesSearchTests: XCTestCase {
    private var indexer: MeetingIndexer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        indexer = try MeetingIndexer.inMemory()
    }

    private func meta(id: String, title: String?) -> MeetingMetadata {
        MeetingMetadata(id: id, startedAt: Date(), title: title,
                        appVersion: "t", models: .init(whisper: "w", diarization: "d"))
    }

    private func upsert(id: String, title: String?,
                        transcript: [TranscriptSegment] = [],
                        notes: [(kind: String, text: String)] = []) throws {
        try indexer.upsert(meta: meta(id: id, title: title),
                           folderPath: URL(fileURLWithPath: "/tmp/\(id)"),
                           transcriptState: "done", transcript: transcript,
                           notes: notes)
    }

    func test_singleWordMatchesInsideTitle_notExactPhrase() throws {
        try upsert(id: "2026-08-02_10h00", title: "Salle de réunion : budget 2026")
        let hits = try indexer.search("budget")
        XCTAssertEqual(hits.map(\.meetingId), ["2026-08-02_10h00"])
        XCTAssertEqual(hits.first?.speaker, "Titre")
    }

    func test_titleMatch_isPrefixAndDiacriticInsensitive() throws {
        try upsert(id: "2026-08-02_11h00", title: "Préparation du séminaire produit")
        XCTAssertFalse(try indexer.search("prepa").isEmpty,
                       "\"prepa\" must prefix-match \"Préparation\" (accents folded)")
        XCTAssertFalse(try indexer.search("seminaire produit").isEmpty,
                       "multi-word queries AND their words, order-free")
        XCTAssertTrue(try indexer.search("budget").isEmpty)
    }

    func test_notesContentIsSearchable_withKindLabel() throws {
        try upsert(id: "2026-08-02_12h00", title: "Point RH",
                   notes: [(kind: "synthese", text: "Décision : embaucher un alternant."),
                           (kind: "live", text: "penser au badge parking")])
        let synth = try indexer.search("alternant")
        XCTAssertEqual(synth.count, 1)
        XCTAssertEqual(synth.first?.speaker, "Notes · synthèse")
        let live = try indexer.search("parking")
        XCTAssertEqual(live.first?.speaker, "Notes · direct")
    }

    func test_titleHitsComeBeforeTranscriptAndNoteHits() throws {
        try upsert(id: "2026-08-02_13h00", title: "Migration Salesforce",
                   transcript: [TranscriptSegment(start: 1, end: 2, speaker: "MOI",
                                                  text: "la migration avance bien")],
                   notes: [(kind: "brief", text: "migration : reste le sandbox")])
        let hits = try indexer.search("migration")
        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(hits.first?.speaker, "Titre")
        XCTAssertEqual(hits.last?.speaker, "Notes · brief")
    }

    func test_transcriptSearchStillWorks_andRenameUpdatesTitleIndex() throws {
        try upsert(id: "2026-08-02_14h00", title: nil,
                   transcript: [TranscriptSegment(start: 5, end: 6, speaker: "SPEAKER_00",
                                                  text: "le déploiement kubernetes")])
        XCTAssertEqual(try indexer.search("kubernetes").count, 1)

        try indexer.updateTitle(id: "2026-08-02_14h00", title: "Post-mortem infra")
        let hits = try indexer.search("post-mortem")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.speaker, "Titre")
        // Renaming again must replace, not accumulate.
        try indexer.updateTitle(id: "2026-08-02_14h00", title: "Rétro infra")
        XCTAssertTrue(try indexer.search("post-mortem").isEmpty)
    }

    func test_updateNote_replacesPreviousBody() throws {
        try upsert(id: "2026-08-02_15h00", title: "Weekly")
        try indexer.updateNote(id: "2026-08-02_15h00", kind: "live", text: "acheter un vidéoprojecteur")
        XCTAssertEqual(try indexer.search("vidéoprojecteur").count, 1)
        try indexer.updateNote(id: "2026-08-02_15h00", kind: "live", text: "rien à noter")
        XCTAssertTrue(try indexer.search("vidéoprojecteur").isEmpty)
    }
}
