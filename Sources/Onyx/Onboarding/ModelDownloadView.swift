import SwiftUI
import RecorderCore
import WhisperKit

struct ModelDownloadView: View {
    @State private var status: String = "Preparing…"
    @State private var progress: Double = 0
    @State private var failed: Bool = false
    @State private var downloadTask: Task<Void, Never>? = nil
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(status).font(.headline)
            if !failed {
                ProgressView(value: progress).frame(width: 320)
            } else {
                HStack(spacing: 16) {
                    Button("Retry") {
                        failed = false
                        status = "Preparing…"
                        progress = 0
                        downloadTask = Task { await run() }
                    }
                    Button("Skip") {
                        onDone()
                    }
                    .foregroundColor(.secondary)
                }
            }
        }
        .padding(40)
        .onAppear {
            downloadTask = Task { await run() }
        }
    }

    private func run() async {
        // Step 1: Whisper model — downloaded via WhisperKit's own API.
        // Its manifest URL is a HuggingFace repo, not a single file, so the
        // generic ModelDownloader can't fetch it; WhisperKit.download does a
        // proper multi-file snapshot.
        status = "Downloading openai_whisper-large-v3 (1/3)…"
        progress = 0
        do {
            try await downloadWhisperIfNeeded()
        } catch {
            status = "Failed openai_whisper-large-v3: \(error.localizedDescription)"
            failed = true
            return
        }

        // Step 2 & 3: sherpa assets — single file / tar.bz2, ModelDownloader works fine.
        let downloader = ModelDownloader()
        let assets: [ModelAsset] = [
            ModelManifest.sherpaSegmentation,
            ModelManifest.sherpaEmbedding,
        ]
        for (i, a) in assets.enumerated() {
            status = "Downloading \(a.id) (\(i+2)/3)…"
            progress = 0
            do {
                _ = try await downloader.download(a) { p in
                    if p.bytesExpected > 0 {
                        let received = p.bytesReceived
                        let expected = p.bytesExpected
                        Task { @MainActor in progress = Double(received) / Double(expected) }
                    }
                }
            } catch { status = "Failed \(a.id): \(error.localizedDescription)"; failed = true; return }
        }
        onDone()
    }

    /// Downloads the Whisper model via WhisperKit into a staging dir and moves
    /// it to the path `ModelManifest.installedPath` (and thus `WhisperTranscriber`)
    /// expects. No-op if that path already exists.
    private func downloadWhisperIfNeeded() async throws {
        let installed = ModelManifest.installedPath(for: ModelManifest.whisperLargeV3)
        if FileManager.default.fileExists(atPath: installed.path) { return }

        let stagingBase = ModelManifest.installRoot.appendingPathComponent(
            "whisperkit-hub", isDirectory: true
        )
        try FileManager.default.createDirectory(at: stagingBase,
                                                withIntermediateDirectories: true)

        let downloaded = try await WhisperKit.download(
            variant: "openai_whisper-large-v3",
            downloadBase: stagingBase,
            from: "argmaxinc/whisperkit-coreml"
        ) { p in
            Task { @MainActor in progress = p.fractionCompleted }
        }

        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: installed)
        try FileManager.default.moveItem(at: downloaded, to: installed)
        // Clean up empty staging dirs (models/argmaxinc/whisperkit-coreml/…)
        try? FileManager.default.removeItem(at: stagingBase)
    }
}
