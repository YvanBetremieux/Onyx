import Foundation

public enum WavWriterError: Error {
    /// Emitted once by `write` when the writer has just reached its size cap.
    /// After this throw the writer is "sealed": subsequent `write` calls are
    /// silent no-ops and the already-written data + its header remain valid.
    case sizeCapReached
}

public final class WavWriter {
    /// Default cap on the `data` chunk size — the WAV RIFF/data size fields
    /// are `UInt32`, so anything ≥ `UInt32.max` would trap `UInt32(byteCount)`
    /// in `flushHeader`. We stop ~1 MB below that so a large in-flight buffer
    /// can never straddle the threshold.
    internal static let defaultCap: UInt64 = UInt64(UInt32.max) - 1_048_576

    /// The active cap for this instance. Mutable and `internal` so tests can
    /// lower it to exercise the cap path without writing 4 GB of samples.
    internal var cap: UInt64 = WavWriter.defaultCap

    /// Number of consecutive write failures before sealing the writer.
    /// (Same graceful-stop path as size cap — prevents silent data loss on full disk.)
    internal var writeFailureSealThreshold = 50
    private var consecutiveWriteFailures = 0

    private let handle: FileHandle
    private let sampleRate: UInt32
    private let channels: UInt16
    private let bitsPerSample: UInt16 = 32
    private var byteCount: UInt64 = 0
    private var closed = false

    /// `true` once the writer has hit `maxDataBytes` and refused a write.
    /// Read from other threads without the lock — `Bool` load/store is atomic
    /// on the platforms we target, and a one-cycle stale read is harmless.
    public private(set) var sealed = false

    /// Serializes access to `handle` and `byteCount`. `write` runs on the
    /// audio tap thread; `flushHeader` runs on the flush task; `finish` runs
    /// on the stop path — all three can race without this lock.
    private let lock = NSLock()

    public init(url: URL, sampleRate: Int, channels: Int) throws {
        self.sampleRate = UInt32(sampleRate)
        self.channels = UInt16(channels)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
        try writeHeader(dataBytes: 0)
    }

    public func write(_ samples: UnsafeBufferPointer<Float>) throws {
        lock.lock(); defer { lock.unlock() }
        if sealed || closed { return }
        let addBytes = UInt64(samples.count) * UInt64(MemoryLayout<Float>.stride)
        if byteCount + addBytes > cap {
            sealed = true
            Log.recorder.error(
                "WavWriter: size cap reached at \(self.byteCount) bytes; sealing writer")
            throw WavWriterError.sizeCapReached
        }
        let data = Data(buffer: samples)
        do {
            try handle.write(contentsOf: data)
            byteCount += UInt64(data.count)
            consecutiveWriteFailures = 0
        } catch {
            consecutiveWriteFailures += 1
            if consecutiveWriteFailures >= writeFailureSealThreshold {
                sealed = true
                Log.recorder.error(
                    "WavWriter: \(self.consecutiveWriteFailures) consecutive write failures (disk full?); sealing writer")
            }
            throw error
        }
    }

    public func flushHeader() throws {
        lock.lock(); defer { lock.unlock() }
        try handle.synchronize()
        let cur = try handle.offset()
        try handle.seek(toOffset: 0)
        try writeHeader(dataBytes: UInt32(byteCount))
        try handle.seek(toOffset: cur)
        try handle.synchronize()
    }

    public func finish() throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        // Inline the flushHeader body — NSLock isn't recursive.
        try handle.synchronize()
        try handle.seek(toOffset: 0)
        try writeHeader(dataBytes: UInt32(byteCount))
        try handle.close()
        closed = true
    }

    deinit { try? finish() }

    private func writeHeader(dataBytes: UInt32) throws {
        var header = Data(count: 44)
        header.replaceSubrange(0..<4,  with: "RIFF".data(using: .ascii)!)
        header.setLE(UInt32(36 &+ dataBytes),      at: 4)
        header.replaceSubrange(8..<12, with: "WAVE".data(using: .ascii)!)
        header.replaceSubrange(12..<16, with: "fmt ".data(using: .ascii)!)
        header.setLE(UInt32(16),                   at: 16)
        header.setLE(UInt16(3),                    at: 20)
        header.setLE(channels,                     at: 22)
        header.setLE(sampleRate,                   at: 24)
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        header.setLE(byteRate,                     at: 28)
        let blockAlign = channels * (bitsPerSample / 8)
        header.setLE(blockAlign,                   at: 32)
        header.setLE(bitsPerSample,                at: 34)
        header.replaceSubrange(36..<40, with: "data".data(using: .ascii)!)
        header.setLE(dataBytes,                    at: 40)
        try handle.write(contentsOf: header)
    }
}

private extension Data {
    mutating func setLE<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { bytes in
            replaceSubrange(offset..<offset + MemoryLayout<T>.size, with: bytes)
        }
    }
}
