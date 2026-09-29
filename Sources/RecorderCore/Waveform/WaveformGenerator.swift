import Foundation
import AVFoundation

public enum WaveformGenerator {
    public enum GenerationError: Error {
        case unsupportedFormat
    }

    /// One-shot scan of a mono float32 WAV, returning true peaks (max |sample|)
    /// bucketed by `bucketSizeMs` (default 50 ms). Uses AVAudioFile for
    /// portability with whatever WAV writer wrote the file. Runs in ~50-100 ms
    /// for a 10-min WAV.
    public static func generate(from wavURL: URL,
                                bucketSizeMs: Int = 50) throws -> WaveformFile {
        let file = try AVAudioFile(forReading: wavURL)
        let sampleRate = Int(file.fileFormat.sampleRate)
        let framesPerBucket = max(1, sampleRate * bucketSizeMs / 1000)

        // The buffer MUST use `processingFormat`: `AVAudioFile.read(into:)`
        // raises an Objective-C exception (uncatchable from Swift, so it would
        // crash the app rather than surface as a thrown error) if the buffer's
        // format differs. `processingFormat` is always float32 deinterleaved,
        // which also makes the `floatChannelData` guard below unreachable —
        // it's kept as a cheap belt-and-braces check.
        let chunkFrames: AVAudioFrameCount = 16_384
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: chunkFrames) else {
            throw GenerationError.unsupportedFormat
        }

        var peaks: [Float] = []
        peaks.reserveCapacity(Int(file.length) / framesPerBucket + 1)

        // True peak per bucket: a scrubber drawn from RMS would never exceed
        // ~70% height for full-scale audio and would render quiet-but-audible
        // speech as near-silence.
        var bucketPeak: Float = 0
        var bucketCount: Int = 0

        while file.framePosition < file.length {
            try file.read(into: buf)
            let n = Int(buf.frameLength)
            // A zero-length read means EOF (or a stalled reader): bail out rather
            // than spin forever on an unchanged framePosition.
            if n == 0 { break }
            guard let ch0 = buf.floatChannelData?[0] else {
                throw GenerationError.unsupportedFormat
            }
            for i in 0..<n {
                bucketPeak = max(bucketPeak, abs(ch0[i]))
                bucketCount += 1
                if bucketCount >= framesPerBucket {
                    // A WAV can legitimately hold samples slightly above 1.0.
                    peaks.append(min(1, bucketPeak))
                    bucketPeak = 0
                    bucketCount = 0
                }
            }
        }
        if bucketCount > 0 {
            peaks.append(min(1, bucketPeak))
        }

        return WaveformFile(peaks: peaks,
                            sampleRate: sampleRate,
                            bucketSizeMs: bucketSizeMs)
    }
}
