import XCTest
@testable import Onyx

/// x ↔ time mapping for the scrubber. Extracted from the view because the
/// gesture that feeds it is the single easiest thing to get wrong here (see
/// `ResizableSplit`, where a handle-local `location` was read as if it were
/// container-local) and because `Int(nan)` traps.
final class AudioScrubberGeometryTests: XCTestCase {

    func test_timeAtX_mapsLinearly() {
        XCTAssertEqual(AudioScrubberGeometry.time(atX: 0, width: 600, duration: 120), 0)
        XCTAssertEqual(AudioScrubberGeometry.time(atX: 300, width: 600, duration: 120), 60)
        XCTAssertEqual(AudioScrubberGeometry.time(atX: 600, width: 600, duration: 120), 120)
    }

    /// A drag that leaves the waveform reports x outside 0...width.
    func test_timeAtX_clampsOutsideBounds() {
        XCTAssertEqual(AudioScrubberGeometry.time(atX: -400, width: 600, duration: 120), 0)
        XCTAssertEqual(AudioScrubberGeometry.time(atX: 9_999, width: 600, duration: 120), 120)
    }

    func test_timeAtX_degenerateInputs() {
        XCTAssertEqual(AudioScrubberGeometry.time(atX: 100, width: 0, duration: 120), 0)
        XCTAssertEqual(AudioScrubberGeometry.time(atX: 100, width: -600, duration: 120), 0)
        XCTAssertEqual(AudioScrubberGeometry.time(atX: 100, width: 600, duration: 0), 0)
        XCTAssertEqual(AudioScrubberGeometry.time(atX: .nan, width: 600, duration: 120), 0)
        XCTAssertEqual(AudioScrubberGeometry.time(atX: 100, width: .nan, duration: 120), 0)
        XCTAssertEqual(AudioScrubberGeometry.time(atX: 100, width: 600, duration: .nan), 0)
    }

    func test_progress_isUnitClamped() {
        XCTAssertEqual(AudioScrubberGeometry.progress(currentTime: 30, duration: 120), 0.25,
                       accuracy: 1e-9)
        XCTAssertEqual(AudioScrubberGeometry.progress(currentTime: 0, duration: 0), 0)
        XCTAssertEqual(AudioScrubberGeometry.progress(currentTime: 500, duration: 120), 1)
        XCTAssertEqual(AudioScrubberGeometry.progress(currentTime: -5, duration: 120), 0)
        XCTAssertEqual(AudioScrubberGeometry.progress(currentTime: .nan, duration: 120), 0)
        XCTAssertEqual(AudioScrubberGeometry.progress(currentTime: 10, duration: .nan), 0)
    }

    /// The plan's `String(format: "%.2gx", rate)` renders 1.25 as "1.2x".
    func test_speedLabel() {
        XCTAssertEqual(AudioScrubberBar.label(for: 1.0), "1×")
        XCTAssertEqual(AudioScrubberBar.label(for: 2.0), "2×")
        XCTAssertEqual(AudioScrubberBar.label(for: 1.5), "1.5×")
        XCTAssertEqual(AudioScrubberBar.label(for: 1.25), "1.25×")
        XCTAssertEqual(AudioScrubberBar.label(for: 0.75), "0.75×")
        XCTAssertEqual(AudioScrubberBar.label(for: .nan), "1×")
    }
}
