import ScreenCaptureKit
import AVFoundation

@available(macOS 13.0, *)
public final class SystemAudioRecorder: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private var writer: WavWriter?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat!
    private var startHostTime: UInt64 = 0

    public var startHostTimeNs: UInt64 { startHostTime }

    /// See `MicRecorder.sizeCapReached` — same semantics for the system-audio side.
    public var sizeCapReached: Bool { writer?.sealed ?? false }

    public func start(writingTo url: URL) async throws {
        writer = try WavWriter(url: url, sampleRate: 16_000, channels: 1)
        targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: 16_000, channels: 1, interleaved: false)

        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                           onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "Onyx", code: 100,
                          userInfo: [NSLocalizedDescriptionKey: "No display for SCStream"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2

        let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        try await s.startCapture()
        self.stream = s
        Log.recorder.info(
            "SystemAudioRecorder started (url=\(url.lastPathComponent, privacy: .public))")
    }

    public func stop() async throws {
        try await stream?.stopCapture()
        stream = nil
        try writer?.finish()
        writer = nil
        Log.recorder.info("SystemAudioRecorder stopped")
    }

    public func flushHeader() throws { try writer?.flushHeader() }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid, CMSampleBufferDataIsReady(sb) else { return }
        if startHostTime == 0 {
            let host = mach_absolute_time()
            startHostTime = host
        }
        guard let pcm = pcmBuffer(from: sb), let writer else { return }
        writeConverted(pcm, to: writer)
    }

    private func pcmBuffer(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc)?.pointee
        else { return nil }
        if sourceFormat == nil {
            sourceFormat = AVAudioFormat(streamDescription: [asbd].withUnsafeBufferPointer { $0.baseAddress! })
            if let sourceFormat {
                converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
            }
        }
        guard let sourceFormat else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard let buf = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames),
                                                     into: buf.mutableAudioBufferList)
        return buf
    }

    private func writeConverted(_ input: AVAudioPCMBuffer, to writer: WavWriter) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var err: NSError?
        var supplied = false
        let status = converter.convert(to: out, error: &err) { _, s in
            if supplied { s.pointee = .noDataNow; return nil }
            supplied = true; s.pointee = .haveData; return input
        }
        if status == .error {
            Log.recorder.error("System conv error: \(err?.localizedDescription ?? "?")")
            return
        }
        guard let ch = out.floatChannelData?[0] else { return }
        let bp = UnsafeBufferPointer(start: ch, count: Int(out.frameLength))
        do { try writer.write(bp) }
        catch WavWriterError.sizeCapReached {
            Log.recorder.error("SystemAudioRecorder: WAV size cap reached; capture ceased for this session")
        }
        catch { Log.recorder.error("System writer failed: \(error.localizedDescription)") }
    }
}
