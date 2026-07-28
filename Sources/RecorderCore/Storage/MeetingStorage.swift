import Foundation

public final class MeetingStorage {
    public let root: URL
    private let fileManager: FileManager
    private let appVersion: String

    public init(root: URL, fileManager: FileManager = .default, appVersion: String = "0.1.0") {
        self.root = root
        self.fileManager = fileManager
        self.appVersion = appVersion
    }

    public func createMeeting(startedAt: Date, timeZone: TimeZone = .current) throws -> MeetingPaths {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let slug = MeetingPaths.slug(for: startedAt, timeZone: timeZone)
        let paths = MeetingPaths(root: root, slug: slug)
        try fileManager.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.audio, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.transcripts, withIntermediateDirectories: true)

        let meta = MeetingMetadata(
            id: slug, startedAt: startedAt, endedAt: nil, durationSeconds: nil,
            title: nil, source: .manual, appVersion: appVersion,
            models: .init(whisper: "large-v3", diarization: "sherpa-pyannote-3.0")
        )
        try AtomicJSON.write(meta, to: paths.meta)
        try AtomicJSON.write(JobState.fresh(), to: paths.job)
        return paths
    }

    public func loadMetadata(_ paths: MeetingPaths) throws -> MeetingMetadata {
        try AtomicJSON.read(MeetingMetadata.self, from: paths.meta)
    }

    public func saveMetadata(_ meta: MeetingMetadata, at paths: MeetingPaths) throws {
        try AtomicJSON.write(meta, to: paths.meta)
    }

    public func patchMetadata(_ mut: @Sendable (inout MeetingMetadata) -> Void,
                              at paths: MeetingPaths) throws {
        var meta = try loadMetadata(paths)
        mut(&meta)
        try saveMetadata(meta, at: paths)
    }

    public func loadJob(_ paths: MeetingPaths) throws -> JobState {
        try AtomicJSON.read(JobState.self, from: paths.job)
    }

    public func saveJob(_ job: JobState, at paths: MeetingPaths) throws {
        try AtomicJSON.write(job, to: paths.job)
    }

    public struct Listing: Equatable {
        public let slug: String
        public let path: URL
    }

    public func listMeetings() throws -> [Listing] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        let entries = try fileManager.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { Listing(slug: $0.lastPathComponent, path: $0) }
            .sorted { $0.slug > $1.slug }
    }
}
