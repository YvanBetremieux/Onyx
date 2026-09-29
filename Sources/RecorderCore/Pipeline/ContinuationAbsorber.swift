import Foundation

/// Merges a continuation segment (a recording restarted after a crash
/// mid-meeting, see `MeetingMetadata.continuationOf`) into its parent meeting.
///
/// Merge happens at the *transcript* level, never the audio level: each
/// segment is transcribed independently by its own (resumable) pipeline, then
/// the child's segments are shifted by the wall-clock offset between the two
/// recording starts and appended to the parent's transcript. The gap between
/// crash and relaunch therefore shows as a genuine hole in the timeline
/// instead of silently compressing time.
///
/// On success the parent gets a re-rendered markdown, freshly generated notes
/// over the full transcript, and the child is marked `absorbed` (hidden from
/// the index and the sidebar). On any failure the child simply stays a
/// visible, complete meeting of its own — exactly the pre-feature behavior.
public struct ContinuationAbsorber: Sendable {
    public enum AbsorbError: Error, Equatable {
        case parentPipelineFailed(String)
        case timedOutWaitingForParent(String)
        case continuationChainTooDeep
    }

    let storage: MeetingStorage
    let notes: NoteGenerationConfig?
    /// Parent-pipeline wait: the parent segment resumes transcription at app
    /// relaunch, concurrently with this recording — its transcript must exist
    /// before it can absorb anything.
    let pollSeconds: TimeInterval
    let timeoutSeconds: TimeInterval

    public init(storage: MeetingStorage, notes: NoteGenerationConfig?,
                pollSeconds: TimeInterval = 5, timeoutSeconds: TimeInterval = 2700) {
        self.storage = storage
        self.notes = notes
        self.pollSeconds = pollSeconds
        self.timeoutSeconds = timeoutSeconds
    }

    /// No-op for regular meetings (`continuationOf == nil`) and for segments
    /// already absorbed (resume after a crash mid-absorption).
    public func absorbIfContinuation(child childPaths: MeetingPaths) async throws {
        let childMeta = try storage.loadMetadata(childPaths)
        guard childMeta.absorbed != true, childMeta.continuationOf != nil else { return }

        let (parentPaths, parentMeta) = try rootParent(of: childMeta)
        try await waitForParentPipeline(parentPaths)

        let childSegs = (try? AtomicJSON.read([TranscriptSegment].self,
                                              from: childPaths.transcriptJson)) ?? []
        let offset = childMeta.startedAt.timeIntervalSince(parentMeta.startedAt)
        let shifted = childSegs.map { seg in
            TranscriptSegment(start: seg.start + offset, end: seg.end + offset,
                              speaker: Self.namespacedSpeaker(seg.speaker), text: seg.text)
        }

        var combined = try AtomicJSON.read([TranscriptSegment].self,
                                           from: parentPaths.transcriptJson)
        // Idempotence: a crash after the transcript write but before the child
        // was flagged absorbed must not duplicate the segments on resume.
        if let first = shifted.first, combined.contains(first) {
            Log.pipeline.info(
                "Absorb: segments already present in \(parentPaths.slug, privacy: .public), skipping append")
        } else {
            combined = (combined + shifted).sorted { $0.start < $1.start }
            try AtomicJSON.write(combined, to: parentPaths.transcriptJson)
        }

        try storage.patchMetadata({ m in
            m.endedAt = childMeta.endedAt
            // The parent crashed mid-recording, so its own duration was never
            // written; the full wall-clock span is the only honest value.
            if let childEnd = childMeta.endedAt {
                m.durationSeconds = Int(childEnd.timeIntervalSince(m.startedAt))
            }
            // The child may have been retro-linked to the calendar event after
            // the crash re-detection — adopt its identity if the parent has none.
            let parentTitle = m.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if parentTitle.isEmpty || m.titleAutoDetected == true,
               let childTitle = childMeta.title, !childTitle.isEmpty {
                m.title = childTitle
                m.titleAutoDetected = childMeta.titleAutoDetected
            }
            if m.calendarEventId == nil { m.calendarEventId = childMeta.calendarEventId }
            if m.source == .detected, childMeta.source == .calendar { m.source = .calendar }
        }, at: parentPaths)

        let mergedMeta = try storage.loadMetadata(parentPaths)
        let md = MarkdownRenderer.render(segments: combined,
                                         meetingStart: mergedMeta.startedAt,
                                         slug: parentPaths.slug)
        try md.data(using: .utf8)!.write(to: parentPaths.transcriptMd, options: .atomic)

        try await regenerateParentNotes(parentPaths, meta: mergedMeta)

        try storage.patchMetadata({ $0.absorbed = true }, at: childPaths)
        Log.pipeline.info(
            "Absorb: merged \(childPaths.slug, privacy: .public) into \(parentPaths.slug, privacy: .public) (offset \(Int(offset))s)")
    }

    /// Resolves `continuationOf` transitively: two crashes in the same meeting
    /// chain child₂ → child₁ → parent, and everything must land in the root —
    /// child₁ will itself be absorbed and hidden.
    private func rootParent(of childMeta: MeetingMetadata)
        throws -> (MeetingPaths, MeetingMetadata) {
        var slug = childMeta.continuationOf!
        for _ in 0..<10 {
            let paths = MeetingPaths(root: storage.root, slug: slug)
            let meta = try storage.loadMetadata(paths)
            guard let up = meta.continuationOf else { return (paths, meta) }
            slug = up
        }
        throw AbsorbError.continuationChainTooDeep
    }

    private func waitForParentPipeline(_ parentPaths: MeetingPaths) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while true {
            let job = try storage.loadJob(parentPaths)
            switch job.state {
            case .done: return
            case .failed: throw AbsorbError.parentPipelineFailed(parentPaths.slug)
            default:
                guard Date() < deadline else {
                    throw AbsorbError.timedOutWaitingForParent(parentPaths.slug)
                }
                try await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
            }
        }
    }

    /// Overwrites the parent's generated notes with ones covering the full
    /// merged transcript — see `NoteFanout`, shared with the manual merge.
    private func regenerateParentNotes(_ paths: MeetingPaths, meta: MeetingMetadata) async throws {
        try await NoteFanout.regenerate(paths: paths, meta: meta,
                                        storage: storage, notes: notes)
    }

    /// "MOI" is the local mic on both segments — same person, keep it. Remote
    /// diarization labels are clustered per segment, so "SPEAKER_00" in part 2
    /// is not necessarily part 1's "SPEAKER_00": namespace them and let the
    /// note generation reconcile.
    static func namespacedSpeaker(_ speaker: String) -> String {
        speaker == "MOI" ? speaker : "\(speaker) (2)"
    }
}
