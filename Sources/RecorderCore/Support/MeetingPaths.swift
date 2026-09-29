import Foundation

public struct MeetingPaths: Equatable {
    public let root: URL
    public let slug: String

    public init(root: URL, slug: String) {
        self.root = root.appendingPathComponent(slug, isDirectory: true)
        self.slug = slug
    }

    public var audio: URL          { root.appendingPathComponent("audio", isDirectory: true) }
    public var transcripts: URL    { root.appendingPathComponent("transcripts", isDirectory: true) }
    public var meta: URL           { root.appendingPathComponent("meta.json") }
    public var job: URL            { root.appendingPathComponent("job.json") }

    public var micWav: URL         { audio.appendingPathComponent("mic.wav") }
    public var systemWav: URL      { audio.appendingPathComponent("system.wav") }
    public var micNormalized: URL  { audio.appendingPathComponent("mic_normalized.wav") }
    public var systemNormalized: URL { audio.appendingPathComponent("system_normalized.wav") }
    public var micM4a: URL         { audio.appendingPathComponent("mic.m4a") }
    public var systemM4a: URL      { audio.appendingPathComponent("system.m4a") }

    public var whisperMic: URL     { transcripts.appendingPathComponent("whisper_mic.json") }
    public var whisperSystem: URL  { transcripts.appendingPathComponent("whisper_system.json") }
    public var diarization: URL    { transcripts.appendingPathComponent("diarization.json") }
    public var transcriptJson: URL { transcripts.appendingPathComponent("transcript.json") }
    public var transcriptMd: URL   { transcripts.appendingPathComponent("transcript.md") }

    public static func slug(for date: Date, timeZone: TimeZone = .current) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = timeZone
        fmt.dateFormat = "yyyy-MM-dd_HH'h'mm"
        return fmt.string(from: date)
    }
}

public extension MeetingPaths {
    var notesDir: URL { root.appendingPathComponent("notes", isDirectory: true) }
    func notesFile(_ level: NoteLevel) -> URL {
        notesDir.appendingPathComponent("\(level.rawValue).md")
    }

    /// User-editable live notes taken during the meeting. Created empty by
    /// `MeetingStorage.createMeeting`, never overwritten by regeneration,
    /// injected into the Claude prompt during the `.notes` pipeline step.
    var liveNotes: URL { notesDir.appendingPathComponent("live.md") }

    /// Pre-computed waveform peaks (Codable `[Float]`) written at the pipeline
    /// `.render` step. Falls back to on-the-fly generation in the viewer if
    /// absent (meetings from before chantier 3).
    var waveformJson: URL { audio.appendingPathComponent("waveform.json") }
}
