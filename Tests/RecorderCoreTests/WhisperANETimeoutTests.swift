import XCTest
@testable import RecorderCore

final class WhisperANETimeoutTests: XCTestCase {
    private struct StringError: Error, CustomStringConvertible {
        let description: String
    }

    /// The exact error observed during the 2026-08-06 incident (two meetings
    /// failed transcription while the machine was transiently saturated).
    func testMatchesRealIncidentError() {
        let incident = StringError(description: """
        Error Domain=com.apple.CoreML Code=0 "Timeout occurred while computing \
        the asynchronous prediction using ML Program." UserInfo={NSLocalizedDescription=\
        Timeout occurred while computing the asynchronous prediction using ML Program. \
        E5RT: Submit Async failed E5RT encountered an internal error: worker for request \
        has timed out (11)}
        """)
        XCTAssertTrue(WhisperTranscriber.isANETimeout(incident))
    }

    func testMatchesE5RTMarkerWithoutCoreMLDomain() {
        let e = StringError(description:
            "E5RT: Submit Async failed — worker for request has timed out (11)")
        XCTAssertTrue(WhisperTranscriber.isANETimeout(e))
    }

    func testDoesNotMatchUnrelatedError() {
        let e = StringError(description: "The file couldn't be opened because there is no such file.")
        XCTAssertFalse(WhisperTranscriber.isANETimeout(e))
    }

    func testDoesNotMatchGenericTimeoutWithoutCoreMLMarker() {
        let e = StringError(description: "URLSession request timed out after 60s")
        XCTAssertFalse(WhisperTranscriber.isANETimeout(e))
    }

    /// Our own init watchdog must not trip the ANE fallback — a stalled
    /// model download/compile is not a prediction timeout.
    func testDoesNotMatchWhisperKitInitTimeout() {
        let e = WhisperTranscriber.InitTimeoutError(seconds: 480)
        XCTAssertFalse(WhisperTranscriber.isANETimeout(e))
    }

    func testDoesNotMatchCoreMLErrorWithoutTimeout() {
        let e = StringError(description:
            "Error Domain=com.apple.CoreML Code=1 \"Model file is corrupt\"")
        XCTAssertFalse(WhisperTranscriber.isANETimeout(e))
    }
}
