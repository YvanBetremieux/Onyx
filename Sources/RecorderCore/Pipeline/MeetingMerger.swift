import Foundation
import AVFoundation

/// Measures the playable length of an audio file. A protocol so the merger can
/// be tested without real audio (AVFoundation cannot decode a stub file).
public protocol AudioDurationProbing: Sendable {
    func durationSeconds(of url: URL) async -> Double?
}

public struct AVAudioDurationProbe: AudioDurationProbing {
    public init() {}
    public func durationSeconds(of url: URL) async -> Double? {
        guard let d = try? await AVURLAsset(url: url).load(.duration) else { return nil }
        let s = d.seconds
        return s.isFinite && s > 0 ? s : nil
    }
}

/// Merges several finished meetings, chosen by hand in the sidebar, into one.
///
/// This is the manual counterpart of `ContinuationAbsorber` and differs from it
/// on the one point that matters: the parts have no wall-clock relationship, so
/// they are **butted end-to-end** (part 2 starts exactly where part 1's audio
/// ends) instead of being placed at their real time offsets. A 4-hour gap
/// between two recordings would otherwise become 4 hours of silence to scrub
/// through.
///
/// No audio is ever rewritten. The carrier meeting records its parts in
/// `meta.mergedParts` (slug + offset + duration) and the player assembles them
/// into a single `AVMutableComposition` at playback time, so a merge costs no
/// disk, no re-encoding, and stays reversible. That is also why the absorbed
/// parts' folders are **kept** on disk (flagged `absorbed` + `mergedInto`, which
/// is what hides them from the index and the sidebar) rather than trashed.
///
/// What the carrier ends up with: the concatenated transcript (`transcript.json`
/// + a re-rendered `transcript.md` carrying a "Partie N" heading per part), the
/// concatenated live notes, notes regenerated over the whole thing, and a
/// duration covering every part.
public struct MeetingMerger: Sendable {
    public enum MergeError: Error, Equatable {
        /// Fewer than two distinct meetings — nothing to merge.
        case needsAtLeastTwoMeetings
        /// A meeting whose pipeline has not finished: its transcript is either
        /// absent or about to be overwritten by the running pipeline.
        case notFinished(String)
        /// Already a part of another merge (or an absorbed continuation).
        case alreadyMerged(String)
        /// A merged meeting can be *extended* (it is the oldest, so it carries
        /// the result), but it cannot be swallowed by another one: its own parts
        /// would have to be re-pointed, and the second merge's ordering would
        /// silently interleave.
        case cannotAbsorbMergedMeeting(String)
    }

    public struct MergeResult: Equatable, Sendable {
        /// Slug of the meeting that carries the result — the oldest one.
        public let target: String
        /// Slugs that were folded into it and are now hidden.
        public let absorbed: [String]
        /// Total length of the merged timeline.
        public let durationSeconds: Double
        public let parts: [MeetingMetadata.MergedPart]
    }

    let storage: MeetingStorage
    let notes: NoteGenerationConfig?
    let probe: any AudioDurationProbing

    public init(storage: MeetingStorage, notes: NoteGenerationConfig?,
                probe: any AudioDurationProbing = AVAudioDurationProbe()) {
        self.storage = storage
        self.notes = notes
        self.probe = probe
    }

    /// Merges `slugs` into their chronologically oldest member.
    ///
    /// Order of the argument is irrelevant — parts are always ordered by
    /// `startedAt`, because that is the only order the user can reason about.
    public func merge(slugs: [String]) async throws -> MergeResult {
        var seen = Set<String>()
        let unique = slugs.filter { seen.insert($0).inserted }
        guard unique.count >= 2 else { throw MergeError.needsAtLeastTwoMeetings }

        var loaded: [(paths: MeetingPaths, meta: MeetingMetadata)] = []
        for slug in unique {
            let paths = MeetingPaths(root: storage.root, slug: slug)
            let meta = try storage.loadMetadata(paths)
            guard meta.absorbed != true, meta.mergedInto == nil else {
                throw MergeError.alreadyMerged(slug)
            }
            // A running pipeline would overwrite `transcript.json` from its own
            // (partial) whisper output right after we rewrote it.
            guard (try? storage.loadJob(paths).state) == .done else {
                throw MergeError.notFinished(slug)
            }
            loaded.append((paths, meta))
        }
        loaded.sort { $0.meta.startedAt < $1.meta.startedAt }

        let target = loaded[0]
        let incoming = Array(loaded.dropFirst())
        for part in incoming where (part.meta.mergedParts?.count ?? 0) > 1 {
            throw MergeError.cannotAbsorbMergedMeeting(part.paths.slug)
        }

        // Part 0 is the carrier. When it is *already* a merged meeting, its
        // existing parts are kept verbatim — their offsets are already baked
        // into its transcript — and the new ones queue up after them.
        var parts: [MeetingMetadata.MergedPart]
        if let existing = target.meta.mergedParts, !existing.isEmpty {
            parts = existing
        } else {
            parts = [MeetingMetadata.MergedPart(
                slug: target.paths.slug, offsetSeconds: 0,
                durationSeconds: await slotDuration(target.paths, meta: target.meta),
                startedAt: target.meta.startedAt, title: target.meta.title)]
        }
        var cursor = parts.reduce(0) { $0 + $1.durationSeconds }
        for part in incoming {
            let duration = await slotDuration(part.paths, meta: part.meta)
            parts.append(MeetingMetadata.MergedPart(
                slug: part.paths.slug, offsetSeconds: cursor,
                durationSeconds: duration,
                startedAt: part.meta.startedAt, title: part.meta.title))
            cursor += duration
        }
        let total = cursor

        // MARK: transcript
        var combined = (try? AtomicJSON.read([TranscriptSegment].self,
                                             from: target.paths.transcriptJson)) ?? []
        for (offsetInParts, part) in incoming.enumerated() {
            // Index in the final part list: part 2 of a 2-way merge gets "(2)".
            let partNumber = parts.count - incoming.count + offsetInParts + 1
            let merged = parts.first { $0.slug == part.paths.slug }!
            let segments = (try? AtomicJSON.read([TranscriptSegment].self,
                                                 from: part.paths.transcriptJson)) ?? []
            combined += segments.map {
                TranscriptSegment(start: $0.start + merged.offsetSeconds,
                                  end: $0.end + merged.offsetSeconds,
                                  speaker: Self.namespacedSpeaker($0.speaker,
                                                                  partNumber: partNumber),
                                  text: $0.text)
            }
        }
        combined.sort { $0.start < $1.start }
        try AtomicJSON.write(combined, to: target.paths.transcriptJson)

        // MARK: live notes — user-typed, so nothing may be dropped
        try writeConcatenatedLiveNotes(target: target.paths, parts: parts)

        // MARK: metadata
        let lastMeta = loaded.last!.meta
        let finalParts = parts
        try storage.patchMetadata({ m in
            m.mergedParts = finalParts
            m.durationSeconds = Int(total.rounded())
            m.endedAt = lastMeta.endedAt ?? lastMeta.startedAt
                .addingTimeInterval(Double(lastMeta.durationSeconds ?? 0))
            // The carrier keeps its own title unless it has none: a merge is a
            // repair, not a rename, and the user can still rename afterwards.
            let own = m.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if own.isEmpty, let inherited = finalParts.compactMap({ $0.title })
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                m.title = inherited
                m.titleAutoDetected = true
            }
        }, at: target.paths)

        let mergedMeta = try storage.loadMetadata(target.paths)
        let md = MarkdownRenderer.render(
            segments: combined, meetingStart: mergedMeta.startedAt,
            slug: target.paths.slug,
            partBoundaries: Self.boundaries(for: parts))
        try md.data(using: .utf8)!.write(to: target.paths.transcriptMd, options: .atomic)

        // MARK: notes over the whole transcript
        try await NoteFanout.regenerate(paths: target.paths, meta: mergedMeta,
                                        storage: storage, notes: notes)

        // Flagged last: until this point every part is still a complete meeting
        // of its own, so a failure anywhere above leaves nothing hidden.
        for part in incoming {
            try storage.patchMetadata({ m in
                m.absorbed = true
                m.mergedInto = target.paths.slug
            }, at: part.paths)
        }
        Log.pipeline.info("""
            Merge: \(incoming.map(\.paths.slug).joined(separator: ", "), privacy: .public) \
            into \(target.paths.slug, privacy: .public) (\(Int(total))s total)
            """)

        return MergeResult(target: target.paths.slug,
                           absorbed: incoming.map(\.paths.slug),
                           durationSeconds: total, parts: parts)
    }

    /// Length of a part's slot on the merged timeline.
    ///
    /// The *audio* length wins over the recorded `durationSeconds`, because the
    /// player butts the next part against the end of this part's audio: taking
    /// the metadata's wall-clock duration (which includes the tail after the
    /// last sample) would leave a silent hole and, worse, shift the transcript
    /// out of sync with what is heard. The fallbacks only matter for a part with
    /// no playable audio at all.
    private func slotDuration(_ paths: MeetingPaths, meta: MeetingMetadata) async -> Double {
        let sources = AudioSourceResolver.resolveSources(paths: paths)
        var longest: Double = 0
        for url in sources.urls {
            if let d = await probe.durationSeconds(of: url) { longest = max(longest, d) }
        }
        if longest > 0 { return longest }
        if let recorded = meta.durationSeconds, recorded > 0 { return Double(recorded) }
        let segments = (try? AtomicJSON.read([TranscriptSegment].self,
                                             from: paths.transcriptJson)) ?? []
        return segments.map(\.end).max() ?? 0
    }

    /// Concatenates the parts' `notes/live.md` in order, under one heading per
    /// part. The carrier's own live notes stay at the top and are rewritten
    /// only when there is something to append.
    private func writeConcatenatedLiveNotes(target: MeetingPaths,
                                            parts: [MeetingMetadata.MergedPart]) throws {
        func body(_ slug: String) -> String {
            let paths = slug == target.slug ? target
                                            : MeetingPaths(root: storage.root, slug: slug)
            let text = (try? String(contentsOf: paths.liveNotes, encoding: .utf8)) ?? ""
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let extras = parts.dropFirst().filter { !body($0.slug).isEmpty }
        guard !extras.isEmpty else { return }
        var out = body(target.slug)
        for part in extras {
            if !out.isEmpty { out += "\n\n" }
            out += "---\n\n### \(Self.partLabel(part, in: parts))\n\n\(body(part.slug))"
        }
        try (out + "\n").data(using: .utf8)!.write(to: target.liveNotes, options: .atomic)
    }

    /// "Partie 2 — 13h59". The hour is the part's *real* recording time, which
    /// the butted-together timeline no longer carries anywhere else.
    static func partLabel(_ part: MeetingMetadata.MergedPart,
                          in parts: [MeetingMetadata.MergedPart]) -> String {
        let number = (parts.firstIndex(where: { $0.slug == part.slug }) ?? 0) + 1
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "fr_FR")
        fmt.dateFormat = "d MMM HH'h'mm"
        var label = "Partie \(number) — \(fmt.string(from: part.startedAt))"
        if let title = part.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            label += " — \(title)"
        }
        return label
    }

    static func boundaries(for parts: [MeetingMetadata.MergedPart])
        -> [MarkdownRenderer.PartBoundary] {
        parts.dropFirst().map {
            MarkdownRenderer.PartBoundary(offsetSeconds: $0.offsetSeconds,
                                          label: partLabel($0, in: parts))
        }
    }

    /// "MOI" is the local mic in every part — same person throughout. Remote
    /// diarization labels are clustered per recording, so part 2's
    /// "SPEAKER_00" is not part 1's: namespace them and let the note
    /// generation reconcile who is who.
    static func namespacedSpeaker(_ speaker: String, partNumber: Int) -> String {
        guard speaker != "MOI", partNumber > 1 else { return speaker }
        return "\(speaker) (\(partNumber))"
    }
}
