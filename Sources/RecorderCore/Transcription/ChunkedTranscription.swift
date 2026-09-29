import Foundation

// Chunked live transcription (chantier 4).
//
// While a meeting is being recorded, `ChunkedTranscriber` slices the growing
// WAVs every `chunkSeconds` and transcribes each slice immediately, with the
// Whisper model loaded once at recording start and kept resident. At stop,
// only the final partial chunk remains to transcribe, so the pipeline's
// whisper steps become a cheap assembly instead of a 0.4×-realtime crawl over
// the whole meeting.
//
// Safety model: chunks are strictly a CACHE. The pipeline assembles them only
// when they cover the entire recording contiguously; any gap (chunking
// disabled mid-way, a failed chunk, a crash) makes `ChunkAssembly` return nil
// and the pipeline falls back to the classic full-file transcription. Nothing
// the chunker does can ever lose audio — it only ever *reads* the WAVs.

/// One transcribed slice of the meeting. `mic`/`system` segments carry
/// ABSOLUTE timestamps (chunk offset already applied).
public struct TranscriptChunk: Codable, Sendable, Equatable {
    public let index: Int
    public let start: Double
    public let end: Double
    public let mic: [WhisperSegment]
    public let system: [WhisperSegment]

    public init(index: Int, start: Double, end: Double,
                mic: [WhisperSegment], system: [WhisperSegment]) {
        self.index = index; self.start = start; self.end = end
        self.mic = mic; self.system = system
    }
}

public extension MeetingPaths {
    /// Per-chunk transcription results (`chunk_000.json`, …) plus the
    /// transient chunk WAVs while one is being transcribed.
    var transcriptChunks: URL {
        transcripts.appendingPathComponent("chunks", isDirectory: true)
    }
    func chunkFile(_ index: Int) -> URL {
        transcriptChunks.appendingPathComponent(String(format: "chunk_%03d.json", index))
    }
}

/// Byte-level slicing of the recorder's WAVs (16 kHz mono Float32, 44-byte
/// header — see `WavWriter`). Works on a *growing* file: the stale header
/// written at open time is ignored, available audio is derived from the file
/// size.
public enum ChunkWav {
    static let headerBytes: UInt64 = 44
    static let bytesPerSecond: Double = 16_000 * 4   // Float32 mono @ 16 kHz

    /// Seconds of audio currently present in `wav` (0 if absent/empty).
    public static func availableSeconds(in wav: URL) -> Double {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: wav.path),
              let size = attrs[.size] as? UInt64, size > headerBytes else { return 0 }
        return Double(size - headerBytes) / bytesPerSecond
    }

    /// RMS level of a WAV's samples (0 = pure silence). Streamed in 1 MB
    /// blocks, so a 20-min chunk costs one sequential read, no full buffer.
    public static func rms(of wav: URL) -> Double {
        guard let handle = try? FileHandle(forReadingFrom: wav) else { return 0 }
        defer { try? handle.close() }
        _ = try? handle.read(upToCount: Int(headerBytes))
        var sumSquares = 0.0
        var count = 0
        while let block = try? handle.read(upToCount: 1_048_576), !block.isEmpty {
            block.withUnsafeBytes { raw in
                for f in raw.bindMemory(to: Float.self) {
                    sumSquares += Double(f) * Double(f)
                }
            }
            count += block.count / 4
        }
        guard count > 0 else { return 0 }
        return (sumSquares / Double(count)).squareRoot()
    }

    /// Below this RMS a slice is considered speech-free: Whisper is skipped
    /// entirely (its classic failure mode on silence is hallucinating TV
    /// caption credits — "Sous-titrage Société Radio-Canada" et al). Real
    /// speech sits around 0.01-0.1 RMS; a quiet room on an open mic around
    /// 0.001-0.005; this threshold is safely below both.
    public static let silenceRMSThreshold = 0.0005

    /// Extracts `[startSeconds, endSeconds)` of `source` into a standalone
    /// valid WAV at `dest`. Returns false (writing nothing) when the source
    /// does not yet contain `endSeconds` of audio.
    @discardableResult
    public static func extract(from source: URL,
                               startSeconds: Double, endSeconds: Double,
                               to dest: URL) throws -> Bool {
        guard endSeconds > startSeconds else { return false }
        guard availableSeconds(in: source) >= endSeconds - 0.001 else { return false }
        // Align to whole Float32 samples so a slice can never split one.
        let startByte = headerBytes + UInt64(startSeconds * bytesPerSecond) / 4 * 4
        let endByte   = headerBytes + UInt64(endSeconds * bytesPerSecond) / 4 * 4
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        try handle.seek(toOffset: startByte)
        let payload = try handle.read(upToCount: Int(endByte - startByte)) ?? Data()
        guard !payload.isEmpty else { return false }

        var out = Data(capacity: 44 + payload.count)
        out.append(contentsOf: "RIFF".utf8)
        out.appendLE(UInt32(36 + payload.count))
        out.append(contentsOf: "WAVE".utf8)
        out.append(contentsOf: "fmt ".utf8)
        out.appendLE(UInt32(16))
        out.appendLE(UInt16(3))            // IEEE float
        out.appendLE(UInt16(1))            // mono
        out.appendLE(UInt32(16_000))
        out.appendLE(UInt32(16_000 * 4))   // byte rate
        out.appendLE(UInt16(4))            // block align
        out.appendLE(UInt16(32))           // bits per sample
        out.append(contentsOf: "data".utf8)
        out.appendLE(UInt32(payload.count))
        out.append(payload)
        try out.write(to: dest, options: .atomic)
        return true
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

/// Whisper implementations that can load their model ahead of the first
/// transcription — used to hide the (minutes-long on cold cache) model load
/// inside the first chunk's recording window.
public protocol WhisperPreloading {
    func preload() async throws
}

/// Live chunk-by-chunk transcription of a recording in progress.
///
/// Lifecycle: `start()` right after the recorder starts (warms the model and
/// begins the polling loop), `finish()` after the recorder stops (transcribes
/// whatever remains, including the final partial chunk). Both WAV channels of
/// a chunk are transcribed before the next chunk starts, so at most one
/// whisper inference runs at a time.
public actor ChunkedTranscriber {
    private let paths: MeetingPaths
    private let chunkSeconds: Double
    private let whisper: any WhisperTranscribing
    /// Fraction of the recorded audio transcribed so far (0…1), emitted after
    /// every chunk — drives the sidebar's "Transcription… N %".
    private let onProgress: (@Sendable (Double) -> Void)?
    private var nextIndex = 0
    private var loop: Task<Void, Never>?
    /// Set on the first chunk error: chunking stops (leaving a coverage gap →
    /// the pipeline falls back to full transcription) instead of retrying a
    /// broken configuration every chunk.
    private var failed = false

    public init(paths: MeetingPaths,
                chunkSeconds: Double,
                whisper: any WhisperTranscribing,
                onProgress: (@Sendable (Double) -> Void)? = nil) {
        self.paths = paths
        // Lower bound guards against a pathological zero/negative config; the
        // Settings slider enforces its own 1-20 min range on top.
        self.chunkSeconds = max(1, chunkSeconds)
        self.whisper = whisper
        self.onProgress = onProgress
    }

    public func start() {
        try? FileManager.default.createDirectory(at: paths.transcriptChunks,
                                                 withIntermediateDirectories: true)
        // Warm the model now, during the first chunk's recording window, so
        // the first transcription starts on a hot model.
        if let preloadable = whisper as? WhisperPreloading {
            Task { try? await preloadable.preload() }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                await self.processReadyChunks()
            }
        }
        Log.pipeline.info(
            "ChunkedTranscriber started for \(self.paths.slug, privacy: .public) (chunk=\(Int(self.chunkSeconds))s)")
    }

    /// Stops chunking without transcribing the remainder — the cancel path,
    /// where the meeting folder is about to be deleted.
    public func abort() async {
        loop?.cancel()
        await loop?.value
        loop = nil
        failed = true
    }

    /// Transcribes everything still missing — called once the recorder has
    /// finalized the WAVs. On return, chunk files cover the whole recording
    /// (unless a chunk failed, in which case the pipeline falls back).
    public func finish() async {
        loop?.cancel()
        // The loop awaits `processReadyChunks` between sleeps; awaiting its
        // completion guarantees no chunk job is still in flight.
        await loop?.value
        loop = nil
        guard !failed else { return }
        let total = ChunkWav.availableSeconds(in: paths.micWav)
        while !failed, Double(nextIndex) * chunkSeconds < total - 0.25 {
            let start = Double(nextIndex) * chunkSeconds
            let end = min(start + chunkSeconds, total)
            await processChunk(start: start, end: end)
        }
        Log.pipeline.info(
            "ChunkedTranscriber finished for \(self.paths.slug, privacy: .public): \(self.nextIndex) chunks, failed=\(self.failed)")
    }

    private func processReadyChunks() async {
        guard !failed else { return }
        // Only full chunks during recording; the final partial one is
        // `finish()`'s job. Recompute availability each turn: transcription
        // takes ~0.4× the chunk, so several chunks may have become ready.
        while !failed {
            let start = Double(nextIndex) * chunkSeconds
            let end = start + chunkSeconds
            guard ChunkWav.availableSeconds(in: paths.micWav) >= end + 0.5,
                  ChunkWav.availableSeconds(in: paths.systemWav) >= end + 0.5 else { return }
            await processChunk(start: start, end: end)
        }
    }

    private func processChunk(start: Double, end: Double) async {
        let index = nextIndex
        let micWav = paths.transcriptChunks.appendingPathComponent("mic_\(index).wav")
        let sysWav = paths.transcriptChunks.appendingPathComponent("sys_\(index).wav")
        let micJson = paths.transcriptChunks.appendingPathComponent("mic_\(index).json")
        let sysJson = paths.transcriptChunks.appendingPathComponent("sys_\(index).json")
        defer {
            for f in [micWav, sysWav, micJson, sysJson] {
                try? FileManager.default.removeItem(at: f)
            }
        }
        do {
            guard try ChunkWav.extract(from: paths.micWav, startSeconds: start,
                                       endSeconds: end, to: micWav),
                  try ChunkWav.extract(from: paths.systemWav, startSeconds: start,
                                       endSeconds: end, to: sysWav) else { return }
            // Energy gate: a speech-free slice never reaches Whisper — that is
            // where the "Sous-titrage Société Radio-Canada" hallucinations
            // come from (and it saves the inference outright). Typical case:
            // the mic while the user only listens.
            let mic: [WhisperSegment]
            if ChunkWav.rms(of: micWav) < ChunkWav.silenceRMSThreshold {
                mic = []
            } else {
                try await whisper.transcribe(wavPath: micWav, to: micJson)
                mic = try AtomicJSON.read([WhisperSegment].self, from: micJson)
            }
            let sys: [WhisperSegment]
            if ChunkWav.rms(of: sysWav) < ChunkWav.silenceRMSThreshold {
                sys = []
            } else {
                try await whisper.transcribe(wavPath: sysWav, to: sysJson)
                sys = try AtomicJSON.read([WhisperSegment].self, from: sysJson)
            }
            let chunk = TranscriptChunk(
                index: index, start: start, end: end,
                mic: mic.map { $0.offset(by: start) },
                system: sys.map { $0.offset(by: start) })
            try AtomicJSON.write(chunk, to: paths.chunkFile(index))
            nextIndex += 1
            // Fraction of the audio recorded SO FAR — during recording the
            // denominator still grows, after stop it is the final duration.
            let total = ChunkWav.availableSeconds(in: paths.micWav)
            if total > 0 { onProgress?(min(1, end / total)) }
            Log.pipeline.info(
                "Chunk \(index) transcribed for \(self.paths.slug, privacy: .public) [\(Int(start))s–\(Int(end))s]")
        } catch {
            failed = true
            Log.pipeline.error(
                "Chunk \(index) failed for \(self.paths.slug, privacy: .public): \(String(describing: error), privacy: .public) — falling back to full transcription")
        }
    }
}

private extension WhisperSegment {
    func offset(by seconds: Double) -> WhisperSegment {
        WhisperSegment(start: start + seconds, end: end + seconds,
                       text: text, confidence: confidence)
    }
}

/// Turns the chunk cache back into full-meeting whisper results.
public enum ChunkAssembly {
    public enum Channel { case mic, system }

    /// All chunk files, sorted by index. Public for the pipeline and tests.
    public static func chunks(paths: MeetingPaths) -> [TranscriptChunk] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: paths.transcriptChunks, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.lastPathComponent.hasPrefix("chunk_") }
            .compactMap { try? AtomicJSON.read(TranscriptChunk.self, from: $0) }
            .sorted { $0.index < $1.index }
    }

    /// Full-meeting segments for one channel, or nil unless the chunks cover
    /// `[0, durationSeconds)` contiguously — the pipeline then falls back to
    /// classic full-file transcription. All-or-nothing on purpose: a partial
    /// assembly would silently drop audio.
    public static func assembledSegments(paths: MeetingPaths,
                                         channel: Channel,
                                         durationSeconds: Double,
                                         tolerance: Double = 1.5) -> [WhisperSegment]? {
        let all = chunks(paths: paths)
        guard !all.isEmpty else { return nil }
        guard all.first!.start <= tolerance else { return nil }
        for (a, b) in zip(all, all.dropFirst()) {
            guard b.index == a.index + 1, abs(b.start - a.end) <= tolerance else { return nil }
        }
        guard all.last!.end >= durationSeconds - tolerance else { return nil }
        switch channel {
        case .mic:    return all.flatMap(\.mic)
        case .system: return all.flatMap(\.system)
        }
    }
}
