import XCTest
@testable import RecorderCore

final class MeetingMetadataMigrationTests: XCTestCase {
    func testDecodesChantier1JSONWithMissingNewFields() throws {
        // JSON as written by Chantier 1 (no calendarEventId/detectedApp/detectedCode)
        let json = """
        {"id":"2026-07-01_10h00","startedAt":"2026-07-01T08:00:00Z","source":"manual","appVersion":"0.1.0","models":{"whisper":"large-v3","diarization":"sherpa-pyannote-3.1"}}
        """.data(using: .utf8)!
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let meta = try dec.decode(MeetingMetadata.self, from: json)
        XCTAssertEqual(meta.id, "2026-07-01_10h00")
        XCTAssertNil(meta.calendarEventId)
        XCTAssertNil(meta.detectedApp)
        XCTAssertNil(meta.detectedCode)
    }

    func testEncodesAllNewFieldsWhenPresent() throws {
        let meta = MeetingMetadata(
            id: "s",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: nil,
            durationSeconds: nil,
            title: "Design review",
            source: .detected,
            appVersion: "0.2.0",
            models: .init(whisper: "large-v3", diarization: "sherpa-pyannote-3.1"),
            calendarEventId: "EK-12345",
            detectedApp: "meet",
            detectedCode: "abc-defg-hij"
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(meta)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["calendarEventId"] as? String, "EK-12345")
        XCTAssertEqual(dict["detectedApp"] as? String, "meet")
        XCTAssertEqual(dict["detectedCode"] as? String, "abc-defg-hij")
    }

    func testRoundTripAllFields() throws {
        let original = MeetingMetadata(
            id: "s",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_003_600),
            durationSeconds: 3600,
            title: "T",
            source: .detected,
            appVersion: "0.2.0",
            models: .init(whisper: "large-v3", diarization: "sherpa-pyannote-3.1"),
            calendarEventId: nil,
            detectedApp: "slack_huddle",
            detectedCode: "42"
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let data = try enc.encode(original)
        let round = try dec.decode(MeetingMetadata.self, from: data)
        XCTAssertEqual(round, original)
    }
}
