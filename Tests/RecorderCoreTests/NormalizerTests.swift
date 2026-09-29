import XCTest
import AVFoundation
@testable import RecorderCore

final class NormalizerTests: XCTestCase {
    func testUnexpectedFormatThrowsInsteadOfCrashing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // WAV 44.1 kHz stereo — a format the recorder never writes.
        let input = dir.appendingPathComponent("bad.wav")
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: 44_100, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: input, settings: fmt.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1024)!
        buf.frameLength = 1024
        try file.write(from: buf)
        let output = dir.appendingPathComponent("out.wav")
        XCTAssertThrowsError(try Normalizer.normalize(input: input, output: output)) { err in
            guard case NormalizerError.unexpectedFormat = err else {
                return XCTFail("expected NormalizerError.unexpectedFormat, got \(err)")
            }
        }
    }
}
