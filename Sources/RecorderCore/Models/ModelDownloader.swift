import Foundation
import CryptoKit

// MARK: - Errors

public enum ModelDownloaderError: Error, LocalizedError {
    case noRemoteURL(assetID: String)
    case checksumMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .noRemoteURL(let id):
            return "Asset '\(id)' has no remoteURL — its download is managed by a separate subsystem."
        case .checksumMismatch(let expected, let actual):
            return "SHA-256 checksum mismatch. Expected: \(expected), actual: \(actual)."
        }
    }
}

// MARK: - ModelDownloader

public final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    public struct Progress {
        public let asset: ModelAsset
        public let bytesReceived: Int64
        public let bytesExpected: Int64
    }

    public typealias ProgressHandler = (Progress) -> Void

    // All access to `handler` and `pending` must be done under `lock`.
    private let lock = NSLock()
    private var handler: ProgressHandler?
    private var pending: [(ModelAsset, CheckedContinuation<URL, Error>)] = []

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    public override init() { super.init() }

    public func download(_ asset: ModelAsset, progress: @escaping ProgressHandler) async throws -> URL {
        guard let remoteURL = asset.remoteURL else {
            throw ModelDownloaderError.noRemoteURL(assetID: asset.id)
        }

        let dest = ModelManifest.installedPath(for: asset)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }

        // Ensure the parent for the *final* file exists (for both file and
        // archive kinds; archives extract into `installRoot/sherpa/`).
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            handler = progress
            pending.append((asset, cont))
            lock.unlock()

            let task = session.downloadTask(with: remoteURL)
            task.taskDescription = asset.id
            task.resume()
        }
    }

    public func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                           totalBytesExpectedToWrite total: Int64) {
        lock.lock()
        let id = downloadTask.taskDescription
        let assetMatch = id.flatMap { taskID in pending.first(where: { $0.0.id == taskID }) }
        let currentHandler = handler
        lock.unlock()

        guard let (asset, _) = assetMatch else { return }
        currentHandler?(.init(asset: asset, bytesReceived: totalBytesWritten, bytesExpected: total))
    }

    public func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }

        lock.lock()
        guard let idx = pending.firstIndex(where: { $0.0.id == id }) else {
            lock.unlock()
            return
        }
        let (asset, cont) = pending.remove(at: idx)
        lock.unlock()

        let finalPath = ModelManifest.installedPath(for: asset)
        do {
            // SHA-256 verification before moving/extracting
            if let expectedHash = asset.sha256 {
                try verifySHA256(of: location, expectedHex: expectedHash)
            } else {
                Log.recorder.warning("ModelDownloader: no SHA-256 checksum for asset '\(asset.id)' — skipping verification")
            }

            switch asset.kind {
            case .file:
                try? FileManager.default.removeItem(at: finalPath)
                try FileManager.default.moveItem(at: location, to: finalPath)
            case .archiveTarBz2:
                try Self.extractTarBz2(from: location, into: finalPath.deletingLastPathComponent().deletingLastPathComponent())
                // extraction target = installRoot/sherpa/ ; the archive contains
                // `sherpa-onnx-pyannote-segmentation-3-0/` at its root, so after
                // extraction the final path (…/sherpa/…-3-0/model.onnx) must exist.
                guard FileManager.default.fileExists(atPath: finalPath.path) else {
                    throw NSError(domain: "ModelDownloader", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "Archive \(asset.id) extracted but expected file missing at \(finalPath.path)"])
                }
                try? FileManager.default.removeItem(at: location)
            }
            cont.resume(returning: finalPath)
        } catch { cont.resume(throwing: error) }
    }

    public func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }

        lock.lock()
        guard let idx = pending.firstIndex(where: { $0.0.id == id }) else {
            lock.unlock()
            return
        }
        let (_, cont) = pending.remove(at: idx)
        lock.unlock()

        cont.resume(throwing: error)
    }

    // MARK: - SHA-256 verification

    private func verifySHA256(of url: URL, expectedHex: String) throws {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        let actualHex = digest.map { String(format: "%02x", $0) }.joined()
        guard actualHex == expectedHex else {
            throw ModelDownloaderError.checksumMismatch(expected: expectedHex, actual: actualHex)
        }
    }

    // MARK: - Archive extraction

    /// Extract a bz2-compressed tar archive into `dir` using the system `tar`.
    private static func extractTarBz2(from archive: URL, into dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archive.path, "-C", dir.path]
        let err = Pipe()
        process.standardError = err

        // Drain stderr continuously to prevent 64 KB pipe buffer deadlock
        // when tar outputs verbose progress or error messages.
        let stderrCollector = DataCollector()
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { stderrCollector.append(d) }
        }

        try process.run()
        process.waitUntilExit()

        // Stop handler and drain any remaining bytes.
        err.fileHandleForReading.readabilityHandler = nil
        if let d = try? err.fileHandleForReading.readDataToEndOfFile(), !d.isEmpty {
            stderrCollector.append(d)
        }

        if process.terminationStatus != 0 {
            let msg = String(data: stderrCollector.snapshot, encoding: .utf8) ?? "unknown tar error"
            throw NSError(domain: "ModelDownloader", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "tar failed: \(msg)"])
        }
    }
}
