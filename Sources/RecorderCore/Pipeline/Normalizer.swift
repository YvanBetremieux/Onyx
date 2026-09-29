import AVFoundation

public enum NormalizerError: Error, Equatable {
    /// The input WAV is not in the format written by the recorder (16 kHz mono Float32).
    /// This is a recoverable pipeline step error — NOT a precondition: a corrupt
    /// file must not crash the app (crash-loop via resumePendingJobs).
    case unexpectedFormat(sampleRate: Double, channels: UInt32)
}

public enum Normalizer {
    public static func normalize(input: URL, output: URL) throws {
        let file = try AVAudioFile(forReading: input)
        let f = file.processingFormat
        guard f.sampleRate == 16_000, f.channelCount == 1 else {
            throw NormalizerError.unexpectedFormat(sampleRate: f.sampleRate,
                                                   channels: f.channelCount)
        }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.copyItem(at: input, to: output)
    }
}
