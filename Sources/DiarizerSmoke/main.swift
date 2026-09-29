import Foundation
import RecorderCore

// swift run DiarizerSmoke <path-to-16k-mono.wav> [output.json]
//
// Downloads sherpa-onnx segmentation + embedding models on first run, invokes
// the real Diarizer against the supplied WAV, and prints the resulting
// speaker segments.

func log(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    log("usage: swift run DiarizerSmoke <path.wav> [output.json]")
    exit(2)
}

let wavPath = URL(fileURLWithPath: args[1])
let jsonPath: URL = args.count >= 3
    ? URL(fileURLWithPath: args[2])
    : FileManager.default.temporaryDirectory.appendingPathComponent("diarization.json")

guard FileManager.default.fileExists(atPath: wavPath.path) else {
    log("Input WAV not found: \(wavPath.path)")
    exit(2)
}

let assets: [ModelAsset] = [
    ModelManifest.sherpaSegmentation,
    ModelManifest.sherpaEmbedding,
]

let downloader = ModelDownloader()

do {
    for asset in assets {
        let dest = ModelManifest.installedPath(for: asset)
        if FileManager.default.fileExists(atPath: dest.path) {
            log("[ok] \(asset.id) already present at \(dest.path)")
            continue
        }
        log("[fetch] \(asset.id) -> \(dest.path)")
        var lastPct = -1
        _ = try await downloader.download(asset) { progress in
            guard progress.bytesExpected > 0 else { return }
            let pct = Int(Double(progress.bytesReceived) / Double(progress.bytesExpected) * 100)
            if pct != lastPct && pct % 5 == 0 {
                lastPct = pct
                log("       \(asset.id) \(pct)%")
            }
        }
        log("[done] \(asset.id)")
    }
} catch {
    log("Model download failed: \(error)")
    exit(1)
}

let diarizer = Diarizer()
let clock = ContinuousClock()
let t0 = clock.now
do {
    try diarizer.diarize(wavPath: wavPath, to: jsonPath)
} catch {
    log("Diarization failed: \(error)")
    exit(1)
}
let elapsed = clock.now - t0
log("Diarization completed in \(elapsed).")

// Print the JSON output.
if let data = try? Data(contentsOf: jsonPath),
   let json = String(data: data, encoding: .utf8) {
    print(json)
} else {
    log("No output at \(jsonPath.path)")
    exit(1)
}
log("Wrote \(jsonPath.path)")
