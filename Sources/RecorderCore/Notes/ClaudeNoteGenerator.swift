import Foundation

public final class ClaudeNoteGenerator {
    public enum GenerationError: Error {
        case transcriptMissing
        case timedOut
        /// `stdout` fait partie de l'erreur, pas seulement `stderr` : le CLI
        /// `claude` écrit ses diagnostics d'authentification sur stdout, et les
        /// jeter a rendu l'incident du 2026-09-07 (11 réunions sans résumé)
        /// invisible dans `job.json`.
        case nonZeroExit(code: Int32, stdout: String, stderr: String)
        /// Le CLI n'est plus authentifié. Cas distinct de `nonZeroExit` parce
        /// qu'il touchera *toutes* les réunions suivantes tant qu'il n'est pas
        /// réglé — c'est le seul échec de notes qui justifie d'alerter
        /// l'utilisateur ; le report vers le moniteur d'authentification est
        /// câblé par le pipeline, voir la tâche dédiée.
        case authFailed(ClaudeAuthFailure, output: String)
        case emptyOutput
        /// `.live` is the user's own hand-written notes (notes/live.md) and is
        /// never a generation target. Reported as an error rather than a
        /// `precondition` so a stale `defaultNoteLevel = "live"` skips one note
        /// instead of trapping the whole app in a release build.
        case liveIsNotGeneratable
    }

    /// Les erreurs sont sérialisées dans `job.json` à chaque échec, et un échec
    /// d'auth se répète à chaque réunion tant qu'il n'est pas réglé : on borne
    /// ce qu'on recopie. La fin du flux est conservée (le diagnostic du CLI
    /// arrive en dernier).
    private static let maxCapturedOutput = 4_000

    /// Les deux flux comptent : l'incident du 2026-09-07 est né du fait qu'un
    /// seul était conservé. Joints plutôt que choisis.
    private static func joinedOutput(stdout: String, stderr: String) -> String {
        if stdout.isEmpty { return stderr }
        if stderr.isEmpty { return stdout }
        return stdout + "\n" + stderr
    }

    private let timeoutSeconds: TimeInterval

    public init(timeoutSeconds: TimeInterval = 300) {
        self.timeoutSeconds = timeoutSeconds
    }

    /// Result of one generation: the note itself lands on disk
    /// (`notes/<level>.md`); the title, when asked for, is returned so the
    /// caller decides what to do with it (metadata update, index refresh).
    public struct GenerationResult: Sendable {
        /// Title extracted from the `TITRE:` line, nil when not requested or
        /// when Claude ignored the instruction.
        public let detectedTitle: String?
    }

    /// - Parameter model: alias handed to `claude --model` ("haiku", "sonnet",
    ///   "opus", …). Nil or empty lets the CLI use its own configured default.
    @discardableResult
    public func generate(paths: MeetingPaths,
                         level: NoteLevel,
                         binary: URL,
                         model: String? = nil,
                         detectTitle: Bool = false) async throws -> GenerationResult {
        // `.live` resolves to the very same file as `paths.liveNotes`, so
        // generating it would overwrite the user's own notes. Refuse first,
        // before any other validation, and by throwing — `precondition` is
        // active in release builds and would crash a menu-bar app over a stale
        // preference value.
        guard level != .live else { throw GenerationError.liveIsNotGeneratable }
        guard FileManager.default.fileExists(atPath: paths.transcriptMd.path) else {
            throw GenerationError.transcriptMissing
        }
        let transcript = try String(contentsOf: paths.transcriptMd, encoding: .utf8)

        // Live notes: optional, may be missing (pre-chantier-3 meetings) or empty.
        let live: String? = {
            guard FileManager.default.fileExists(atPath: paths.liveNotes.path) else {
                return nil
            }
            let raw: String
            do {
                raw = try String(contentsOf: paths.liveNotes, encoding: .utf8)
            } catch {
                // Non-fatal by design: note generation must not fail because of
                // live notes. But a present-yet-unreadable file (permissions,
                // bad encoding) means the user's deliberately-typed notes are
                // being dropped, which must not look like "no notes".
                Log.pipeline.warning(
                    "Live notes exist but could not be read for \(paths.slug, privacy: .public): \(String(describing: error), privacy: .public)")
                return nil
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()

        let prompt = NotePromptTemplates.prompt(
            for: level, transcript: transcript, liveNotes: live, detectTitle: detectTitle
        )

        try FileManager.default.createDirectory(at: paths.notesDir,
                                                withIntermediateDirectories: true)

        let output = try await runClaude(binary: binary,
                                         cwd: paths.root,
                                         stdin: prompt,
                                         model: model)
        guard !output.isEmpty else { throw GenerationError.emptyOutput }
        let (title, body) = detectTitle ? Self.splitDetectedTitle(from: output)
                                        : (nil, output)
        // If Claude ignored the TITRE instruction, `body == output` and the
        // note is written untouched — a missing title must never cost the note.
        guard !body.isEmpty else { throw GenerationError.emptyOutput }
        try body.data(using: .utf8)!.write(to: paths.notesFile(level),
                                           options: .atomic)
        return GenerationResult(detectedTitle: title)
    }

    /// Splits a leading `TITRE: …` line off the model output.
    ///
    /// Tolerant on purpose — the line may arrive after a blank line or wrapped
    /// in Markdown emphasis (`**TITRE: …**`, `# TITRE: …`), so the first few
    /// non-empty lines are scanned rather than requiring an exact first byte.
    /// Anything unparseable degrades to (nil, full output): the note survives.
    static func splitDetectedTitle(from output: String) -> (title: String?, body: String) {
        var lines = output.components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // Only the first non-empty line may be the title; a TITRE deeper in
            // the note is content, not metadata.
            let stripped = line.trimmingCharacters(
                in: CharacterSet(charactersIn: "#*_> "))
            guard stripped.uppercased().hasPrefix("TITRE:") else { break }
            var title = String(stripped.dropFirst("TITRE:".count))
                .trimmingCharacters(in: .whitespaces)
            title = title.trimmingCharacters(in: CharacterSet(charactersIn: "*_\"«» "))
            lines.remove(at: i)
            let body = lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (title.isEmpty ? nil : title, body)
        }
        return (nil, output)
    }

    private func runClaude(binary: URL, cwd: URL, stdin: String,
                           model: String? = nil) async throws -> String {
        let proc = Process()
        proc.executableURL = binary
        var args = ["-p", "--output-format", "text"]
        if let model, !model.isEmpty { args += ["--model", model] }
        proc.arguments = args
        proc.currentDirectoryURL = cwd

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        // Drain pipes continuously to prevent 64 KB pipe buffer deadlock.
        let stdoutCollector = DataCollector()
        let stderrCollector = DataCollector()
        stdoutPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { stdoutCollector.append(d) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { stderrCollector.append(d) }
        }

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

        // Stop handlers and drain any final bytes the handler may have missed.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if let d = try? stdoutPipe.fileHandleForReading.readDataToEndOfFile(), !d.isEmpty {
            stdoutCollector.append(d)
        }
        if let d = try? stderrPipe.fileHandleForReading.readDataToEndOfFile(), !d.isEmpty {
            stderrCollector.append(d)
        }

        guard proc.terminationStatus == 0 else {
            let fullOut = String(data: stdoutCollector.snapshot, encoding: .utf8) ?? ""
            let fullErr = String(data: stderrCollector.snapshot, encoding: .utf8) ?? ""
            // Classification runs on the untruncated text — the marker could in
            // principle sit before the cut point of a very long stream.
            let failure = ClaudeAuthClassifier.classify(
                exitCode: proc.terminationStatus, stdout: fullOut, stderr: fullErr)
            let out = String(fullOut.suffix(Self.maxCapturedOutput))
            let err = String(fullErr.suffix(Self.maxCapturedOutput))
            if let failure {
                throw GenerationError.authFailed(
                    failure, output: Self.joinedOutput(stdout: out, stderr: err))
            }
            throw GenerationError.nonZeroExit(code: proc.terminationStatus,
                                              stdout: out, stderr: err)
        }
        return String(data: stdoutCollector.snapshot, encoding: .utf8) ?? ""
    }
}
