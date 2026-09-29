import XCTest
@testable import RecorderCore

final class MeetingMetadataTests: XCTestCase {
    func testRoundTripJSON() throws {
        let started = Date(timeIntervalSince1970: 1_784_819_535)
        let meta = MeetingMetadata(
            id: "2026-07-22_14h32",
            startedAt: started,
            endedAt: nil,
            durationSeconds: nil,
            title: nil,
            source: .manual,
            appVersion: "0.1.0",
            models: .init(whisper: "large-v3", diarization: "sherpa-pyannote-3.1")
        )
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meta-\(UUID().uuidString).json")
        try AtomicJSON.write(meta, to: tmp)
        let back = try AtomicJSON.read(MeetingMetadata.self, from: tmp)
        XCTAssertEqual(back, meta)
    }
}
