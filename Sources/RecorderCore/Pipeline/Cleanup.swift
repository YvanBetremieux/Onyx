import Foundation

public enum Cleanup {
    public static func run(paths: MeetingPaths) async throws {
        try await Mp4Converter.convert(wav: paths.micWav, to: paths.micM4a)
        try await Mp4Converter.convert(wav: paths.systemWav, to: paths.systemM4a)
        for f in [paths.micWav, paths.systemWav,
                  paths.micNormalized, paths.systemNormalized] {
            try? FileManager.default.removeItem(at: f)
        }
        // Live-transcription chunk cache: consumed by the whisper steps, dead
        // weight once the merge is done.
        try? FileManager.default.removeItem(at: paths.transcriptChunks)
    }
}
