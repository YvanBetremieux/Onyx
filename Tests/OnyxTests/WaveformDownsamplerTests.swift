import XCTest
@testable import Onyx

/// `waveform.json` holds one true-peak value per 50 ms bucket — 144 000 floats
/// for a 2-hour meeting. A `Canvas` has ~600 points of width to draw them into,
/// so the peaks MUST be reduced to one value per drawn column. These tests pin
/// down the two properties that make that reduction honest: it must use `max`
/// (a mean smears transients and renders speech as a flat band) and it must
/// cover every input sample (a strided pick would drop 99.6% of the data and
/// could miss every loud passage).
final class WaveformDownsamplerTests: XCTestCase {

    func test_emptyAndDegenerateInputs() {
        XCTAssertEqual(WaveformDownsampler.downsample([], to: 100), [])
        XCTAssertEqual(WaveformDownsampler.downsample([0.1, 0.2], to: 0), [])
        XCTAssertEqual(WaveformDownsampler.downsample([0.1, 0.2], to: -5), [])
    }

    /// Fewer peaks than columns: nothing to reduce, hand them back untouched
    /// rather than stretching (the view spaces the bars out instead).
    func test_fewerPeaksThanColumnsIsIdentity() {
        let peaks: [Float] = [0.1, 0.9, 0.4]
        XCTAssertEqual(WaveformDownsampler.downsample(peaks, to: 10), peaks)
        XCTAssertEqual(WaveformDownsampler.downsample(peaks, to: 3), peaks)
    }

    func test_producesExactlyColumnsValues() {
        let peaks = (0..<1000).map { Float($0 % 7) / 7.0 }
        XCTAssertEqual(WaveformDownsampler.downsample(peaks, to: 250).count, 250)
        XCTAssertEqual(WaveformDownsampler.downsample(peaks, to: 999).count, 999)
    }

    /// The whole point: a 1.0 spike inside a bucket of near-silence must reach
    /// full height. A mean over the same bucket would report ~0.01.
    func test_usesMaxNotMean() {
        var peaks = [Float](repeating: 0.0, count: 1000)
        peaks[437] = 1.0
        let out = WaveformDownsampler.downsample(peaks, to: 10)
        XCTAssertEqual(out.max(), 1.0, "the spike must survive downsampling")
        XCTAssertEqual(out.filter { $0 > 0 }.count, 1,
                       "exactly one column contains the spike")
        // Bucket 4 covers indices 400..<500.
        XCTAssertEqual(out[4], 1.0)
    }

    /// Every input index belongs to exactly one column, so wherever a single
    /// spike sits it must be visible. This is what a `stride`-based pick fails.
    func test_everyInputIndexIsCovered() {
        let n = 997   // deliberately coprime-ish with the column count
        for spike in 0..<n {
            var peaks = [Float](repeating: 0.0, count: n)
            peaks[spike] = 1.0
            let out = WaveformDownsampler.downsample(peaks, to: 60)
            XCTAssertEqual(out.max(), 1.0,
                           "spike at index \(spike) was dropped by downsampling")
        }
    }

    func test_clampsIntoUnitRange() {
        // Peaks are documented as [0,1] but the file is on disk and editable.
        let out = WaveformDownsampler.downsample([-3, 0.5, 17, .nan], to: 2)
        XCTAssertTrue(out.allSatisfy { $0 >= 0 && $0 <= 1 && $0.isFinite },
                      "got \(out)")
    }

    // MARK: - Redraw cache

    /// The cache exists so a 10 Hz redraw does not redo the reduction. A stale
    /// hit would be a much worse bug than the cost it saves, so pin down both
    /// invalidation keys.
    func test_barCacheReturnsSameResultAndInvalidatesOnBothKeys() {
        let cache = WaveformBarCache()
        let a = (0..<1000).map { Float($0 % 13) / 13.0 }
        let first = cache.bars(for: a, columns: 100)
        XCTAssertEqual(cache.bars(for: a, columns: 100), first)
        XCTAssertEqual(first, WaveformDownsampler.downsample(a, to: 100))

        // Window resized.
        let wider = cache.bars(for: a, columns: 250)
        XCTAssertEqual(wider.count, 250)
        XCTAssertEqual(wider, WaveformDownsampler.downsample(a, to: 250))

        // Another meeting selected: same column count, different peaks.
        var b = [Float](repeating: 0, count: 1000)
        b[10] = 1
        let other = cache.bars(for: b, columns: 250)
        XCTAssertEqual(other, WaveformDownsampler.downsample(b, to: 250))
        XCTAssertNotEqual(other, cache.bars(for: a, columns: 250))
    }

    /// 2 hours at 50 ms = 144 000 peaks. Reduction is O(n) and must stay well
    /// inside a display frame; this is the "does a long meeting freeze the UI"
    /// question, measured rather than assumed.
    func test_twoHourArrayReducesFastEnough() {
        let peaks = (0..<144_000).map { _ in Float.random(in: 0...1) }
        let start = Date()
        let out = WaveformDownsampler.downsample(peaks, to: 600)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(out.count, 600)
        XCTAssertLessThan(elapsed, 0.05,
                          "144k -> 600 took \(elapsed)s; a 10 Hz redraw would stutter")
    }
}
