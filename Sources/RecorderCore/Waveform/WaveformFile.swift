import Foundation

/// Compact on-disk representation of a meeting's waveform, used by the viewer's
/// scrubber. Written once by the pipeline `.render` step, then read many times.
public struct WaveformFile: Codable, Equatable, Sendable {
    /// True peak amplitude — `max(|sample|)` clamped to [0, 1] — per bucket,
    /// in chronological order.
    public let peaks: [Float]
    public let sampleRate: Int
    public let bucketSizeMs: Int

    public init(peaks: [Float], sampleRate: Int, bucketSizeMs: Int) {
        self.peaks = peaks
        self.sampleRate = sampleRate
        self.bucketSizeMs = bucketSizeMs
    }

    public func write(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> WaveformFile {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(WaveformFile.self, from: data)
    }
}
