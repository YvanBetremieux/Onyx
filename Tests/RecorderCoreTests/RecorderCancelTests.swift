import XCTest
@testable import RecorderCore

@available(macOS 13.0, *)
final class RecorderCancelTests: XCTestCase {
    func testCancelDeletesMeetingFolder() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let storage = MeetingStorage(root: tmp)
        let recorder = Recorder(storage: storage)

        // We can't call start() in this test — it opens the mic and system audio,
        // which requires permissions in CI. Instead, we create a meeting folder
        // through MeetingStorage and drive cancel() directly with those paths.
        let paths = try storage.createMeeting(startedAt: Date())
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.root.path))

        try await recorder.cancel(paths: paths)

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.root.path),
                       "cancel() must delete the meeting folder")
    }
}
