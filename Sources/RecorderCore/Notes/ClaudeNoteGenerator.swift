import Foundation

public final class ClaudeNoteGenerator {
    public enum GenerationError: Error {
        case transcriptMissing
        case timedOut
        case nonZeroExit(code: Int32, stderr: String)
        case emptyOutput
    }

    private let timeoutSeconds: TimeInterval

    public init(timeoutSeconds: TimeInterval = 300) {
        self.timeoutSeconds = timeoutSeconds
    }

    public func generate(paths: MeetingPaths,
                         level: NoteLevel,
                         binary: URL) async throws {
        guard FileManager.default.fileExists(atPath: paths.transcriptMd.path) else {
            throw GenerationError.transcriptMissing
        }
        let transcript = try String(contentsOf: paths.transcriptMd, encoding: .utf8)
        let prompt = NotePromptTemplates.prompt(for: level, transcript: transcript)

        try FileManager.default.createDirectory(at: paths.notesDir,
                                                withIntermediateDirectories: true)

        let output = try await runClaude(binary: binary,
                                         cwd: paths.root,
                                         stdin: prompt)
        guard !output.isEmpty else { throw GenerationError.emptyOutput }
        try output.data(using: .utf8)!.write(to: paths.notesFile(level),
                                             options: .atomic)
    }

    private func runClaude(binary: URL, cwd: URL, stdin: String) async throws -> String {
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["-p", "--output-format", "text"]
        proc.currentDirectoryURL = cwd

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        try proc.run()

        if let data = stdin.data(using: .utf8) {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        }
        try stdinPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while proc.isRunning {
            if Date() >= deadline {
                proc.terminate()
                try? await Task.sleep(nanoseconds: 200_000_000)
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                throw GenerationError.timedOut
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let stdoutData = try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
        let stderrData = try stderrPipe.fileHandleForReading.readToEnd() ?? Data()

        guard proc.terminationStatus == 0 else {
            let err = String(data: stderrData, encoding: .utf8) ?? ""
            throw GenerationError.nonZeroExit(code: proc.terminationStatus,
                                              stderr: err)
        }
        return String(data: stdoutData, encoding: .utf8) ?? ""
    }
}
