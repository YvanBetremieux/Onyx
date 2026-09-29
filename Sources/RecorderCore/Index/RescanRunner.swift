import Foundation
import GRDB

/// Rebuilds the SQLite index from the meeting folders on disk.
///
/// Two entry points:
/// - `rescan()` — full rebuild. Used by the explicit "Reindex" actions in the
///   menu bar and Settings, where the user asked for everything to be re-read.
/// - `rescan(onlyStale: true)` — boot path. Visits only meetings whose index row
///   is missing or *stale*, which is exactly what the schema migrations produce:
///   v2 (`start_ms` on the FTS table) and v3 (`source` / `detected_app` on
///   `meetings`) both `UPDATE meetings SET indexed_at = NULL`, so every pre-v3
///   row is picked up and backfilled without re-reading transcripts that are
///   already indexed.
public struct RescanRunner {
    public let storage: MeetingStorage
    public let indexer: MeetingIndexer

    public init(storage: MeetingStorage, indexer: MeetingIndexer) {
        self.storage = storage
        self.indexer = indexer
    }

    /// True when at least one meeting folder has no fresh row in the index.
    /// Cheap enough to call on boot: one SELECT plus one directory listing.
    public func needsRescan() throws -> Bool {
        let fresh = try freshlyIndexedIds()
        return try storage.listMeetings().contains { !fresh.contains($0.slug) }
    }

    /// - Parameter onlyStale: when `true`, meetings already indexed under the
    ///   current schema are skipped. Defaults to `false` (full rebuild) so the
    ///   existing manual "Reindex" call sites keep their meaning.
    public func rescan(onlyStale: Bool = false) async throws {
        let fresh: Set<String> = onlyStale ? try freshlyIndexedIds() : []
        for listing in try storage.listMeetings() {
            // The folder slug is the meeting id (see MeetingStorage.createMeeting),
            // so it can be matched against the index without reading meta.json.
            if onlyStale && fresh.contains(listing.slug) { continue }
            indexOne(slug: listing.slug)
        }
    }

    /// Indexes a single meeting, now. Called when its pipeline finishes so the
    /// sidebar shows the completed meeting immediately instead of waiting for
    /// the next full rescan (i.e. an app restart or a manual "Reindex").
    public func reindex(slug: String) {
        indexOne(slug: slug)
    }

    private func indexOne(slug: String) {
        let paths = MeetingPaths(root: storage.root, slug: slug)
        let meta: MeetingMetadata
        let job: JobState
        do {
            meta = try storage.loadMetadata(paths)
        } catch {
            Log.pipeline.error(
                "Rescan: skip \(slug, privacy: .public) — meta.json unreadable: \(String(describing: error), privacy: .public)")
            return
        }
        // An absorbed continuation segment lives on inside its parent's
        // transcript — its own row must disappear, not be refreshed.
        if meta.absorbed == true {
            try? indexer.removeMeeting(id: slug)
            return
        }
        do {
            job = try storage.loadJob(paths)
        } catch {
            Log.pipeline.error(
                "Rescan: skip \(slug, privacy: .public) — job.json unreadable: \(String(describing: error), privacy: .public)")
            return
        }
        let state = job.state == .done ? "done"
                   : job.state == .failed ? "failed" : "in_progress"
        let segments: [TranscriptSegment]
        if FileManager.default.fileExists(atPath: paths.transcriptJson.path) {
            segments = (try? AtomicJSON.read([TranscriptSegment].self,
                                             from: paths.transcriptJson)) ?? []
        } else { segments = [] }
        // Note bodies (generated levels + the user's live notes) join the
        // search index alongside the transcript.
        var notes: [(kind: String, text: String)] = []
        for level in NoteLevel.generatable {
            if let text = try? String(contentsOf: paths.notesFile(level), encoding: .utf8) {
                notes.append((kind: level.rawValue, text: text))
            }
        }
        if let live = try? String(contentsOf: paths.liveNotes, encoding: .utf8) {
            notes.append((kind: "live", text: live))
        }
        do {
            try indexer.upsert(meta: meta, folderPath: paths.root,
                               transcriptState: state, transcript: segments,
                               notes: notes)
        } catch {
            // One bad meeting must not abort the whole rescan: the remaining
            // folders still need their rows, and the already-written ones
            // must stay.
            Log.pipeline.error(
                "Rescan: upsert failed for \(slug, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Ids whose row was written by the *current* schema. `source IS NOT NULL`
    /// is part of the test because a v1/v2 row can carry a non-null `indexed_at`
    /// from before that column existed; the migrations null `indexed_at` out, but
    /// keeping both predicates makes the check robust to a partially migrated DB.
    ///
    /// An `in_progress` row is never fresh: it was indexed while the meeting's
    /// pipeline was still running, and if that pipeline's completion never got
    /// to reindex it (app killed mid-run), the row would otherwise stay
    /// "waiting for transcription" forever. Revisiting it at boot is the
    /// self-heal; genuinely still-running meetings just get re-indexed as
    /// in_progress again, which is free.
    private func freshlyIndexedIds() throws -> Set<String> {
        try indexer.reader.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT id FROM meetings
                WHERE indexed_at IS NOT NULL AND source IS NOT NULL
                  AND transcript_state != 'in_progress'
                """))
        }
    }
}
