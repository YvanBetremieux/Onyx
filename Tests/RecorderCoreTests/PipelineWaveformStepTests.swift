import XCTest
import AVFoundation
@testable import RecorderCore

@available(macOS 13.0, *)
final class PipelineWaveformStepTests: XCTestCase {
    var tmp: URL!
    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-pip-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp); super.tearDown() }

    private func writeSineWav(to url: URL) throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames: AVAudioFrameCount = 16_000
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData![0]
        for i in 0..<Int(frames) {
            ch[i] = Float(sin(2 * .pi * 440 * Double(i) / 16_000))
        }
        try file.write(from: buf)
    }

    private struct StubWhisper: WhisperTranscribing {
        func transcribe(wavPath: URL, to jsonPath: URL) async throws {
            let segs = [WhisperSegment(start: 0, end: 1, text: "hi", confidence: 1)]
            try AtomicJSON.write(segs, to: jsonPath)
        }
    }
    private struct StubDiarizer: Diarizing {
        func diarize(wavPath: URL, to jsonPath: URL) throws {
            let segs: [DiarSegment] = []
            try AtomicJSON.write(segs, to: jsonPath)
        }
    }

    /// Runs a mocked pipeline (whisper + diarizer stubs) end-to-end and asserts
    /// waveform.json is written after .render.
    func test_render_writesWaveformJson() async throws {
        let storage = MeetingStorage(root: tmp.appendingPathComponent("Meetings"))
        let paths = try storage.createMeeting(startedAt: Date())
        try writeSineWav(to: paths.micWav)
        try writeSineWav(to: paths.systemWav)

        let pipeline = Pipeline(storage: storage, whisper: StubWhisper(),
                                diarizer: StubDiarizer(), notes: nil)
        try await pipeline.run(paths: paths)

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.waveformJson.path),
                      "waveform.json should be written after .render")
        let wf = try WaveformFile.read(from: paths.waveformJson)
        XCTAssertFalse(wf.peaks.isEmpty)
    }

    /// Waveform generation is best-effort: a corrupt normalized WAV must not fail
    /// the pipeline. The `.normalize` step is pre-marked done so the garbage file
    /// survives into `.render`.
    func test_waveformFailureIsNonFatal() async throws {
        let storage = MeetingStorage(root: tmp.appendingPathComponent("Meetings"))
        let paths = try storage.createMeeting(startedAt: Date())
        try writeSineWav(to: paths.micWav)
        try writeSineWav(to: paths.systemWav)

        var job = try storage.loadJob(paths)
        job.markDone(.normalize)
        try storage.saveJob(job, at: paths)
        try Data("not audio".utf8).write(to: paths.micNormalized)
        try Data("not audio".utf8).write(to: paths.systemNormalized)

        let pipeline = Pipeline(storage: storage, whisper: StubWhisper(),
                                diarizer: StubDiarizer(), notes: nil)
        try await pipeline.run(paths: paths)

        let finished = try storage.loadJob(paths)
        XCTAssertEqual(finished.state, .done)
        XCTAssertEqual(finished.stepStatus(.render), .done)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.waveformJson.path))
    }
}
