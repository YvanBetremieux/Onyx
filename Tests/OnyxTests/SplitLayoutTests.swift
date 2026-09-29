import XCTest
import CoreGraphics
@testable import Onyx

final class SplitLayoutTests: XCTestCase {
    private let minL: CGFloat = 320
    private let minT: CGFloat = 280

    private func resolve(_ total: CGFloat, _ ratio: Double) -> SplitLayout {
        SplitLayout.resolve(total: total, ratio: ratio, minLeading: minL, minTrailing: minT)
    }

    func test_panesPlusDividerAlwaysFillTheContainer() {
        for total in [0, 1, 100, 600, 601, 1200, 4000] as [CGFloat] {
            for ratio in [-1, 0, 0.3, 0.5, 0.97, 2] as [Double] {
                let l = resolve(total, ratio)
                XCTAssertEqual(l.leadingWidth + l.trailingWidth + SplitLayout.dividerWidth,
                               max(total, SplitLayout.dividerWidth), accuracy: 0.001,
                               "total=\(total) ratio=\(ratio)")
            }
        }
    }

    func test_widthsAreNeverNegative() {
        for total in [-50, 0, 3, 6, 7, 200, 605, 2000] as [CGFloat] {
            for ratio in [-5, 0, 0.5, 1, 12] as [Double] {
                let l = resolve(total, ratio)
                XCTAssertGreaterThanOrEqual(l.leadingWidth, 0, "total=\(total) ratio=\(ratio)")
                XCTAssertGreaterThanOrEqual(l.trailingWidth, 0, "total=\(total) ratio=\(ratio)")
            }
        }
    }

    func test_middleRatio_isHonoured() {
        let l = resolve(1006, 0.5)
        XCTAssertEqual(l.leadingWidth, 500, accuracy: 0.001)
        XCTAssertEqual(l.trailingWidth, 500, accuracy: 0.001)
    }

    func test_ratioTooSmall_clampsToMinLeading_andKeepsTrailingPositive() {
        let l = resolve(1006, 0.01)
        XCTAssertEqual(l.leadingWidth, minL, accuracy: 0.001)
        XCTAssertEqual(l.trailingWidth, 1000 - minL, accuracy: 0.001)
    }

    func test_ratioTooLarge_clampsToMinTrailing() {
        let l = resolve(1006, 0.99)
        XCTAssertEqual(l.trailingWidth, minT, accuracy: 0.001)
        XCTAssertEqual(l.leadingWidth, 1000 - minT, accuracy: 0.001)
    }

    func test_containerNarrowerThanBothMinimums_splitsProportionally_neverZero() {
        // 306 usable px for 320 + 280 of minimums: impossible, so share it out
        // in the same proportion instead of starving the trailing pane.
        let l = resolve(306, 0.5)
        XCTAssertEqual(l.leadingWidth + l.trailingWidth, 300, accuracy: 0.001)
        XCTAssertEqual(l.leadingWidth, 300 * minL / (minL + minT), accuracy: 0.001)
        XCTAssertGreaterThan(l.leadingWidth, 0)
        XCTAssertGreaterThan(l.trailingWidth, 0)
    }

    func test_containerSmallerThanDivider_yieldsEmptyPanes() {
        let l = resolve(4, 0.5)
        XCTAssertEqual(l.leadingWidth, 0)
        XCTAssertEqual(l.trailingWidth, 0)
    }

    func test_nonFiniteRatio_fallsBackToHalf() {
        XCTAssertEqual(resolve(1006, .nan).leadingWidth, 500, accuracy: 0.001)
        XCTAssertEqual(resolve(1006, .infinity).leadingWidth, 1000 - minT, accuracy: 0.001)
    }

    func test_zeroMinimums_stillWorks() {
        let l = SplitLayout.resolve(total: 106, ratio: 0, minLeading: 0, minTrailing: 0)
        XCTAssertEqual(l.leadingWidth, 0)
        XCTAssertEqual(l.trailingWidth, 100)
    }

    // MARK: - Drag -> ratio

    func test_ratioFromLeadingWidth_isClampedToTheLegalRange() {
        let lo = SplitLayout.ratio(forLeadingWidth: -400, total: 1006,
                                   minLeading: minL, minTrailing: minT)
        XCTAssertEqual(lo, Double(minL / 1000), accuracy: 0.0001)

        let hi = SplitLayout.ratio(forLeadingWidth: 99_999, total: 1006,
                                   minLeading: minL, minTrailing: minT)
        XCTAssertEqual(hi, Double((1000 - minT) / 1000), accuracy: 0.0001)
    }

    func test_ratioFromLeadingWidth_roundTripsThroughResolve() {
        let r = SplitLayout.ratio(forLeadingWidth: 700, total: 1006,
                                  minLeading: minL, minTrailing: minT)
        XCTAssertEqual(resolve(1006, r).leadingWidth, 700, accuracy: 0.001)
    }

    func test_ratioFromLeadingWidth_isFiniteEvenForDegenerateContainers() {
        for total in [-10, 0, 6, 7] as [CGFloat] {
            let r = SplitLayout.ratio(forLeadingWidth: 3, total: total,
                                      minLeading: minL, minTrailing: minT)
            XCTAssertTrue(r.isFinite, "total=\(total) gave \(r)")
            XCTAssertTrue((0...1).contains(r), "total=\(total) gave \(r)")
        }
    }
}
