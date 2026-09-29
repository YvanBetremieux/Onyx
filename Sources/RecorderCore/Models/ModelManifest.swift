import Foundation

public struct ModelAsset {
    public let id: String
    /// Remote URL to download the asset from. `nil` for assets whose download
    /// is managed by a separate subsystem (e.g. WhisperKit manages its own
    /// model fetch; pointing `ModelDownloader` at those URLs is incorrect).
    public let remoteURL: URL?
    /// Where the *final* usable file/directory ends up under `installRoot`.
    /// For archives, this points inside the extraction directory.
    public let relativeInstallPath: String
    public let sha256: String?
    /// If `.archiveTarBz2`, the downloader extracts and then verifies
    /// `relativeInstallPath` exists inside the extracted tree.
    public let kind: Kind

    public enum Kind {
        case file
        case archiveTarBz2
    }

    public init(id: String,
                remoteURL: URL?,
                relativeInstallPath: String,
                sha256: String?,
                kind: Kind = .file) {
        self.id = id
        self.remoteURL = remoteURL
        self.relativeInstallPath = relativeInstallPath
        self.sha256 = sha256
        self.kind = kind
    }
}

public enum ModelManifest {
    /// WhisperKit manages its own model download; `remoteURL` is `nil` here
    /// because the HuggingFace page URL is not a direct file download.
    /// Use `WhisperKit.download(...)` instead of `ModelDownloader` for this asset.
    public static let whisperLargeV3 = ModelAsset(
        id: "openai_whisper-large-v3",
        remoteURL: nil,
        relativeInstallPath: "whisperkit/openai_whisper-large-v3",
        sha256: nil
    )

    /// Large-v3 "turbo" (v20240930): distilled decoder, ~4-6× faster than
    /// large-v3 for near-identical quality — the speed/quality sweet spot for
    /// live chunked transcription. Downloaded lazily by `WhisperTranscriber`
    /// on first use (same WhisperKit-managed fetch as large-v3).
    public static let whisperLargeV3Turbo = ModelAsset(
        id: "openai_whisper-large-v3-v20240930",
        remoteURL: nil,
        relativeInstallPath: "whisperkit/openai_whisper-large-v3-v20240930",
        sha256: nil
    )

    /// Whisper asset for a persisted settings value; unknown ids fall back to
    /// turbo (the default) so a stale preference can never break transcription.
    public static func whisperAsset(id: String) -> ModelAsset {
        id == whisperLargeV3.id ? whisperLargeV3 : whisperLargeV3Turbo
    }

    /// Pyannote segmentation 3.0, packaged as a tar.bz2 by sherpa-onnx.
    /// After extraction the usable model lives at
    /// `sherpa/sherpa-onnx-pyannote-segmentation-3-0/model.onnx`.
    public static let sherpaSegmentation = ModelAsset(
        id: "sherpa-onnx-pyannote-segmentation-3-0",
        remoteURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2")!,
        relativeInstallPath: "sherpa/sherpa-onnx-pyannote-segmentation-3-0/model.onnx",
        sha256: nil,
        kind: .archiveTarBz2
    )

    /// WeSpeaker CAM++ trained on VoxCeleb — a general-purpose English/European
    /// speaker embedding model. Preferred over the previous Chinese-only
    /// 3dspeaker model for French/English meetings.
    /// See https://k2-fsa.github.io/sherpa/onnx/pretrained_models/speaker-embedding-models/
    public static let sherpaEmbedding = ModelAsset(
        id: "wespeaker_en_voxceleb_CAM++",
        remoteURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_CAM++.onnx")!,
        relativeInstallPath: "sherpa/wespeaker_en_voxceleb_CAMPP.onnx",
        sha256: nil
    )

    public static let installRoot: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Onyx/models", isDirectory: true)
    }()

    public static func installedPath(for asset: ModelAsset) -> URL {
        installRoot.appendingPathComponent(asset.relativeInstallPath)
    }
}
