import Foundation

/// Ce qu'Onyx sait de l'authentification du CLI `claude`.
///
/// `unknown` n'est pas un défaut : c'est l'état honnête au premier lancement,
/// avant qu'une génération de notes ait eu lieu. Aucune bannière ne s'affiche
/// dans cet état — alerter sans savoir serait pire que se taire.
public enum ClaudeAuthStatus: Codable, Equatable, Sendable {
    case unknown
    case connected(checkedAt: Date)
    case disconnected(ClaudeAuthFailure, since: Date)

    public var isDisconnected: Bool {
        if case .disconnected = self { return true }
        return false
    }

    /// Deux statuts « de même nature » ne constituent pas une transition. Sert
    /// à ne notifier l'utilisateur qu'une fois, quel que soit le nombre de
    /// réunions qui échouent ensuite.
    func sameKind(as other: ClaudeAuthStatus) -> Bool {
        switch (self, other) {
        case (.unknown, .unknown): return true
        case (.connected, .connected): return true
        case (.disconnected(let a, _), .disconnected(let b, _)): return a == b
        default: return false
        }
    }
}

/// Résultat d'une sonde explicite (bouton « Tester »).
public enum ClaudeAuthProbeOutcome: Equatable, Sendable {
    case connected
    case disconnected(ClaudeAuthFailure)
    /// Ni l'un ni l'autre : binaire injoignable, timeout, réseau coupé. Ne
    /// modifie pas le statut — une coupure réseau n'est pas une déconnexion.
    case inconclusive(String)
}

/// Détient le statut d'authentification, le persiste, et le met à jour depuis
/// deux sources : les vraies générations de notes (passif, gratuit) et une
/// sonde explicite déclenchée par l'utilisateur.
public actor ClaudeAuthMonitor {
    /// Invoked synchronously, from inside the actor, every time `apply(_:)`
    /// records a genuine transition. Contract: the handler MUST return
    /// immediately and MUST NOT call back into this monitor (`status`,
    /// `reportSuccess`, `reportFailure`, `probe`, …) — doing so would
    /// re-enter or stall the actor, and the pipeline's `.notes` step reports
    /// through this same actor, so a slow subscriber would stall note
    /// generation itself. The one real subscriber posts to
    /// `NotificationCenter`, whose delivery to our Combine subscriber hops to
    /// the main queue, so that usage is safe.
    public typealias ChangeHandler = @Sendable (ClaudeAuthStatus) -> Void

    private let stateFile: URL
    private let onChange: ChangeHandler?
    private var current: ClaudeAuthStatus
    private let probeTimeout: TimeInterval

    public init(stateFile: URL, probeTimeout: TimeInterval = 30,
                onChange: ChangeHandler? = nil) {
        self.stateFile = stateFile
        self.onChange = onChange
        self.probeTimeout = probeTimeout
        // Un fichier absent ou corrompu vaut `.unknown` : ce composant ne doit
        // jamais empêcher l'app de démarrer.
        self.current = (try? AtomicJSON.read(ClaudeAuthStatus.self, from: stateFile)) ?? .unknown
    }

    public var status: ClaudeAuthStatus { current }

    /// Appelé par l'étape `.notes` du pipeline après une génération réussie.
    public func reportSuccess(at date: Date = Date()) {
        apply(.connected(checkedAt: date))
    }

    /// Appelé par l'étape `.notes` du pipeline après un échec. Les erreurs qui
    /// ne sont pas des problèmes d'auth sont ignorées volontairement.
    public func reportFailure(_ error: Error, at date: Date = Date()) {
        guard case ClaudeNoteGenerator.GenerationError.authFailed(let failure, _) = error
        else { return }
        apply(.disconnected(failure, since: date))
    }

    /// Sonde à la demande : un vrai `claude -p` minimal. Coûte quelques tokens,
    /// et c'est le prix d'une réponse fiable — lire le jeton dans le trousseau
    /// serait gratuit mais mensonger (un jeton d'apparence valide peut être
    /// refusé côté serveur).
    @discardableResult
    public func probe(binary: URL, model: String? = nil) async -> ClaudeAuthProbeOutcome {
        let outcome = await Self.runProbe(binary: binary, model: model,
                                          timeout: probeTimeout)
        switch outcome {
        case .connected:
            apply(.connected(checkedAt: Date()))
        case .disconnected(let failure):
            apply(.disconnected(failure, since: Date()))
        case .inconclusive:
            break // statut inchangé, volontairement
        }
        return outcome
    }

    private func apply(_ new: ClaudeAuthStatus) {
        let isTransition = !current.sameKind(as: new)
        let previous = current
        if isTransition {
            current = new
        } else if case .connected(let checkedAt) = new {
            // Un succès répété rafraîchit l'horodatage : « vérifié à 11h42 »
            // doit dire la vérité.
            current = .connected(checkedAt: checkedAt)
        }
        // Sinon : déconnexion répétée. `since` reste la date du PREMIER échec —
        // c'est tout l'intérêt du champ. Pendant l'incident du 2026-09-07,
        // onze réunions ont échoué sur deux jours ; la bannière doit annoncer
        // « depuis deux jours », pas « à l'instant ».
        guard current != previous else { return }
        do {
            try FileManager.default.createDirectory(
                at: stateFile.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            // `AtomicJSON` encodes dates as ISO-8601 without fractional
            // seconds, so the timestamp persisted here keeps whole-second
            // precision only — a round trip through disk can shift it by up
            // to ~1s from what was passed to `apply`. Never switch the
            // encoder to emit fractional seconds to "fix" this: the decoder
            // side deliberately stays plain `.iso8601` too, and mismatching
            // the two would break parsing of every other file this house
            // helper writes (`meta.json`, `job.json`, …). This is harmless
            // here because the timestamp is display-only — `sameKind(as:)`,
            // which drives the notify-once logic, ignores it entirely.
            try AtomicJSON.write(current, to: stateFile)
        } catch {
            Log.pipeline.warning(
                "Could not persist Claude auth status: \(String(describing: error), privacy: .public)")
        }
        if isTransition {
            let updated = current
            Log.pipeline.info("Claude auth status → \(String(describing: updated), privacy: .public)")
            onChange?(updated)
        }
    }

    // MARK: - Sonde

    private static func runProbe(binary: URL, model: String?,
                                 timeout: TimeInterval) async -> ClaudeAuthProbeOutcome {
        let proc = Process()
        proc.executableURL = binary
        var args = ["-p", "--output-format", "text"]
        if let model, !model.isEmpty { args += ["--model", model] }
        proc.arguments = args

        let stdinPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let outCollector = DataCollector(), errCollector = DataCollector()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { outCollector.append(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { errCollector.append(d) }
        }
        // The timeout branch below is precisely the network-cut case this
        // probe exists to detect, so it WILL return early in practice —
        // tear the handlers down in a `defer` so no exit path can skip it
        // and leak a readability handler on a pipe nobody is reading.
        defer {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
        }

        do {
            try proc.run()
        } catch {
            return .inconclusive("Binaire injoignable : \(error.localizedDescription)")
        }

        // Prompt volontairement minuscule : la sonde doit coûter le moins
        // possible tout en empruntant exactement le chemin de production.
        if let data = "Réponds uniquement: OK".data(using: .utf8) {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
        }
        try? stdinPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning {
            if Date() >= deadline {
                proc.terminate()
                try? await Task.sleep(nanoseconds: 200_000_000)
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                return .inconclusive("Délai dépassé (\(Int(timeout)) s).")
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        if let d = try? outPipe.fileHandleForReading.readDataToEndOfFile(), !d.isEmpty {
            outCollector.append(d)
        }
        if let d = try? errPipe.fileHandleForReading.readDataToEndOfFile(), !d.isEmpty {
            errCollector.append(d)
        }

        let out = String(data: outCollector.snapshot, encoding: .utf8) ?? ""
        let err = String(data: errCollector.snapshot, encoding: .utf8) ?? ""
        if proc.terminationStatus == 0 { return .connected }
        // Même fonction de décision que la production : un seul chemin de
        // classification pour la sonde et pour l'étape .notes.
        if let failure = ClaudeAuthClassifier.classify(exitCode: proc.terminationStatus,
                                                       stdout: out, stderr: err) {
            return .disconnected(failure)
        }
        let joined = (out + "\n" + err).trimmingCharacters(in: .whitespacesAndNewlines)
        // 200 chars, not `ClaudeNoteGenerator.maxCapturedOutput` (4000): that
        // constant sizes a diagnostic blob kept for `nonZeroExit`/`authFailed`
        // and never rendered as-is, while this string is shown directly in
        // the "Tester" button's result in the UI, so it needs to stay
        // short enough to read at a glance rather than complete.
        return .inconclusive(joined.isEmpty
            ? "Échec (code \(proc.terminationStatus))."
            : String(joined.suffix(200)))
    }
}
