import XCTest
import Combine
@testable import Onyx

/// The transcript must follow the playhead without being rebuilt at the
/// player's tick rate. `AudioPlayer` publishes `currentTime` 10×/s — a view
/// observing it redraws 10×/s *whatever property it reads*, because
/// `@ObservedObject` invalidates on `objectWillChange`, not per-property. So
/// the transcript observes this object instead, which only publishes when the
/// quantised playhead actually moves.
@MainActor
final class TranscriptPlayheadTests: XCTestCase {

    private func countPublishes(_ p: TranscriptPlayhead,
                                _ body: () -> Void) -> Int {
        var n = 0
        let c = p.objectWillChange.sink { _ in n += 1 }
        body()
        c.cancel()
        return n
    }

    func test_quantisesToTheConfiguredStep() {
        let p = TranscriptPlayhead(quantum: 0.5)
        p.update(0.0);  XCTAssertEqual(p.seconds, 0.0)
        p.update(0.49); XCTAssertEqual(p.seconds, 0.0)
        p.update(0.5);  XCTAssertEqual(p.seconds, 0.5)
        p.update(0.99); XCTAssertEqual(p.seconds, 0.5)
        p.update(7.3);  XCTAssertEqual(p.seconds, 7.0)
    }

    /// The redraw-storm guard: eleven 10 Hz ticks covering 0.0…1.0 s cross two
    /// 0.5 s boundaries, so the transcript is invalidated twice, not eleven
    /// times. (Starting at 0, the tick at 0.0 is not a change.)
    func test_doesNotRepublishWithinTheSameQuantum() {
        let p = TranscriptPlayhead(quantum: 0.5)
        let n = countPublishes(p) {
            for i in 0...10 { p.update(Double(i) * 0.1) }
        }
        XCTAssertEqual(n, 2, "expected one publish per crossed quantum, got \(n)")
    }

    func test_seekingBackwardsPublishes() {
        let p = TranscriptPlayhead(quantum: 0.5)
        p.update(40)
        let n = countPublishes(p) { p.update(3) }
        XCTAssertEqual(n, 1)
        XCTAssertEqual(p.seconds, 3)
    }

    /// These values come from `AVAudioPlayer.currentTime` and from JSON on disk.
    func test_nonFiniteAndNegativeInputsCollapseToZero() {
        let p = TranscriptPlayhead(quantum: 0.5)
        p.update(12)
        p.update(.nan);      XCTAssertEqual(p.seconds, 0)
        p.update(12)
        p.update(-7);        XCTAssertEqual(p.seconds, 0)
        p.update(12)
        p.update(.infinity); XCTAssertEqual(p.seconds, 0)
    }

    func test_resetPublishesOnlyWhenNotAlreadyZero() {
        let p = TranscriptPlayhead(quantum: 0.5)
        XCTAssertEqual(countPublishes(p) { p.reset() }, 0)
        p.update(9)
        XCTAssertEqual(countPublishes(p) { p.reset() }, 1)
        XCTAssertEqual(p.seconds, 0)
    }

    /// A zero or negative quantum would divide by zero / publish on every tick.
    func test_degenerateQuantumIsSanitised() {
        let p = TranscriptPlayhead(quantum: 0)
        p.update(1.234)
        XCTAssertTrue(p.seconds.isFinite)
        let n = countPublishes(p) { for i in 0..<10 { p.update(1.234 + Double(i) * 0.001) } }
        XCTAssertLessThanOrEqual(n, 1, "a degenerate quantum must not publish per tick")
    }
}
