import Foundation
import AVFoundation

public struct DiarizationResult {
    public let segments: [DiarSegment]
    public init(segments: [DiarSegment]) {
        self.segments = segments
    }
}

public enum DiarizerError: Error, CustomStringConvertible {
    case modelMissing(URL)
    case audioLoadFailed(String)
    case sherpaInitFailed(String)

    public var description: String {
        switch self {
        case .modelMissing(let url):
            return "Diarizer: model file missing at \(url.path). Run onboarding or scripts/fetch-sherpa.sh to populate it."
        case .audioLoadFailed(let msg):
            return "Diarizer: failed to load audio — \(msg)"
        case .sherpaInitFailed(let msg):
            return "Diarizer: sherpa-onnx initialisation failed — \(msg)"
        }
    }
}

public protocol Diarizing: Sendable {
    func diarize(wavPath: URL, to jsonPath: URL) throws
}

public final class Diarizer: Diarizing, @unchecked Sendable {
    private let segmentationModelPath: URL
    private let embeddingModelPath: URL

    public init(segmentation: URL = ModelManifest.installedPath(for: ModelManifest.sherpaSegmentation),
                embedding: URL = ModelManifest.installedPath(for: ModelManifest.sherpaEmbedding)) {
        self.segmentationModelPath = segmentation
        self.embeddingModelPath = embedding
    }

    /// Reads a 16 kHz mono float32 WAV and writes `diarization.json` = `[DiarSegment]`.
    public func diarize(wavPath: URL, to jsonPath: URL) throws {
        for url in [segmentationModelPath, embeddingModelPath] {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw DiarizerError.modelMissing(url)
            }
        }

        let samples = try Self.loadMono16kSamples(from: wavPath)

        let sherpa: SherpaOfflineSpeakerDiarizer
        do {
            sherpa = try SherpaOfflineSpeakerDiarizer(
                segmentationModelPath: segmentationModelPath.path,
                embeddingModelPath: embeddingModelPath.path
            )
        } catch {
            throw DiarizerError.sherpaInitFailed(String(describing: error))
        }

        let rawSegments = sherpa.process(samples: samples)
        let segments = rawSegments.map {
            DiarSegment(
                start: Double($0.start),
                end: Double($0.end),
                speakerId: String(format: "SPEAKER_%02d", $0.speaker)
            )
        }

        try FileManager.default.createDirectory(
            at: jsonPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(segments)
        try data.write(to: jsonPath, options: .atomic)
    }

    /// Load a WAV file as a mono 16 kHz float32 sample array. Resamples/mixes
    /// down using `AVAudioConverter` when the source is not already in that
    /// format.
    static func loadMono16kSamples(from url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw DiarizerError.audioLoadFailed("open \(url.lastPathComponent): \(error)")
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw DiarizerError.audioLoadFailed("cannot build target format")
        }

        let sourceFormat = file.processingFormat

        // Fast path: already mono float32 @ 16 kHz.
        if sourceFormat.sampleRate == targetFormat.sampleRate
            && sourceFormat.channelCount == 1
            && sourceFormat.commonFormat == .pcmFormatFloat32 {
            let frameCount = AVAudioFrameCount(file.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
                throw DiarizerError.audioLoadFailed("alloc buffer")
            }
            try file.read(into: buffer)
            return Self.extractFloatSamples(from: buffer)
        }

        // Slow path: convert to target format.
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw DiarizerError.audioLoadFailed("cannot build AVAudioConverter from \(sourceFormat) to \(targetFormat)")
        }

        let chunkFrames: AVAudioFrameCount = 8_192
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkFrames) else {
            throw DiarizerError.audioLoadFailed("alloc input buffer")
        }

        // Sized generously to avoid mid-loop reallocations at upsampling ratios.
        let outputCapacity = AVAudioFrameCount(
            max(1024, Double(chunkFrames) * targetFormat.sampleRate / sourceFormat.sampleRate * 1.5)
        )
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            throw DiarizerError.audioLoadFailed("alloc output buffer")
        }

        var out: [Float] = []
        var inputExhausted = false

        while true {
            let inputBlock: AVAudioConverterInputBlock = { requested, outStatus in
                if inputExhausted {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                inputBuffer.frameLength = 0
                do {
                    try file.read(into: inputBuffer, frameCount: requested)
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inputBuffer.frameLength == 0 {
                    outStatus.pointee = .endOfStream
                    inputExhausted = true
                    return nil
                }
                outStatus.pointee = .haveData
                return inputBuffer
            }

            outputBuffer.frameLength = 0
            var convertError: NSError?
            let status = converter.convert(to: outputBuffer, error: &convertError, withInputFrom: inputBlock)

            if let convertError {
                throw DiarizerError.audioLoadFailed("convert: \(convertError.localizedDescription)")
            }

            if outputBuffer.frameLength > 0 {
                out.append(contentsOf: Self.extractFloatSamples(from: outputBuffer))
            }

            if status == .endOfStream || status == .error {
                break
            }
            if status == .inputRanDry && inputExhausted {
                break
            }
        }
        return out
    }

    private static func extractFloatSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let count = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }
}
