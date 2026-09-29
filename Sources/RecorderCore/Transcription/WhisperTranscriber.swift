import CoreML
import Foundation
import WhisperKit

public actor WhisperTranscriber: WhisperPreloading {
    private var kit: WhisperKit?
    private var model: ModelAsset
    private let language: String

    /// Max wait for WhisperKit's init. First run compiles the Core ML models
    /// (`large-v3` can take several minutes on cold cache) AND may fetch tokenizer
    /// files from HuggingFace. Observed cold init: ~4-5 min. 8 min gives headroom
    /// while still catching genuine hangs (e.g. a stalled HF request that would
    /// otherwise leave the pipeline stuck in `whisper_mic=in_progress` forever
    /// with no UI signal). Subsequent runs hit the local cache and complete in ms.
    public struct InitTimeoutError: Error, LocalizedError {
        public let seconds: Int
        public var errorDescription: String? {
            "WhisperKit init timed out after \(seconds)s (network fetch or Core ML compile stalled?)"
        }
    }
    private let initTimeoutSeconds: Int = 480

    public init(language: String = "fr",
                model: ModelAsset = ModelManifest.whisperLargeV3Turbo) {
        self.language = language
        self.model = model
    }

    /// Switches the Whisper variant (Settings → Advanced). Drops the resident
    /// model if it changes; the next transcription loads — and if needed
    /// first downloads — the new one via `ensureLoaded`.
    public func setModel(_ asset: ModelAsset) {
        guard asset.id != model.id else { return }
        model = asset
        kit = nil
    }

    /// Loads the model without transcribing anything — lets the chunked
    /// transcriber warm it during the first minutes of recording, so the
    /// first chunk starts on a hot model.
    public func preload() async throws {
        _ = try await ensureLoaded()
    }

    /// Releases the resident model (~3-4 GB for large-v3). Called by AppState
    /// once nothing is recording and no pipeline is running; the next
    /// transcription reloads it transparently via `ensureLoaded`.
    public func unload() {
        kit = nil
    }

    private func ensureLoaded() async throws -> WhisperKit {
        if let kit { return kit }
        let k = try await loadKit(computeOptions: nil)
        kit = k
        return k
    }

    /// Loads a WhisperKit instance for the current model. `computeOptions`
    /// nil = WhisperKit's default (Neural Engine for the heavy models);
    /// non-nil is used by the ANE-timeout fallback to force CPU+GPU. The
    /// caller decides whether to cache the result (`ensureLoaded` does,
    /// the fallback instance is deliberately throwaway).
    private func loadKit(computeOptions: ModelComputeOptions?) async throws -> WhisperKit {
        let modelFolder = ModelManifest.installedPath(for: model)
        // Lazy fetch: a variant picked in Settings but never downloaded (or
        // deleted from the model manager) is pulled on first use.
        try await ModelLibrary.downloadWhisperIfNeeded(model)
        let cfg = WhisperKitConfig(
            model: model.id,
            modelFolder: modelFolder.path,
            computeOptions: computeOptions,
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: true,
            download: true
        )
        let timeout = initTimeoutSeconds
        return try await withThrowingTaskGroup(of: WhisperKit.self) { group in
            group.addTask { try await WhisperKit(cfg) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                throw InitTimeoutError(seconds: timeout)
            }
            guard let result = try await group.next() else {
                throw InitTimeoutError(seconds: timeout)
            }
            group.cancelAll()
            return result
        }
    }

    /// Compute units for the ANE-timeout fallback: everything on CPU+GPU,
    /// nothing on the Neural Engine — the very unit that just timed out.
    private static var cpuGPUComputeOptions: ModelComputeOptions {
        ModelComputeOptions(
            melCompute: .cpuAndGPU,
            audioEncoderCompute: .cpuAndGPU,
            textDecoderCompute: .cpuAndGPU,
            prefillCompute: .cpuOnly
        )
    }

    /// True for the CoreML/ANE prediction timeouts seen under heavy system
    /// load, e.g. `Error Domain=com.apple.CoreML Code=0 "Timeout occurred
    /// while computing the asynchronous prediction using ML Program." …
    /// "E5RT: Submit Async failed … has timed out"`. Requires BOTH a
    /// timeout wording AND a CoreML/E5RT marker so it doesn't swallow our
    /// own `InitTimeoutError` or unrelated timeouts.
    ///
    /// English-substring matching is accepted: the observed incident string
    /// was English. A localized CoreML description would miss here and the
    /// error falls through to the job-level retry budget — degraded (no
    /// within-run CPU+GPU fallback), not broken.
    static func isANETimeout(_ error: Error) -> Bool {
        let desc = String(describing: error)
        let isTimeout = desc.localizedCaseInsensitiveContains("timeout")
            || desc.localizedCaseInsensitiveContains("timed out")
        let isCoreML = desc.contains("com.apple.CoreML")
            || desc.contains("E5RT")
            || desc.contains("ML Program")
        return isTimeout && isCoreML
    }

    /// Mirrors the pipeline's recording gate. While a recording is live the
    /// ANE-timeout fallback is disabled — it would load a second ~3-4 GB
    /// model exactly when the machine is already saturated (chunked live
    /// transcription calls `transcribe` DURING recording, and a pipeline
    /// whisper step can be mid-flight when a recording starts). AppState
    /// flips this in the same gate-stream consumer as
    /// `Pipeline.setRecordingActive`, preserving transition order.
    private var recordingActive = false

    public func setRecordingActive(_ active: Bool) {
        recordingActive = active
    }

    /// At most ONE throwaway CPU+GPU fallback kit may exist at a time —
    /// `kit.transcribe` is a suspension point, so two concurrent transcribes
    /// could otherwise each spawn one (~3-4 GB each).
    private var fallbackInFlight = false

    public func transcribe(wavPath: URL, to jsonPath: URL) async throws {
        let kit = try await ensureLoaded()
        do {
            try await transcribe(with: kit, wavPath: wavPath, to: jsonPath)
        } catch where Self.isANETimeout(error) {
            // Transient ANE saturation (heavy system load): retry ONCE on
            // CPU+GPU with a temporary instance. The resident `kit` (used by
            // chunked live transcription) is left untouched — the ANE config
            // stays the fast path for the next transcription.
            //
            // Skipped (original error rethrown) while a recording is live or
            // another fallback is already running: the job-level retryCount
            // budget re-runs the job after the meeting — that is the designed
            // complement. Accepted worst case: a recording that starts AFTER
            // a fallback began coexists with that one temporary kit until it
            // finishes; the flags only prevent starting new fallbacks.
            guard !recordingActive, !fallbackInFlight else {
                Log.transcription.warning(
                    "ANE timeout on \(wavPath.lastPathComponent, privacy: .public) — fallback skipped (recordingActive=\(self.recordingActive), fallbackInFlight=\(self.fallbackInFlight)); deferring to job-level retry")
                throw error
            }
            fallbackInFlight = true
            defer { fallbackInFlight = false }
            Log.transcription.warning(
                "ANE timeout transcribing \(wavPath.lastPathComponent, privacy: .public) — retrying once on CPU+GPU: \(String(describing: error), privacy: .public)")
            let fallbackKit = try await loadKit(computeOptions: Self.cpuGPUComputeOptions)
            try await transcribe(with: fallbackKit, wavPath: wavPath, to: jsonPath)
        }
    }

    private func transcribe(with kit: WhisperKit, wavPath: URL, to jsonPath: URL) async throws {
        let opts = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0.0,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: 5,
            withoutTimestamps: false,
            wordTimestamps: false
        )
        let results: [TranscriptionResult] = try await kit.transcribe(
            audioPath: wavPath.path,
            decodeOptions: opts
        )
        var segments: [WhisperSegment] = []
        for r in results {
            for s in r.segments {
                let cleaned = Self.stripSpecialTokens(s.text)
                if cleaned.isEmpty { continue }
                if Self.isKnownHallucination(cleaned) { continue }
                segments.append(
                    WhisperSegment(
                        start: Double(s.start),
                        end: Double(s.end),
                        text: cleaned,
                        confidence: Double(s.avgLogprob)
                    )
                )
            }
        }
        try AtomicJSON.write(segments, to: jsonPath)
    }

    /// Whisper hallucinates subtitle/channel credits on silent or near-silent
    /// audio — artifacts of its training data (TV captions), not speech. The
    /// phrases below are distinctive enough that they cannot plausibly occur
    /// in a real meeting segment, so a substring match on the normalized text
    /// is safe. Matched segments are dropped entirely.
    static func isKnownHallucination(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR"))
        let patterns = [
            "sous-titrage societe radio-canada",
            "sous-titrage st' 501",
            "sous-titrage st'501",
            "sous-titrage fr 2021",
            "sous-titres realises par la communaute d'amara.org",
            "sous-titres realises para la communaute d'amara.org",
            "soustitreur.com",
            "sous-titrage par red bee media",
            "merci d'avoir regarde cette video",
            "abonnez-vous a la chaine",
            "n'oubliez pas de vous abonner",
        ]
        return patterns.contains { normalized.contains($0) }
    }

    /// Removes Whisper special tokens like `<|startoftranscript|>`, `<|fr|>`,
    /// `<|transcribe|>`, `<|0.00|>`, `<|endoftext|>` that WhisperKit sometimes
    /// leaks into `segment.text`, then trims whitespace.
    private static func stripSpecialTokens(_ text: String) -> String {
        let pattern = #"<\|[^|>]*\|>"#
        let stripped = text.replacingOccurrences(of: pattern, with: "",
                                                 options: .regularExpression)
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
