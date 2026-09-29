import Foundation
import AVFoundation
import Combine

/// `AVPlayer` wrapper with published transport state, driving the viewer's
/// scrubber.
///
/// Why `AVPlayer` and not `AVAudioPlayer` (which this type used until the
/// mixed-playback change): a meeting has two independent, time-aligned streams
/// (`mic.m4a` = the user, `system.m4a` = the remote participants) and an
/// `AVAudioPlayer` can only play one file. Both streams are inserted at t=0
/// into an `AVMutableComposition` — no extra disk, no re-encode, and one
/// transport (seek/rate/pause) driving both tracks in sample-lock, which two
/// synchronized `AVAudioPlayer`s cannot guarantee across seeks and rate
/// changes.
///
/// Everything mutable lives on the main actor so the published values and the
/// underlying player can never disagree. The only thing that leaves the main
/// actor is opening the files (see `load`), which for a two-hour `.m4a` is real
/// I/O.
@MainActor
final class AudioPlayer: ObservableObject {
    /// Playback speeds offered in the UI. With `.timeDomain` pitch correction
    /// `AVPlayer` accepts a much wider range, but 0.5…2.0 is what the speed
    /// menu offers (and what the old `AVAudioPlayer.rate` supported); anything
    /// outside is clamped.
    static let minRate: Float = 0.5
    static let maxRate: Float = 2.0

    @Published private(set) var isPlaying = false
    /// Ticks at `tickInterval` while playing. Deliberately *not* observed by the
    /// transcript — see `TranscriptPlayhead`.
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var rate: Float = 1.0
    /// False when the meeting has no playable audio at all. The scrubber stays
    /// visible but inert rather than pretending to be able to play silence.
    @Published private(set) var hasAudio = false

    /// Called on the main actor whenever the playhead moves — on every tick and
    /// on every seek. Used to feed `TranscriptPlayhead` without making the
    /// transcript observe this object.
    var onTimeChanged: (@MainActor (TimeInterval) -> Void)?

    private static let tickInterval: TimeInterval = 0.1
    /// Treated as "at the end": an `AVPlayer` whose item sits at its end
    /// pauses immediately instead of playing, so `play()` there must rewind.
    private static let endEpsilon: TimeInterval = 0.05
    /// `CMTime` timescale for seeks. 600 is the AVFoundation convention (it
    /// divides every common frame/sample cadence).
    private static let seekTimescale: CMTimeScale = 600

    private var player: AVPlayer?
    private var timer: Timer?
    /// Held for the whole duration of playback. Without it App Nap throttles the
    /// process as soon as the viewer window stops being frontmost or gets
    /// occluded (another app in front, window minimised), which starves the
    /// tick timer and can stall `AVPlayer` itself — playback appeared to "cut"
    /// whenever the user switched away. Released on pause/stop so a paused
    /// viewer in the background is as cheap as it was before.
    private var playbackActivity: NSObjectProtocol?
    /// Bumped by every `load` and every `stop`, so a load whose off-main file
    /// open resumes late can tell that it has been superseded and publish
    /// nothing. Without it, two quick meeting selections leave the *older*
    /// recording loaded.
    private var loadGeneration = 0
    /// Count of `AVPlayer.seek` completions still in flight. Unlike the old
    /// `AVAudioPlayer.currentTime` setter, `AVPlayer` seeks asynchronously, so
    /// between the request and its completion the player still reports the
    /// *old* position — the ticker must not publish that (a visible playhead
    /// snap-back while scrubbing) nor mistake the paused-during-seek state for
    /// end-of-file.
    private var pendingSeeks = 0

    /// Exposed for tests: `isPlaying` and a live ticker must always agree —
    /// `isPlaying` without a ticker freezes the playhead, a ticker without
    /// `isPlaying` leaks a timer onto the main run loop forever.
    var isTickerRunning: Bool { timer != nil }

    // MARK: - Loading

    /// Single-file convenience over `load(urls:)`.
    func load(url: URL?) async {
        await load(urls: url.map { [$0] } ?? [])
    }

    /// Opens every playable file in `urls` off the main thread, mixes them into
    /// one composition (all starting at t=0 — the recorder starts the streams
    /// together, so their timelines are aligned) and publishes the mix's
    /// duration (= the longest stream).
    ///
    /// The mix is unity-gain, deliberately (no `AVMutableAudioMix`): the call
    /// audio is echo-cancelled so mic and system rarely overlap at sustained
    /// full scale, and CoreAudio soft-limits the summed output. If clipping is
    /// ever actually heard, the fix is per-track volume ≈ 0.7 via
    /// `AVMutableAudioMix` — not attenuating preemptively, which would just
    /// make every meeting quieter.
    ///
    /// A missing, unreadable or non-audio file is not an error worth surfacing:
    /// it is skipped, and if *nothing* opens the meeting simply has nothing to
    /// play — the caller has already had to guess which of `mic.m4a` /
    /// `system.m4a` / the pre-cleanup WAVs exists.
    func load(urls: [URL]) async {
        await load(parts: [Part(urls: urls, offset: 0)])
    }

    /// One stretch of the timeline: the files to mix (mic + system of a single
    /// recording) and where that recording starts on the merged timeline.
    ///
    /// A plain meeting is one part at offset 0. A manually merged meeting
    /// (`MeetingMetadata.mergedParts`) is N parts butted end-to-end, which is
    /// what lets the viewer play several recordings through a single transport
    /// and a single scrubber without ever rewriting a byte of audio.
    struct Part: Equatable {
        let urls: [URL]
        let offset: TimeInterval
    }

    /// Opens every part off the main thread and inserts each one's streams at
    /// its own offset in a single composition. Within a part all streams start
    /// together (the recorder starts them together), so they stay mixed and
    /// aligned exactly as before.
    func load(parts: [Part]) async {
        loadGeneration += 1
        let generation = loadGeneration
        stopKeepingGeneration()
        guard parts.contains(where: { !$0.urls.isEmpty }) else { return }
        guard let box = await Self.open(parts), generation == loadGeneration else { return }
        let item = AVPlayerItem(asset: box.composition)
        // Pitch-corrected speed change, like the old `AVAudioPlayer.enableRate`
        // behaviour. `.timeDomain` is the cheap speech-quality algorithm.
        item.audioTimePitchAlgorithm = .timeDomain
        let p = AVPlayer(playerItem: item)
        // Local files: never wait to "buffer", so `playImmediately(atRate:)`
        // takes effect right away.
        p.automaticallyWaitsToMinimizeStalling = false
        player = p
        hasAudio = true
        duration = box.duration.isFinite ? max(0, box.duration) : 0
        currentTime = 0
        onTimeChanged?(0)
    }

    /// Handing an `AVMutableComposition` back from a detached task. Safe
    /// because the instance is created there and never touched from that thread
    /// again — it is used exclusively from the main actor from the moment it is
    /// unboxed.
    private struct CompositionBox: @unchecked Sendable {
        let composition: AVMutableComposition
        let duration: TimeInterval
    }

    private static func open(_ parts: [Part]) async -> CompositionBox? {
        await Task.detached(priority: .userInitiated) { () -> CompositionBox? in
            let composition = AVMutableComposition()
            var end = CMTime.zero
            for part in parts {
                // Local copy of the seek timescale: the enclosing type is
                // main-actor isolated and this closure is not.
                let at = CMTime(seconds: max(0, part.offset), preferredTimescale: 600)
                for url in part.urls {
                    let asset = AVURLAsset(url: url)
                    // A missing or undecodable file throws here; skip it so one
                    // broken stream does not silence the other.
                    guard let tracks = try? await asset.load(.tracks) else { continue }
                    for track in tracks where track.mediaType == .audio {
                        guard let range = try? await track.load(.timeRange),
                              let dst = composition.addMutableTrack(
                                withMediaType: .audio,
                                preferredTrackID: kCMPersistentTrackID_Invalid)
                        else { continue }
                        // Every stream of a part starts at that part's offset —
                        // 0 for a plain meeting, so this is the same
                        // time-alignment story as before for the common case.
                        guard (try? dst.insertTimeRange(range, of: track, at: at)) != nil
                        else { composition.removeTrack(dst); continue }
                        end = CMTimeMaximum(end, dst.timeRange.end)
                    }
                }
            }
            guard !composition.tracks.isEmpty, end > .zero, end.seconds.isFinite
            else { return nil }
            return CompositionBox(composition: composition, duration: end.seconds)
        }.value
    }

    // MARK: - Transport

    func play() {
        guard let p = player else { return }
        // Rewind rather than "play" a finished item, which would look like a
        // dead button. The seek is asynchronous, so playback only starts from
        // its completion — starting it before would play the tail end for a
        // frame and immediately re-pause at EOF.
        if duration > 0, currentTime >= duration - Self.endEpsilon {
            currentTime = 0
            onTimeChanged?(0)
            isPlaying = true
            startTicker()
            pendingSeeks += 1
            let generation = loadGeneration
            p.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                Task { @MainActor [weak self] in
                    guard let self, generation == self.loadGeneration else { return }
                    self.pendingSeeks -= 1
                    // The user may have paused while the rewind was in flight.
                    guard self.isPlaying else { return }
                    self.player?.playImmediately(atRate: self.rate)
                }
            }
            return
        }
        p.playImmediately(atRate: rate)
        isPlaying = true
        startTicker()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicker()
        endPlaybackActivity()
    }

    func toggle() { isPlaying ? pause() : play() }

    /// Clamps into `0...duration`. `t` reaches us from `transcript.json` and from
    /// FTS row timestamps, so a non-finite value is a realistic input — and
    /// building a `CMTime` from NaN is undefined behaviour, not a no-op.
    ///
    /// The clamped target is published immediately (the old `AVAudioPlayer`
    /// setter was synchronous and callers rely on that); the asynchronous
    /// `AVPlayer.seek` catches up, with `pendingSeeks` keeping the ticker from
    /// publishing the stale in-between position.
    func seek(_ t: TimeInterval) {
        let target = Self.clamp(t, duration: duration)
        if let p = player {
            pendingSeeks += 1
            // Generation-guarded: `stop()`/`load()` reset `pendingSeeks` to 0,
            // so a completion arriving after that must not decrement the *new*
            // player's counter below zero (which would freeze the ticker's
            // `pendingSeeks == 0` gate forever).
            let generation = loadGeneration
            p.seek(to: CMTime(seconds: target, preferredTimescale: Self.seekTimescale),
                   toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                Task { @MainActor [weak self] in
                    guard let self, generation == self.loadGeneration else { return }
                    self.pendingSeeks -= 1
                }
            }
        }
        // With no player at all the answer is 0, whatever was asked.
        currentTime = player != nil ? target : 0
        onTimeChanged?(currentTime)
    }

    static func clamp(_ t: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0 }
        guard t.isFinite else { return t.isNaN ? 0 : (t > 0 ? duration : 0) }
        return max(0, min(duration, t))
    }

    func setRate(_ r: Float) {
        let sanitised = r.isFinite ? r : 1.0
        rate = min(Self.maxRate, max(Self.minRate, sanitised))
        // Only applied while playing: assigning a non-zero `AVPlayer.rate` to a
        // *paused* player starts playback — the paused case is re-applied by
        // `play()` through `playImmediately(atRate:)`.
        if isPlaying { player?.rate = rate }
    }

    /// Releases the media. Also invalidates any in-flight `load`.
    func stop() {
        loadGeneration += 1
        stopKeepingGeneration()
    }

    private func stopKeepingGeneration() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        pendingSeeks = 0
        isPlaying = false
        hasAudio = false
        duration = 0
        currentTime = 0
        stopTicker()
        endPlaybackActivity()
        onTimeChanged?(0)
    }

    // MARK: - Ticker

    /// A manual `Timer` rather than `AVPlayer.addPeriodicTimeObserver`,
    /// deliberately: a periodic observer must be removed before its player is
    /// released (crash-on-dealloc otherwise), which is exactly the player churn
    /// `load()`'s generation bumping produces — and it cannot be gated by
    /// `pendingSeeks`, so it would publish stale positions mid-seek.
    private func startTicker() {
        stopTicker()
        beginPlaybackActivity()
        let t = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] timer in
            guard let self else {
                // The player was released while playing: don't leave a timer
                // retained by the run loop forever.
                timer.invalidate()
                return
            }
            // The block already runs on the main *thread*, but macOS 13 has no
            // `MainActor.assumeIsolated`, so hop explicitly.
            Task { @MainActor in self.tick() }
        }
        // `.common` and not the default mode: a default-mode timer stalls while
        // a menu is open or the user is dragging a scroller, which is exactly
        // when the speed menu is up.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTicker() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - App Nap

    /// `.userInitiated` keeps the process out of App Nap; `.idleDisplaySleep`
    /// is deliberately *not* requested — audio has no reason to keep the screen
    /// awake, only the process scheduled.
    private func beginPlaybackActivity() {
        guard playbackActivity == nil else { return }
        playbackActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Onyx audio playback")
    }

    private func endPlaybackActivity() {
        guard let a = playbackActivity else { return }
        ProcessInfo.processInfo.endActivity(a)
        playbackActivity = nil
    }

    private func tick() {
        // A tick enqueued just before `pause()` can land just after it: the
        // timer is invalidated, but its hop onto the main actor was already
        // queued. Publishing then would move the playhead *while paused* — the
        // real clock leads the last published tick by up to one tick interval.
        guard isPlaying else { return }
        guard let p = player else { pause(); return }
        // While a seek is in flight the player still reports the old position
        // and sits paused; publishing either would be wrong. The completion
        // brings `pendingSeeks` back to 0 and the next tick resumes normally.
        guard pendingSeeks == 0 else { return }
        let raw = p.currentTime().seconds
        let t = raw.isFinite ? max(0, min(duration, raw)) : 0
        if t != currentTime {
            currentTime = t
            onTimeChanged?(t)
        }
        // Playback reached the end (`actionAtItemEnd` defaults to `.pause`), or
        // was stopped behind our back (item failure, output device gone).
        if p.timeControlStatus == .paused, isPlaying { pause() }
    }
}
