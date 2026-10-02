import AVFoundation

public final class MicRecorder {
    public struct Config {
        public var sampleRate: Double = 16_000
        /// Apple voice processing (the FaceTime/Zoom echo canceller): the OS
        /// subtracts what it is playing on the speakers from what the mic
        /// hears. Without it, speaker playback re-enters through the mic and
        /// every remote sentence gets transcribed twice — once on the system
        /// channel and once as "MOI" (observed on real meetings).
        ///
        /// OFF by default since 2026-10-02: on an Apple Silicon MacBook Pro it
        /// lowered the mic for EVERY app (Meet participants could no longer
        /// hear the user), and the effect lasted until Onyx quit. Echo is then
        /// handled at the transcript level by the Merger's near-duplicate
        /// filter. Opt-in via the `micEchoCancellation` setting.
        public var echoCancellation: Bool = false
        public init() {}
    }

    /// Clé UserDefaults du réglage « Annulation d'écho » (app Onyx).
    public static let echoCancellationDefaultsKey = "micEchoCancellation"

    public static func echoCancellationEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: echoCancellationDefaultsKey)
    }

    /// Un moteur neuf par enregistrement, libéré à l'arrêt : un moteur gardé
    /// toute la vie de l'app gardait le traitement de la voix actif (et le
    /// micro des autres apps baissé) bien après la fin de l'enregistrement.
    private var engine: AVAudioEngine?
    private var voiceProcessingActive = false
    private let config: Config
    private var writer: WavWriter?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat!
    private var startHostTime: UInt64 = 0
    /// Peak |sample| written this session. A session that ends at exactly 0 was
    /// digital silence — the failure mode of the 2026-08-03 channel-mapping bug
    /// (and of a denied mic permission), worth shouting about in the log.
    private var sessionPeak: Float = 0

    public init(config: Config = .init()) { self.config = config }

    public var startHostTimeNs: UInt64 { startHostTime }

    /// `true` when the underlying WAV writer refused a sample because the
    /// data chunk would exceed `WavWriter.maxDataBytes`. Once true, the mic
    /// side is effectively "capped" — the flush task in `Recorder` polls
    /// this to trigger a graceful stop.
    public var sizeCapReached: Bool { writer?.sealed ?? false }

    /// `echoCancellation` : `nil` → valeur de `Config`.
    public func start(writingTo url: URL, echoCancellation: Bool? = nil) throws {
        let engine = AVAudioEngine()
        self.engine = engine
        writer = try WavWriter(url: url, sampleRate: Int(config.sampleRate), channels: 1)
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: config.sampleRate,
            channels: 1,
            interleaved: false)

        let input = engine.inputNode
        if echoCancellation ?? config.echoCancellation {
            // Best-effort: some devices/virtual inputs refuse voice
            // processing. Recording without AEC beats not recording — the
            // Merger's near-duplicate filter still cleans the transcript.
            do {
                try input.setVoiceProcessingEnabled(true)
                voiceProcessingActive = true
                if #available(macOS 14.0, *) {
                    // Keep AEC but stop macOS from ducking every other
                    // audio stream (the meeting itself) while recording.
                    input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                        enableAdvancedDucking: false,
                        duckingLevel: .min)
                }
                Log.recorder.info("MicRecorder: voice processing (AEC) enabled")
            } catch {
                Log.recorder.error(
                    "MicRecorder: voice processing unavailable, recording without AEC: \(String(describing: error), privacy: .public)")
            }
        }
        // Read the format AFTER toggling voice processing — enabling it
        // changes the input node's stream format.
        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        // 2026-08-07 fix: with voice processing enabled the input node exposes a
        // multichannel stream (7ch observed) and AVAudioConverter's default
        // multichannel→mono mapping produces pure digital silence — every mic
        // track recorded between 2026-08-03 and 2026-08-07 was zeros. Map the
        // mono output explicitly to channel 0 (the primary mic signal).
        if inputFormat.channelCount > 1 {
            converter?.channelMap = [0]
            Log.recorder.info(
                "MicRecorder: multichannel input (\(inputFormat.channelCount)ch), channelMap=[0]")
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buf, when in
            guard let self else { return }
            if self.startHostTime == 0 { self.startHostTime = when.hostTime }
            self.process(inputBuffer: buf)
        }
        try engine.start()
        Log.recorder.info(
            "MicRecorder started (url=\(url.lastPathComponent, privacy: .public), hostTime=\(self.startHostTime))")
    }

    public func stop() throws {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            if voiceProcessingActive {
                try? engine.inputNode.setVoiceProcessingEnabled(false)
                voiceProcessingActive = false
            }
        }
        engine = nil
        try writer?.finish()
        writer = nil
        if sessionPeak == 0 {
            Log.recorder.error(
                "MicRecorder stopped: session was PURE DIGITAL SILENCE (peak=0) — check mic permission and channel mapping")
        } else {
            Log.recorder.info("MicRecorder stopped (sessionPeak=\(self.sessionPeak))")
        }
        sessionPeak = 0
    }

    public func flushHeader() throws { try writer?.flushHeader() }

    private func process(inputBuffer: AVAudioPCMBuffer) {
        guard let converter, let writer else { return }
        let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var err: NSError?
        var supplied = false
        let status = converter.convert(to: out, error: &err) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true; outStatus.pointee = .haveData; return inputBuffer
        }
        if status == .error {
            Log.recorder.error("Mic conversion error: \(err?.localizedDescription ?? "?")")
            return
        }
        guard let ch = out.floatChannelData?[0] else { return }
        let count = Int(out.frameLength)
        for i in 0..<count { sessionPeak = max(sessionPeak, abs(ch[i])) }
        let buffer = UnsafeBufferPointer(start: ch, count: count)
        do { try writer.write(buffer) }
        catch WavWriterError.sizeCapReached {
            Log.recorder.error("MicRecorder: WAV size cap reached; capture ceased for this session")
        }
        catch { Log.recorder.error("Mic writer failed: \(error.localizedDescription)") }
    }
}
