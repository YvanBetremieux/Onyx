import Foundation

/// Regenerates a meeting's notes over its *current* transcript, one parallel
/// `claude -p` session per level.
///
/// Extracted from `ContinuationAbsorber` so the manual merge behaves identically
/// to the automatic one: both replace notes that describe only part of a
/// transcript, so unlike the pipeline's `.notes` step there is deliberately no
/// "already exists on disk" skip — overwriting is the whole point.
enum NoteFanout {
    /// Runs every level of `cfg` and writes back any Claude-detected title.
    /// No-op without a configured binary or with no levels to generate.
    static func regenerate(paths: MeetingPaths, meta: MeetingMetadata,
                           storage: MeetingStorage,
                           notes cfg: NoteGenerationConfig?) async throws {
        guard let cfg, let binary = cfg.binary else { return }
        let todo = cfg.levels.filter { $0 != .live }
        guard !todo.isEmpty else { return }
        let titleCarrier = NoteLevel.titleCarrier(among: todo)
        try await withThrowingTaskGroup(of: String?.self) { group in
            for level in todo {
                let detectTitle = level == titleCarrier && meta.wantsTitleDetection
                group.addTask {
                    try await cfg.generator.generate(
                        paths: paths, level: level, binary: binary,
                        model: cfg.model, detectTitle: detectTitle
                    ).detectedTitle
                }
            }
            for try await detected in group {
                if let title = detected {
                    try storage.patchMetadata({ m in
                        m.title = title
                        m.titleAutoDetected = true
                    }, at: paths)
                }
            }
        }
    }
}
