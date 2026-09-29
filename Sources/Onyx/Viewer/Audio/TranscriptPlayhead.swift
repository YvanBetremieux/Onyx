import Foundation
import Combine

/// The playhead position the *transcript* follows, quantised so the transcript
/// is not rebuilt at the player's tick rate.
///
/// `AudioPlayer` publishes `currentTime` 10×/s. `@ObservedObject` invalidates
/// the whole observing view on `objectWillChange` — it has no idea which
/// property the body read — so any view observing the player redraws 10×/s. For
/// the transcript that means re-deriving every row and re-running the
/// auto-scroll `onChange` ten times a second, on a list that can hold thousands
/// of turns.
///
/// This object sits in between and publishes only when the quantised position
/// actually moves: 2 publishes per second of audio at the default 0.5 s step,
/// which is also the worst-case lag of the active-turn highlight.
@MainActor
final class TranscriptPlayhead: ObservableObject {
    @Published private(set) var seconds: TimeInterval = 0

    /// Quantisation step in seconds. Sanitised at init: a zero or negative step
    /// would divide by zero and publish on every single tick — the exact
    /// problem this type exists to avoid.
    let quantum: TimeInterval

    init(quantum: TimeInterval = 0.5) {
        self.quantum = (quantum.isFinite && quantum > 0) ? quantum : 0.5
    }

    /// Feed with the raw player time. Cheap and idempotent — safe to call on
    /// every tick.
    func update(_ t: TimeInterval) {
        let q = Self.quantise(t, step: quantum)
        // The whole point: assign only on a real change, so `objectWillChange`
        // does not fire.
        if q != seconds { seconds = q }
    }

    func reset() { update(0) }

    /// Non-finite and negative inputs collapse to 0: these values come from
    /// `AVAudioPlayer.currentTime` and from JSON on disk, and downstream
    /// `Int(_:)` conversions trap on NaN.
    static func quantise(_ t: TimeInterval, step: TimeInterval) -> TimeInterval {
        guard t.isFinite, t > 0, step.isFinite, step > 0 else { return 0 }
        return (t / step).rounded(.down) * step
    }
}
