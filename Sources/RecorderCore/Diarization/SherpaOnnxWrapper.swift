import Foundation
import CSherpaOnnx

/// Minimal Swift bindings around the pieces of sherpa-onnx's C API needed for
/// offline speaker diarization. Adapted from `swift-api-examples/SherpaOnnx.swift`
/// in the sherpa-onnx repository (v1.13.4).

struct SherpaDiarSegment {
    var start: Float
    var end: Float
    var speaker: Int
}

final class SherpaOfflineSpeakerDiarizer {
    private var impl: OpaquePointer?

    /// Default thread count: scale with the machine instead of the previous
    /// hardcoded 2, which left most cores idle during the longest post-stop
    /// step. Two cores are kept free for the UI + audio; capped at 8 (onnx
    /// runtime gains flatten out beyond that on these models).
    static let defaultNumThreads = Int32(
        max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))

    init(segmentationModelPath: String,
         embeddingModelPath: String,
         numThreads: Int32 = SherpaOfflineSpeakerDiarizer.defaultNumThreads,
         provider: String = "cpu",
         minDurationOn: Float = 0.3,
         minDurationOff: Float = 0.5,
         clusteringThreshold: Float = 0.5,
         numClusters: Int32 = -1) throws {

        var created: OpaquePointer?

        segmentationModelPath.withCString { segPtr in
            embeddingModelPath.withCString { embPtr in
                provider.withCString { provPtr in
                    let pyannote = SherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(model: segPtr)
                    let segCfg = SherpaOnnxOfflineSpeakerSegmentationModelConfig(
                        pyannote: pyannote,
                        num_threads: numThreads,
                        debug: 0,
                        provider: provPtr
                    )
                    let embCfg = SherpaOnnxSpeakerEmbeddingExtractorConfig(
                        model: embPtr,
                        num_threads: numThreads,
                        debug: 0,
                        provider: provPtr
                    )
                    let clustering = SherpaOnnxFastClusteringConfig(
                        num_clusters: numClusters,
                        threshold: clusteringThreshold
                    )
                    var config = SherpaOnnxOfflineSpeakerDiarizationConfig(
                        segmentation: segCfg,
                        embedding: embCfg,
                        clustering: clustering,
                        min_duration_on: minDurationOn,
                        min_duration_off: minDurationOff
                    )
                    created = withUnsafePointer(to: &config) { cfgPtr -> OpaquePointer? in
                        // C API returns `const SherpaOnnxOfflineSpeakerDiarization *`,
                        // which imports as `OpaquePointer?` because the struct is
                        // only forward-declared in the public header.
                        return SherpaOnnxCreateOfflineSpeakerDiarization(cfgPtr)
                    }
                }
            }
        }

        guard let p = created else {
            throw NSError(domain: "SherpaDiarizer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "SherpaOnnxCreateOfflineSpeakerDiarization returned NULL. segmentation=\(segmentationModelPath) embedding=\(embeddingModelPath)"])
        }
        self.impl = p
    }

    deinit {
        if let impl {
            SherpaOnnxDestroyOfflineSpeakerDiarization(impl)
        }
    }

    var sampleRate: Int32 {
        guard let impl else { return 16000 }
        return SherpaOnnxOfflineSpeakerDiarizationGetSampleRate(impl)
    }

    func process(samples: [Float]) -> [SherpaDiarSegment] {
        guard let impl else { return [] }
        guard !samples.isEmpty else { return [] }

        let result: OpaquePointer? = samples.withUnsafeBufferPointer { buf -> OpaquePointer? in
            SherpaOnnxOfflineSpeakerDiarizationProcess(impl, buf.baseAddress, Int32(buf.count))
        }
        guard let result else { return [] }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result) }

        let n = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result))
        guard n > 0,
              let segs = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result)
        else { return [] }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroySegment(segs) }

        var out: [SherpaDiarSegment] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let s = segs[i]
            out.append(SherpaDiarSegment(start: s.start, end: s.end, speaker: Int(s.speaker)))
        }
        return out
    }
}
