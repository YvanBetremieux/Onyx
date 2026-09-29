import Foundation

/// Picks the file(s) the viewer plays for a meeting.
///
/// This is constrained, not a free choice. `Pipeline`'s `.cleanup` step converts
/// `mic.wav`/`system.wav` to `.m4a` and then **deletes** `mic.wav`,
/// `system.wav`, `mic_normalized.wav` and `system_normalized.wav`. So for any
/// finished meeting the only surviving audio is `mic.m4a` / `system.m4a`, and
/// the WAVs exist only while the meeting is recording or its pipeline has not
/// reached cleanup yet.
///
/// A meeting has two independent, time-aligned streams — the user on the mic,
/// the remote participants on system audio — and the player mixes both
/// (`AudioPlayer.load(urls:)`), so the resolver's job is to pick the best file
/// *per stream*, not to choose between the streams. Within a stream the
/// preference is `.m4a` (the file that survives cleanup) over the normalized
/// WAV (what `waveform.json` was computed from) over the raw WAV.
public enum AudioSourceResolver {

    /// The best available file of each stream. Either side is nil when that
    /// stream has no non-empty regular file (never recorded, still empty, or
    /// an aborted recording's 0-byte stub).
    public struct Sources: Equatable {
        public var mic: URL?
        public var system: URL?
        /// The files to hand to the player, mic first. Order is cosmetic —
        /// both streams start at t=0 of the meeting and are mixed.
        public var urls: [URL] { [mic, system].compactMap { $0 } }
    }

    /// Per-stream preference order: the file that will still exist tomorrow
    /// (`.m4a`) before the pre-cleanup WAVs, and the normalized WAV before the
    /// raw one because that is the file `waveform.json` was computed from.
    public static func micCandidates(_ paths: MeetingPaths) -> [URL] {
        [paths.micM4a, paths.micNormalized, paths.micWav]
    }

    public static func systemCandidates(_ paths: MeetingPaths) -> [URL] {
        [paths.systemM4a, paths.systemNormalized, paths.systemWav]
    }

    /// Resolves both streams independently. This is what the viewer plays:
    /// both when both exist (mixed), one when only one exists, nothing when
    /// the meeting has no playable audio at all.
    public static func resolveSources(paths: MeetingPaths,
                               fileManager: FileManager = .default) -> Sources {
        Sources(mic: firstPlayable(micCandidates(paths), fileManager: fileManager),
                system: firstPlayable(systemCandidates(paths), fileManager: fileManager))
    }

    /// Single best file, mic stream preferred. Kept for callers (and tests)
    /// that need one representative file rather than the playable pair.
    public static func resolve(paths: MeetingPaths,
                        fileManager: FileManager = .default) -> URL? {
        let s = resolveSources(paths: paths, fileManager: fileManager)
        return s.mic ?? s.system
    }

    static func firstPlayable(_ candidates: [URL],
                                      fileManager: FileManager) -> URL? {
        candidates.first { url in
            guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular,
                  let size = attrs[.size] as? NSNumber
            else { return false }
            // A 0-byte file is what an aborted recording leaves behind;
            // the player would just fail on it a moment later.
            return size.intValue > 0
        }
    }

    /// True when `url` is one of the mic-stream files, i.e. when the pipeline's
    /// `waveform.json` (computed from `mic_normalized.wav`) describes it. Used
    /// to decide whether that cached waveform may be reused, or whether one has
    /// to be generated from the file actually being played.
    public static func isMicSource(_ url: URL, paths: MeetingPaths) -> Bool {
        micCandidates(paths)
            .contains { $0.standardizedFileURL == url.standardizedFileURL }
    }
}
