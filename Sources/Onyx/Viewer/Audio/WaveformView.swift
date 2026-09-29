import SwiftUI

/// Reduces `waveform.json`'s peak array to one value per drawn bar.
///
/// This is not an optimisation, it is a correctness requirement: peaks are one
/// true-peak value per 50 ms bucket, so a two-hour meeting is 144 000 floats and
/// the scrubber has ~600 points of width. The plan's literal code picked every
/// `peaks.count / count`-th sample, which for that meeting *looks at 0.4% of the
/// data* — a loud passage between two sampled indices simply vanishes.
///
/// Reduction is by `max` over a contiguous partition of the input, so every
/// input sample belongs to exactly one bar and no transient can be lost. A mean
/// would smear them instead, which is how a peak waveform ends up looking like a
/// flat band.
enum WaveformDownsampler {
    static func downsample(_ peaks: [Float], to columns: Int) -> [Float] {
        guard columns > 0, !peaks.isEmpty else { return [] }
        guard peaks.count > columns else { return peaks.map(sanitise) }

        var out = [Float]()
        out.reserveCapacity(columns)
        let n = peaks.count
        for i in 0..<columns {
            let lo = i * n / columns
            // Integer partition: `hi` of bar i is `lo` of bar i+1, so the bars
            // tile 0..<n exactly. `columns < n` guarantees hi > lo.
            let hi = (i + 1) * n / columns
            var m: Float = 0
            for j in lo..<max(lo + 1, hi) {
                let v = sanitise(peaks[j])
                if v > m { m = v }
            }
            out.append(m)
        }
        return out
    }

    /// Peaks are documented as [0,1] but they arrive from a JSON file on disk,
    /// so a NaN or an out-of-range value is a realistic input — and it would
    /// become a NaN bar height, which `Canvas` draws as nothing at all.
    private static func sanitise(_ v: Float) -> Float {
        guard v.isFinite else { return 0 }
        return min(1, max(0, v))
    }
}

/// Memoises the reduction across redraws.
///
/// The scrubber redraws 10×/s while playing, but only `progress` changes — the
/// peaks and the width do not. Reducing 144 000 peaks takes ~17 ms in a debug
/// build, so redoing it every tick would burn a sixth of a core for nothing.
///
/// A reference type held in `@State`, deliberately *not* an `ObservableObject`:
/// filling the cache must not invalidate the view that is currently drawing.
/// `Array ==` short-circuits on identical storage, so the hit path is O(1) as
/// long as the caller keeps handing over the same array instance.
final class WaveformBarCache {
    private var peaks: [Float] = []
    private var columns: Int = -1
    private var bars: [Float] = []

    func bars(for peaks: [Float], columns: Int) -> [Float] {
        if columns == self.columns, peaks == self.peaks { return bars }
        self.peaks = peaks
        self.columns = columns
        bars = WaveformDownsampler.downsample(peaks, to: columns)
        return bars
    }
}

/// Bar-drawn waveform with a played/unplayed split at `progress`.
struct WaveformView: View {
    let peaks: [Float]
    /// 0…1. Callers should use `AudioScrubberGeometry.progress` so it is clamped.
    let progress: Double

    @State private var cache = WaveformBarCache()

    private let barWidth: CGFloat = 2
    private let gap: CGFloat = 1.5
    private let minBarHeight: CGFloat = 2

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            guard size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0 else { return }
            let step = barWidth + gap
            let columns = max(1, Int(size.width / step))
            let bars = cache.bars(for: peaks, columns: columns)
            guard !bars.isEmpty else { return }

            let midY = size.height / 2
            let usable = max(minBarHeight, size.height - 4)
            // Split on the x axis rather than on a bar count: with fewer peaks
            // than columns the bars no longer map 1:1 to columns, and an
            // index-based split would drift away from the time position.
            let playedX = size.width * CGFloat(min(1, max(0, progress)))

            for (i, p) in bars.enumerated() {
                let x = CGFloat(i) * step
                if x > size.width { break }
                let h = max(minBarHeight, CGFloat(p) * usable)
                let rect = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                         with: .color(x + barWidth / 2 <= playedX
                                      ? Color.accentColor
                                      : Color.secondary.opacity(0.45)))
            }
        }
    }
}
