import SwiftUI

/// x ↔ time mapping for the scrubber, kept out of the view because it is the
/// part that can actually be wrong.
enum AudioScrubberGeometry {
    /// Time for a hit at `x` inside a waveform `width` points wide.
    ///
    /// Clamped on both ends: a `DragGesture` keeps reporting locations after the
    /// pointer has left the view, so `x` is regularly negative or past `width`.
    static func time(atX x: CGFloat, width: CGFloat,
                     duration: TimeInterval) -> TimeInterval {
        guard x.isFinite, width.isFinite, duration.isFinite,
              width > 0, duration > 0 else { return 0 }
        let ratio = min(1, max(0, Double(x / width)))
        return ratio * duration
    }

    static func progress(currentTime: TimeInterval,
                         duration: TimeInterval) -> Double {
        guard currentTime.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }
}

/// The bar under the notes|transcript split: play/pause, waveform, elapsed time,
/// speed.
///
/// Observes `AudioPlayer` directly, and is the *only* thing that does: the
/// player publishes 10×/s, so redrawing this bar (one `Canvas`, two labels) is
/// cheap, whereas letting the transcript observe it would rebuild the turn list
/// ten times a second.
struct AudioScrubberBar: View {
    @ObservedObject var player: AudioPlayer
    let peaks: [Float]

    private static let speeds: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        HStack(spacing: 14) {
            playButton

            GeometryReader { geo in
                WaveformView(
                    peaks: peaks,
                    progress: AudioScrubberGeometry.progress(
                        currentTime: player.currentTime, duration: player.duration)
                )
                .contentShape(Rectangle())
                .gesture(scrub(width: geo.size.width))
            }
            .frame(height: 26)
            .opacity(player.hasAudio ? 1 : 0.35)

            Text("\(TurnStyle.mmss(player.currentTime)) / \(TurnStyle.mmss(player.duration))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                // Fixed slot so the waveform does not resize as the digits
                // change width — at 10 Hz that is a visible jitter.
                .frame(minWidth: 96, alignment: .trailing)
                .accessibilityLabel("Position de lecture")
                .accessibilityValue("\(TurnStyle.mmss(player.currentTime)) sur \(TurnStyle.mmss(player.duration))")

            speedMenu
        }
        .padding(.horizontal, 20)
        .frame(height: 46)
        .background(.regularMaterial)
        .overlay(Rectangle().fill(.separator).frame(height: 0.5), alignment: .top)
    }

    private var playButton: some View {
        Button(action: player.toggle) {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 12))
                // Not `.white`: the disc is filled with `.primary`, which flips
                // with the appearance, so the glyph has to flip with it too.
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(player.hasAudio ? 0.85 : 0.25),
                            in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!player.hasAudio)
        .help(player.hasAudio
              ? (player.isPlaying ? "Pause" : "Lecture")
              : "Aucun fichier audio pour ce meeting")
        .accessibilityLabel(player.isPlaying ? "Pause" : "Lecture")
    }

    private var speedMenu: some View {
        Menu(Self.label(for: player.rate)) {
            ForEach(Self.speeds, id: \.self) { s in
                Button(Self.label(for: s)) { player.setRate(s) }
            }
        }
        .menuStyle(.borderlessButton)
        .font(.system(size: 11, design: .monospaced))
        .frame(width: 62)
        .disabled(!player.hasAudio)
        .accessibilityLabel("Vitesse de lecture")
    }

    /// The plan used `%.2g`, which renders 1.25 as "1.2" and 1.5 as "1.5" — two
    /// significant digits is simply the wrong tool. Whole speeds lose the decimal
    /// point, fractional ones keep only the digits they need.
    static func label(for rate: Float) -> String {
        let r = rate.isFinite ? rate : 1
        if r == r.rounded() { return String(format: "%.0f×", r) }
        var s = String(format: "%.2f", r)
        if s.hasSuffix("0") { s.removeLast() }
        return s + "×"
    }

    /// `minimumDistance: 0` so a plain click seeks too.
    ///
    /// `value.location` is in the coordinate space of the view the gesture is
    /// attached to — here the `WaveformView`, which fills the `GeometryReader`,
    /// so `geo.size.width` is the right denominator. (Attaching the same gesture
    /// to a narrow handle and dividing by the container width is the bug
    /// `ResizableSplit` had.)
    private func scrub(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                guard player.hasAudio else { return }
                player.seek(AudioScrubberGeometry.time(atX: v.location.x,
                                                       width: width,
                                                       duration: player.duration))
            }
    }
}
