import XCTest
@testable import RecorderCore

/// Manual merge of hand-picked meetings (sidebar checkbox selection).
///
/// The invariants worth pinning: parts are ordered by `startedAt` and butted
/// end-to-end against the *audio* length (not the metadata duration, or the
/// transcript drifts out of sync with what is heard), part 2's diarization
/// labels are namespaced so two unrelated "SPEAKER_00" are not read as one
/// person, and nothing user-written is dropped.
final class MeetingMergerTests: XCTestCase {

    /// Fixed durations per file, so no real audio decoding is needed.
    private struct FakeProbe: AudioDurationProbing {
        let byLastPathComponent: [String: Double]
        /// Keyed by slug when several meetings each have a `mic.m4a`.
        let bySlug: [String: Double]
        init(bySlug: [String: Double] = [:], byLastPathComponent: [String: Double] = [:]) {
            self.bySlug = bySlug
            self.byLastPathComponent = byLastPathComponent
        }
        func durationSeconds(of url: URL) async -> Double? {
            // …/<slug>/audio/<file>
            let slug = url.deletingLastPathComponent().deletingLastPathComponent()
                .lastPathComponent
            return bySlug[slug] ?? byLastPathComponent[url.lastPathComponent]
        }
    }

    private func makeStorage() throws -> MeetingStorage {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return MeetingStorage(root: root)
    }

    /// A finished meeting with a transcript, a non-empty `mic.m4a` stub (so the
    /// resolver finds audio and the probe is consulted) and optional live notes.
    @discardableResult
    private func makeMeeting(_ storage: MeetingStorage, start: Date,
                             title: String? = nil,
                             segments: [TranscriptSegment],
                             liveNotes: String? = nil,
                             durationSeconds: Int? = nil,
                             withAudio: Bool = true,
                             jobState: JobOverallState = .done) throws -> MeetingPaths {
        let paths = try storage.createMeeting(startedAt: start)
        try storage.patchMetadata({ m in
            m.title = title
            m.durationSeconds = durationSeconds
            m.endedAt = start.addingTimeInterval(Double(durationSeconds ?? 0))
        }, at: paths)
        try AtomicJSON.write(segments, to: paths.transcriptJson)
        if withAudio {
            try Data("stub".utf8).write(to: paths.micM4a)
        }
        if let liveNotes {
            try liveNotes.data(using: .utf8)!.write(to: paths.liveNotes)
        }
        var job = try storage.loadJob(paths)
        job.state = jobState
        try storage.saveJob(job, at: paths)
        return paths
    }

    private func merger(_ storage: MeetingStorage, probe: FakeProbe) -> MeetingMerger {
        MeetingMerger(storage: storage, notes: nil, probe: probe)
    }

    private let t0 = Date(timeIntervalSince1970: 1_784_800_000)

    // MARK: - Happy path

    func testMergeButtsPartsEndToEndAndNamespacesSpeakers() async throws {
        let storage = try makeStorage()
        let first = try makeMeeting(storage, start: t0, title: "Point produit", segments: [
            TranscriptSegment(start: 0, end: 5, speaker: "MOI", text: "un"),
            TranscriptSegment(start: 5, end: 9, speaker: "SPEAKER_00", text: "deux"),
        ])
        // Four hours later: with real offsets this would be 4 h of silence.
        let second = try makeMeeting(storage, start: t0.addingTimeInterval(14_400),
                                     segments: [
            TranscriptSegment(start: 0, end: 3, speaker: "MOI", text: "trois"),
            TranscriptSegment(start: 3, end: 7, speaker: "SPEAKER_00", text: "quatre"),
        ])
        let probe = FakeProbe(bySlug: [first.slug: 600, second.slug: 300])

        // Argument order deliberately reversed: order comes from startedAt.
        let result = try await merger(storage, probe: probe)
            .merge(slugs: [second.slug, first.slug])

        XCTAssertEqual(result.target, first.slug, "the oldest meeting carries the merge")
        XCTAssertEqual(result.absorbed, [second.slug])
        XCTAssertEqual(result.durationSeconds, 900, "600s + 300s, no gap")
        XCTAssertEqual(result.parts.map(\.offsetSeconds), [0, 600])

        let merged = try AtomicJSON.read([TranscriptSegment].self, from: first.transcriptJson)
        XCTAssertEqual(merged.map(\.text), ["un", "deux", "trois", "quatre"])
        XCTAssertEqual(merged.map(\.start), [0, 5, 600, 603],
                       "part 2 is shifted by part 1's audio length exactly")
        XCTAssertEqual(merged.map(\.speaker),
                       ["MOI", "SPEAKER_00", "MOI", "SPEAKER_00 (2)"],
                       "MOI is the same person throughout; remote labels are per-part")
    }

    func testAbsorbedPartIsHiddenButItsFolderIsKept() async throws {
        let storage = try makeStorage()
        let first = try makeMeeting(storage, start: t0, segments: [])
        let second = try makeMeeting(storage, start: t0.addingTimeInterval(3600), segments: [])
        let probe = FakeProbe(bySlug: [first.slug: 100, second.slug: 50])

        _ = try await merger(storage, probe: probe).merge(slugs: [first.slug, second.slug])

        let childMeta = try storage.loadMetadata(second)
        XCTAssertEqual(childMeta.absorbed, true, "hidden from the index and the sidebar")
        XCTAssertEqual(childMeta.mergedInto, first.slug)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.root.path),
                      "the folder must stay: the merged audio is played from it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.micM4a.path))
    }

    func testCarrierMetadataCoversEveryPart() async throws {
        let storage = try makeStorage()
        let first = try makeMeeting(storage, start: t0, title: "Point produit",
                                    segments: [], durationSeconds: 610)
        let secondStart = t0.addingTimeInterval(7200)
        let second = try makeMeeting(storage, start: secondStart, title: "Suite",
                                     segments: [], durationSeconds: 305)
        let probe = FakeProbe(bySlug: [first.slug: 600, second.slug: 300])

        _ = try await merger(storage, probe: probe).merge(slugs: [first.slug, second.slug])

        let meta = try storage.loadMetadata(first)
        XCTAssertEqual(meta.durationSeconds, 900)
        XCTAssertEqual(meta.endedAt, secondStart.addingTimeInterval(305),
                       "the merged meeting ends when its last part ended")
        XCTAssertEqual(meta.title, "Point produit",
                       "a merge is a repair, not a rename")
        XCTAssertEqual(meta.mergedParts?.map(\.slug), [first.slug, second.slug])
        XCTAssertEqual(meta.mergedParts?.map(\.startedAt), [t0, secondStart],
                       "each part keeps its real recording time for the UI")
    }

    func testTranscriptMarkdownCarriesAPartHeading() async throws {
        let storage = try makeStorage()
        let first = try makeMeeting(storage, start: t0, segments: [
            TranscriptSegment(start: 0, end: 5, speaker: "MOI", text: "un"),
        ])
        let second = try makeMeeting(storage, start: t0.addingTimeInterval(14_400),
                                     title: "Suite", segments: [
            TranscriptSegment(start: 0, end: 3, speaker: "MOI", text: "deux"),
        ])
        let probe = FakeProbe(bySlug: [first.slug: 600, second.slug: 300])

        _ = try await merger(storage, probe: probe).merge(slugs: [first.slug, second.slug])

        let md = try String(contentsOf: first.transcriptMd, encoding: .utf8)
        XCTAssertTrue(md.contains("### Partie 2"), md)
        XCTAssertTrue(md.contains("Suite"), "the part's own title helps place it")
        let heading = try XCTUnwrap(md.range(of: "### Partie 2"))
        let un = try XCTUnwrap(md.range(of: "un"))
        let deux = try XCTUnwrap(md.range(of: "deux"))
        XCTAssertTrue(un.lowerBound < heading.lowerBound,
                      "the heading separates part 1 from part 2")
        XCTAssertTrue(heading.lowerBound < deux.lowerBound)
    }

    func testLiveNotesOfEveryPartAreKept() async throws {
        let storage = try makeStorage()
        let first = try makeMeeting(storage, start: t0, segments: [],
                                    liveNotes: "mes notes du matin")
        let second = try makeMeeting(storage, start: t0.addingTimeInterval(7200),
                                     segments: [], liveNotes: "mes notes de l'aprem")
        let probe = FakeProbe(bySlug: [first.slug: 100, second.slug: 50])

        _ = try await merger(storage, probe: probe).merge(slugs: [first.slug, second.slug])

        let live = try String(contentsOf: first.liveNotes, encoding: .utf8)
        XCTAssertTrue(live.contains("mes notes du matin"), live)
        XCTAssertTrue(live.contains("mes notes de l'aprem"), live)
        XCTAssertTrue(live.contains("Partie 2"), "with a heading, not silently glued")
    }

    /// A part with no playable audio still needs a slot, or the next part's
    /// transcript would land on top of it.
    func testPartWithoutAudioFallsBackToItsRecordedDuration() async throws {
        let storage = try makeStorage()
        let first = try makeMeeting(storage, start: t0, segments: [],
                                    durationSeconds: 420, withAudio: false)
        let second = try makeMeeting(storage, start: t0.addingTimeInterval(7200),
                                     segments: [
            TranscriptSegment(start: 0, end: 3, speaker: "MOI", text: "deux"),
        ])
        let probe = FakeProbe(bySlug: [second.slug: 300])

        let result = try await merger(storage, probe: probe)
            .merge(slugs: [first.slug, second.slug])

        XCTAssertEqual(result.parts.map(\.offsetSeconds), [0, 420])
        let merged = try AtomicJSON.read([TranscriptSegment].self, from: first.transcriptJson)
        XCTAssertEqual(merged.first?.start, 420)
    }

    // MARK: - Extending a merge

    func testAnExistingMergeCanBeExtendedWithoutMovingItsParts() async throws {
        let storage = try makeStorage()
        let a = try makeMeeting(storage, start: t0, segments: [
            TranscriptSegment(start: 0, end: 5, speaker: "MOI", text: "a"),
        ])
        let b = try makeMeeting(storage, start: t0.addingTimeInterval(3600), segments: [
            TranscriptSegment(start: 0, end: 5, speaker: "MOI", text: "b"),
        ])
        let c = try makeMeeting(storage, start: t0.addingTimeInterval(7200), segments: [
            TranscriptSegment(start: 0, end: 5, speaker: "MOI", text: "c"),
        ])
        let probe = FakeProbe(bySlug: [a.slug: 100, b.slug: 200, c.slug: 300])
        let m = merger(storage, probe: probe)

        _ = try await m.merge(slugs: [a.slug, b.slug])
        let second = try await m.merge(slugs: [a.slug, c.slug])

        XCTAssertEqual(second.parts.map(\.slug), [a.slug, b.slug, c.slug])
        XCTAssertEqual(second.parts.map(\.offsetSeconds), [0, 100, 300],
                       "the first merge's offsets are frozen; c queues after both")
        let merged = try AtomicJSON.read([TranscriptSegment].self, from: a.transcriptJson)
        XCTAssertEqual(merged.map(\.text), ["a", "b", "c"])
        XCTAssertEqual(merged.map(\.start), [0, 100, 300],
                       "b's segments must not be shifted a second time")
    }

    // MARK: - Refusals

    func testRefusesFewerThanTwoDistinctMeetings() async throws {
        let storage = try makeStorage()
        let a = try makeMeeting(storage, start: t0, segments: [])
        let probe = FakeProbe(bySlug: [a.slug: 100])
        do {
            _ = try await merger(storage, probe: probe).merge(slugs: [a.slug, a.slug])
            XCTFail("a meeting cannot be merged with itself")
        } catch {
            XCTAssertEqual(error as? MeetingMerger.MergeError, .needsAtLeastTwoMeetings)
        }
    }

    func testRefusesAMeetingWhosePipelineHasNotFinished() async throws {
        let storage = try makeStorage()
        let a = try makeMeeting(storage, start: t0, segments: [])
        let b = try makeMeeting(storage, start: t0.addingTimeInterval(3600),
                                segments: [], jobState: .transcribing)
        let probe = FakeProbe(bySlug: [a.slug: 100, b.slug: 200])
        do {
            _ = try await merger(storage, probe: probe).merge(slugs: [a.slug, b.slug])
            XCTFail("merging under a running pipeline would lose the transcript")
        } catch {
            XCTAssertEqual(error as? MeetingMerger.MergeError, .notFinished(b.slug))
        }
        XCTAssertNil(try storage.loadMetadata(a).mergedParts,
                     "a refused merge must change nothing")
    }

    func testRefusesAlreadyAbsorbedMeeting() async throws {
        let storage = try makeStorage()
        let a = try makeMeeting(storage, start: t0, segments: [])
        let b = try makeMeeting(storage, start: t0.addingTimeInterval(3600), segments: [])
        let c = try makeMeeting(storage, start: t0.addingTimeInterval(7200), segments: [])
        let probe = FakeProbe(bySlug: [a.slug: 100, b.slug: 200, c.slug: 300])
        let m = merger(storage, probe: probe)
        _ = try await m.merge(slugs: [a.slug, b.slug])
        do {
            _ = try await m.merge(slugs: [b.slug, c.slug])
            XCTFail("b now lives inside a")
        } catch {
            XCTAssertEqual(error as? MeetingMerger.MergeError, .alreadyMerged(b.slug))
        }
    }

    /// A merged meeting may be extended (it stays the carrier), never swallowed:
    /// its own parts would have to be re-pointed.
    func testRefusesToFoldAMergedMeetingIntoAnOlderOne() async throws {
        let storage = try makeStorage()
        let old = try makeMeeting(storage, start: t0, segments: [])
        let b = try makeMeeting(storage, start: t0.addingTimeInterval(3600), segments: [])
        let c = try makeMeeting(storage, start: t0.addingTimeInterval(7200), segments: [])
        let probe = FakeProbe(bySlug: [old.slug: 100, b.slug: 200, c.slug: 300])
        let m = merger(storage, probe: probe)
        _ = try await m.merge(slugs: [b.slug, c.slug])   // b becomes a carrier
        do {
            _ = try await m.merge(slugs: [old.slug, b.slug])
            XCTFail("b is a carrier and older than nothing here")
        } catch {
            XCTAssertEqual(error as? MeetingMerger.MergeError,
                           .cannotAbsorbMergedMeeting(b.slug))
        }
    }
}
