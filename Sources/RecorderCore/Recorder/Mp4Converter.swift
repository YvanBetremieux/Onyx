import AVFoundation

public enum Mp4Converter {
    public static func convert(wav: URL, to m4a: URL,
                               timeoutSeconds: TimeInterval = 600) async throws {
        let asset = AVURLAsset(url: wav)
        guard let export = AVAssetExportSession(asset: asset,
                                                presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "Onyx", code: 300,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create exporter"])
        }
        try? FileManager.default.removeItem(at: m4a)
        export.outputURL = m4a
        export.outputFileType = .m4a

        // Race export vs timeout — a stalled export would leave the job
        // stuck in_progress permanently.
        let finished = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await export.export(); return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !finished {
            export.cancelExport()
            throw NSError(domain: "Onyx", code: 302,
                          userInfo: [NSLocalizedDescriptionKey:
                            "m4a export timed out after \(Int(timeoutSeconds))s"])
        }
        if export.status != .completed {
            throw export.error ?? NSError(domain: "Onyx", code: 301)
        }
    }
}
