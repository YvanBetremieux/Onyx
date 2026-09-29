import XCTest
@testable import RecorderCore

final class WaveformFileTests: XCTestCase {
    func test_roundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = WaveformFile(peaks: [0.1, 0.5, 0.9], sampleRate: 16_000, bucketSizeMs: 50)
        try file.write(to: tmp)
        let back = try WaveformFile.read(from: tmp)
        XCTAssertEqual(back.peaks, [0.1, 0.5, 0.9])
        XCTAssertEqual(back.sampleRate, 16_000)
        XCTAssertEqual(back.bucketSizeMs, 50)
    }
}
