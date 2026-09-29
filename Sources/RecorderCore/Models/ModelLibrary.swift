import Foundation
import WhisperKit

/// Install-state management for the ML models: what is on disk, how big it
/// is, downloading and deleting. The Settings window drives it; the
/// transcriber uses `downloadWhisperIfNeeded` for its lazy first-use fetch.
///
/// `root` is injectable for tests; production always uses
/// `ModelManifest.installRoot`.
public enum ModelLibrary {
    /// All Whisper variants the app knows about, in UI order.
    public static var whisperVariants: [ModelAsset] {
        [ModelManifest.whisperLargeV3Turbo, ModelManifest.whisperLargeV3]
    }

    public static func isInstalled(_ asset: ModelAsset,
                                   root: URL = ModelManifest.installRoot) -> Bool {
        FileManager.default.fileExists(
            atPath: root.appendingPathComponent(asset.relativeInstallPath).path)
    }

    /// Total on-disk size of an installed asset (recursive for directories),
    /// nil when not installed.
    public static func installedSizeBytes(_ asset: ModelAsset,
                                          root: URL = ModelManifest.installRoot) -> Int64? {
        let url = root.appendingPathComponent(asset.relativeInstallPath)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        guard let enumerator = fm.enumerator(at: url,
                                             includingPropertiesForKeys: [.totalFileAllocatedSizeKey,
                                                                          .fileSizeKey]) else {
            return (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    /// Removes an installed model from disk. Safe on the *selected* model
    /// too: `WhisperTranscriber` re-downloads lazily at the next use.
    public static func delete(_ asset: ModelAsset,
                              root: URL = ModelManifest.installRoot) throws {
        try FileManager.default.removeItem(
            at: root.appendingPathComponent(asset.relativeInstallPath))
    }

    /// Downloads a Whisper variant via WhisperKit's own fetcher (staged, then
    /// moved — a cancelled download can never leave a half model at the
    /// install path). No-op when already installed.
    public static func downloadWhisperIfNeeded(
        _ asset: ModelAsset,
        root: URL = ModelManifest.installRoot,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let installed = root.appendingPathComponent(asset.relativeInstallPath)
        guard !FileManager.default.fileExists(atPath: installed.path) else { return }
        Log.pipeline.info("ModelLibrary: downloading \(asset.id, privacy: .public)")
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperkit-hub-\(UUID().uuidString)", isDirectory: true)
        let downloaded = try await WhisperKit.download(
            variant: asset.id,
            downloadBase: staging,
            from: "argmaxinc/whisperkit-coreml",
            progressCallback: { p in progress?(p.fractionCompleted) })
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: downloaded, to: installed)
        try? FileManager.default.removeItem(at: staging)
        Log.pipeline.info("ModelLibrary: installed \(asset.id, privacy: .public)")
    }
}
