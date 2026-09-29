import XCTest
import AVFoundation
@testable import RecorderCore

final class WaveformGeneratorTests: XCTestCase {
    var tmp: URL!
    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp); super.tearDown() }

    /// Writes a 1-second 16 kHz mono float32 WAV via AVAudioFile (matching what
    /// Recorder already produces). Content is a 440 Hz sine so peaks are ~1.0.
    private func makeSineWav(duration: Double = 1.0, freq: Double = 440) throws -> URL {
        let url = tmp.appendingPathComponent("sine.wav")
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(16_000 * duration)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let ch = buf.floatChannelData![0]
        for i in 0..<Int(frames) {
            ch[i] = Float(sin(2 * .pi * freq * Double(i) / 16_000))
        }
        try file.write(from: buf)
        return url
    }

    func test_generate_returnsNonEmptyPeaks() throws {
        let wav = try makeSineWav(duration: 1.0)
        let wf = try WaveformGenerator.generate(from: wav, bucketSizeMs: 50)
        // 1000ms / 50ms = 20 buckets (±1 for the trailing partial bucket).
        XCTAssertTrue((19...21).contains(wf.peaks.count),
                      "expected ~20 buckets, got \(wf.peaks.count)")
        XCTAssertTrue(wf.peaks.allSatisfy { $0 >= 0 && $0 <= 1.001 })
        XCTAssertTrue(wf.peaks.contains { $0 > 0.5 })
        XCTAssertEqual(wf.sampleRate, 16_000)
        XCTAssertEqual(wf.bucketSizeMs, 50)
    }

    /// A full-scale sine must report ~1.0 buckets: these are TRUE peaks
    /// (max |sample|), not RMS (which would top out at ~0.707).
    func test_generate_reportsTruePeakNotRms() throws {
        let wav = try makeSineWav(duration: 1.0)
        let wf = try WaveformGenerator.generate(from: wav, bucketSizeMs: 50)
        let maxPeak = wf.peaks.max() ?? 0
        XCTAssertGreaterThan(maxPeak, 0.95,
                             "full-scale sine should peak near 1.0, got \(maxPeak) (RMS would be ~0.707)")
        XCTAssertTrue(wf.peaks.allSatisfy { $0 > 0.95 },
                      "every 50 ms bucket of a 440 Hz full-scale sine contains a crest")
    }

    /// Both other tests use exactly 1 s of audio, i.e. a single 16384-frame
    /// read. This one spans several chunk reads so the bucket accumulator's
    /// carry-over across reads is actually exercised.
    func test_generate_multiBucketAcrossChunkReads() throws {
        let wav = try makeSineWav(duration: 4.0)
        let wf = try WaveformGenerator.generate(from: wav, bucketSizeMs: 50)
        // 4 s at 16 kHz = 64000 frames; 50 ms bucket = 800 frames -> exactly 80.
        XCTAssertEqual(wf.peaks.count, 80,
                       "expected 80 buckets for 4 s at 50 ms, got \(wf.peaks.count)")
        XCTAssertTrue(wf.peaks.allSatisfy { $0 > 0.95 && $0 <= 1.001 },
                      "no bucket boundary should be dropped or double-counted")
    }

    func test_generate_silentAudioReturnsZeroPeaks() throws {
        let url = tmp.appendingPathComponent("silence.wav")
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 16_000)!
        buf.frameLength = 16_000
        // buffer is zero-initialized
        try file.write(from: buf)
        let wf = try WaveformGenerator.generate(from: url, bucketSizeMs: 50)
        XCTAssertTrue(wf.peaks.allSatisfy { $0 == 0 })
    }
}
