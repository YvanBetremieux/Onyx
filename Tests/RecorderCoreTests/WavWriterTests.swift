import XCTest
@testable import RecorderCore

final class WavWriterTests: XCTestCase {
    func testProducesValidWavHeaderAfterFinish() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("t-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let writer = try WavWriter(url: tmp, sampleRate: 16000, channels: 1)
        let samples = [Float](repeating: 0.1, count: 16000)
        try samples.withUnsafeBufferPointer { try writer.write($0) }
        try writer.finish()

        let data = try Data(contentsOf: tmp)
        XCTAssertGreaterThan(data.count, 44)
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data[36..<40], encoding: .ascii), "data")
        XCTAssertEqual(data[20], 3); XCTAssertEqual(data[21], 0)
    }

    func testHeaderRewriteDuringRecordingKeepsFileReadable() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("t-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let writer = try WavWriter(url: tmp, sampleRate: 16000, channels: 1)
        let block = [Float](repeating: 0.0, count: 16000)
        try block.withUnsafeBufferPointer { try writer.write($0) }
        try writer.flushHeader()

        let mid = try Data(contentsOf: tmp)
        let chunkSize = mid.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertGreaterThan(chunkSize, 0)
    }

    /// Regression for the 2026-07-31 crash: `WavWriter.flushHeader` used to
    /// trap on `UInt32(byteCount)` once byteCount exceeded UInt32.max. The
    /// cap now refuses further writes before that can happen and the file
    /// stays valid.
    func testWriteRefusesSamplesBeyondCapAndFileRemainsValid() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("t-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let writer = try WavWriter(url: tmp, sampleRate: 16000, channels: 1)
        // 4000 floats = 16 KB. Cap = 20 KB → first write fits, second overflows.
        writer.cap = 20_000
        let block = [Float](repeating: 0.5, count: 4000)

        try block.withUnsafeBufferPointer { try writer.write($0) }
        XCTAssertFalse(writer.sealed)

        XCTAssertThrowsError(
            try block.withUnsafeBufferPointer { try writer.write($0) }
        ) { err in
            guard case WavWriterError.sizeCapReached = err else {
                return XCTFail("Expected WavWriterError.sizeCapReached, got \(err)")
            }
        }
        XCTAssertTrue(writer.sealed)

        // A subsequent write after sealing is a silent no-op (no throw, no data).
        try block.withUnsafeBufferPointer { try writer.write($0) }

        try writer.finish()

        // The file must have a valid header reflecting only the bytes that
        // were actually written (the first block).
        let data = try Data(contentsOf: tmp)
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data[36..<40], encoding: .ascii), "data")
        let dataChunkSize = data.subdata(in: 40..<44)
            .withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(dataChunkSize, UInt32(4000 * MemoryLayout<Float>.stride))
        XCTAssertEqual(data.count, 44 + 4000 * MemoryLayout<Float>.stride)
    }

    func testWriteAfterFinishIsSilentNoOp() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.wav")
        let w = try WavWriter(url: url, sampleRate: 16_000, channels: 1)
        let samples = [Float](repeating: 0.5, count: 256)
        try samples.withUnsafeBufferPointer { try w.write($0) }
        try w.finish()
        let sizeAfterFinish = try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as! UInt64
        // Must neither throw nor write.
        try samples.withUnsafeBufferPointer { try w.write($0) }
        let sizeAfterLateWrite = try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as! UInt64
        XCTAssertEqual(sizeAfterFinish, sizeAfterLateWrite)
    }
}
