import XCTest
@testable import RecorderCore

final class SmokeTest: XCTestCase {
    func testLoggerAvailable() {
        Log.storage.info("smoke test log")
    }
}
