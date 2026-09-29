# État de connexion Claude — Plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Onyx détecte que le CLI `claude` est déconnecté, l'affiche (Paramètres, bannière viewer, menu, notification), propose une reconnexion en un clic, et régénère automatiquement les notes perdues pendant la déconnexion.

**Architecture:** Toute la logique décidable vit dans `RecorderCore` : une fonction pure de classification des erreurs du CLI, un actor `ClaudeAuthMonitor` qui détient et persiste le statut, et un sélecteur de réunions en retard. L'étape `.notes` du pipeline rapporte chaque succès/échec au monitor — l'état vient donc de ce qui s'est réellement passé, sans sonde périodique. Le target `Onyx` ne fait que lire un `@Published` et câbler les vues.

**Tech Stack:** Swift 6 / SwiftUI, `swift-tools` SPM, XCTest, `Process` + `osascript`, `AtomicJSON` (helper maison), `os.Logger`.

**Spec de référence :** `docs/superpowers/specs/2026-09-09-claude-auth-status-design.md`

---

## Conventions de ce plan (lis-les avant de commencer)

**Pas de commits.** Ce dépôt ne reçoit ni `git add`, ni `git commit`, ni `git push` — c'est une
règle du propriétaire du projet. Chaque tâche se termine donc par une étape de **vérification**
(`swift build` + `swift test --filter …`), pas par un commit. Ne dévie pas de ça, même si
l'habitude TDD te pousse à committer.

**Cible de test.** Les tests unitaires ne couvrent que `RecorderCore`
(`Tests/RecorderCoreTests`). Aucune tâche n'ajoute de test UI : c'est la convention du dépôt, et
la logique testable a été poussée dans le cœur exprès.

**Commandes utiles :**

```bash
swift build                                   # build debug
swift test --filter ClaudeAuthClassifierTests # une classe de test
swift test                                    # toute la suite
scripts/build-app.sh                          # produit dist/Onyx.app (build + dylibs + signature)
```

**Attention aux réunions en cours.** Avant tout `pkill Onyx` / redéploiement (tâche 12),
vérifie que la réunion la plus récente de `~/Meetings` n'a pas un `job.json` en cours
(`state` ≠ `done`) : tuer l'app pendant un enregistrement perd l'audio.

---

## Structure des fichiers

**Créés — `RecorderCore` (logique, testée)**

| Fichier | Responsabilité |
|---|---|
| `Sources/RecorderCore/Notes/ClaudeAuthError.swift` | `ClaudeAuthFailure` + classification pure de la sortie du CLI. Aucune I/O. |
| `Sources/RecorderCore/Notes/ClaudeAuthMonitor.swift` | `ClaudeAuthStatus` + actor qui détient/persiste le statut et sonde l'auth à la demande. |
| `Sources/RecorderCore/Notes/NotesCatchUp.swift` | Sélection des réunions dont les notes ont échoué sur un problème d'auth. |

**Créés — `Onyx` (UI, non testé)**

| Fichier | Responsabilité |
|---|---|
| `Sources/Onyx/Notes/ClaudeReconnectLauncher.swift` | Lance `claude /login` dans Terminal, avec deux replis. |
| `Sources/Onyx/Notes/ClaudeAuthLabels.swift` | Libellés français d'un `ClaudeAuthStatus` (partagés par les 3 surfaces d'UI). |
| `Sources/Onyx/Viewer/ClaudeAuthBanner.swift` | La bannière orange du viewer. |

**Créés — tests**

- `Tests/RecorderCoreTests/ClaudeAuthClassifierTests.swift`
- `Tests/RecorderCoreTests/ClaudeAuthMonitorTests.swift`
- `Tests/RecorderCoreTests/NotesCatchUpTests.swift`

**Modifiés**

| Fichier | Modification |
|---|---|
| `Sources/RecorderCore/Notes/ClaudeNoteGenerator.swift` | stdout ajouté à `nonZeroExit`, nouveau cas `authFailed`. |
| `Sources/RecorderCore/Pipeline/Pipeline.swift` | `authMonitor` dans `NoteGenerationConfig`, report dans l'étape `.notes`. |
| `Sources/Onyx/AppState.swift` | Monitor, `@Published claudeAuthStatus`, `checkClaudeAuth()`, `catchUpNotes()`. |
| `Sources/Onyx/Settings/SettingsWindow.swift` | Ligne d'état, bouton « Tester », bouton « Se reconnecter… ». |
| `Sources/Onyx/Viewer/ViewerRootView.swift` | Insertion de la bannière. |
| `Sources/Onyx/Viewer/ViewerStore.swift` | `describe(generationFailure:)` : nouvelle signature + cas auth. |
| `Sources/Onyx/Menu/MenuBarView.swift` | Item d'alerte en tête de menu. |
| `Sources/Onyx/Notifications/OptOutNotificationCenter.swift` | `showClaudeDisconnected(_:)`. |
| `Tests/RecorderCoreTests/ClaudeNoteGeneratorTests.swift` | Nouvelle signature d'erreur + 2 tests. |

---

## Task 1 : Classification des erreurs d'auth

**Files:**
- Create: `Sources/RecorderCore/Notes/ClaudeAuthError.swift`
- Test: `Tests/RecorderCoreTests/ClaudeAuthClassifierTests.swift`

Les chaînes testées ici ne sont pas inventées : elles viennent des transcripts réels de
l'incident du 7-8 septembre 2026 (`~/.claude/projects/-Users-yvan-betremieux-Meetings-*`).

- [ ] **Step 1: Écrire le test qui échoue**

Crée `Tests/RecorderCoreTests/ClaudeAuthClassifierTests.swift` :

```swift
import XCTest
@testable import RecorderCore

final class ClaudeAuthClassifierTests: XCTestCase {
    /// Message réel du 2026-09-07T11:12:35Z et des 10 réunions suivantes.
    func testNotLoggedInOnStdout() {
        let out = "Not logged in · Please run /login"
        XCTAssertEqual(ClaudeAuthClassifier.classify(exitCode: 1, stdout: out, stderr: ""),
                       .notLoggedIn)
    }

    /// Message réel du 2026-09-07T08:12:54Z — la toute première défaillance.
    func testSessionExpiredOnStdout() {
        let out = "Failed to authenticate: OAuth session expired and could not be refreshed"
        XCTAssertEqual(ClaudeAuthClassifier.classify(exitCode: 1, stdout: out, stderr: ""),
                       .sessionExpired)
    }

    /// Le CLI écrit sur stdout aujourd'hui. Parier sur ce seul canal est
    /// exactement l'hypothèse qui a causé l'incident : stderr doit marcher aussi.
    func testDetectedOnStderrToo() {
        XCTAssertEqual(ClaudeAuthClassifier.classify(exitCode: 1, stdout: "",
                                                     stderr: "not logged in, please run /login"),
                       .notLoggedIn)
    }

    /// Ces échecs ne sont PAS des déconnexions : proposer « reconnecte-toi »
    /// serait un faux diagnostic.
    func testNonAuthFailuresAreNotClassified() {
        XCTAssertNil(ClaudeAuthClassifier.classify(exitCode: 1,
                                                   stdout: "Invalid API key", stderr: ""))
        XCTAssertNil(ClaudeAuthClassifier.classify(exitCode: 1,
                                                   stdout: "Credit balance too low", stderr: ""))
        XCTAssertNil(ClaudeAuthClassifier.classify(exitCode: 1,
                                                   stdout: "Claude usage limit reached",
                                                   stderr: ""))
        XCTAssertNil(ClaudeAuthClassifier.classify(exitCode: 1, stdout: "", stderr: ""))
    }

    /// Un exit 0 est un succès, quel que soit le texte produit : une note qui
    /// *parle* de login ne doit pas déclencher la bannière.
    func testExitZeroIsNeverAnAuthFailure() {
        let out = "TITRE: Onboarding\n- l'utilisateur doit run /login, il n'est pas logged in"
        XCTAssertNil(ClaudeAuthClassifier.classify(exitCode: 0, stdout: out, stderr: ""))
    }

    func testCaseInsensitiveAndSurroundedByNoise() {
        let out = "\u{1B}[31mERROR\u{1B}[0m NOT LOGGED IN · PLEASE RUN /LOGIN\nbye\n"
        XCTAssertEqual(ClaudeAuthClassifier.classify(exitCode: 1, stdout: out, stderr: ""),
                       .notLoggedIn)
    }
}
```

- [ ] **Step 2: Lancer le test pour vérifier qu'il échoue**

Run: `swift test --filter ClaudeAuthClassifierTests`
Expected: échec de compilation — `cannot find 'ClaudeAuthClassifier' in scope`.

- [ ] **Step 3: Écrire l'implémentation minimale**

Crée `Sources/RecorderCore/Notes/ClaudeAuthError.swift` :

```swift
import Foundation

/// Les deux façons dont le CLI `claude` annonce qu'il n'est plus authentifié.
/// Distinguées parce que le message affiché à l'utilisateur diffère : une
/// session expirée est passive (rien à se reprocher), un « not logged in »
/// signifie que les identifiants ont carrément disparu du trousseau.
public enum ClaudeAuthFailure: String, Codable, Equatable, Sendable {
    case notLoggedIn
    case sessionExpired
}

public enum ClaudeAuthClassifier {
    // Motifs observés sur `claude` 2.1.220 lors de l'incident du 2026-09-07.
    private static let expiredMarkers = [
        "oauth session expired",
        "failed to authenticate",
    ]
    private static let notLoggedInMarkers = [
        "not logged in",
        "please run /login",
        "please run `/login`",
    ]

    /// - Returns: `nil` quand l'échec n'est **pas** un problème
    ///   d'authentification (timeout, quota, clé invalide, sortie vide).
    ///
    /// Lit stdout **et** stderr : le CLI écrit ses diagnostics d'auth sur
    /// stdout aujourd'hui, mais ce détail a déjà changé et ne fait pas partie
    /// de son contrat public.
    public static func classify(exitCode: Int32, stdout: String,
                                stderr: String) -> ClaudeAuthFailure? {
        guard exitCode != 0 else { return nil }
        let haystack = (stdout + "\n" + stderr).lowercased()
        // L'expiration d'abord : c'est le diagnostic le plus spécifique, et un
        // futur message pourrait contenir les deux familles de motifs.
        if expiredMarkers.contains(where: haystack.contains) { return .sessionExpired }
        if notLoggedInMarkers.contains(where: haystack.contains) { return .notLoggedIn }
        return nil
    }
}
```

- [ ] **Step 4: Lancer le test pour vérifier qu'il passe**

Run: `swift test --filter ClaudeAuthClassifierTests`
Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 5: Vérifier que rien d'autre n'a cassé**

Run: `swift build`
Expected: `Build complete`. (Pas de commit — voir les conventions en tête de plan.)

---

## Task 2 : Le générateur conserve stdout et lève `authFailed`

**Files:**
- Modify: `Sources/RecorderCore/Notes/ClaudeNoteGenerator.swift` (enum `GenerationError`, fin de `runClaude`)
- Modify: `Sources/Onyx/Viewer/ViewerStore.swift:1110` (`describe(generationFailure:)`)
- Test: `Tests/RecorderCoreTests/ClaudeNoteGeneratorTests.swift`

C'est le correctif du défaut n°1 de l'incident : le message d'auth arrivait sur stdout, et le
code ne gardait que stderr. Sans cette tâche, rien n'est détectable.

- [ ] **Step 1: Écrire les tests qui échouent**

Dans `Tests/RecorderCoreTests/ClaudeNoteGeneratorTests.swift`, remplace le test existant
`testNonZeroExitRaisesError` (il utilise l'ancienne signature à deux associés) par ces deux
tests :

```swift
    func testNonZeroExitRaisesErrorKeepingBothStreams() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-fail-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("claude")
        try "#!/bin/bash\ncat > /dev/null\necho out-boom\necho err-boom >&2\nexit 3"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)

        let paths = try makeMeetingWithTranscript()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let gen = ClaudeNoteGenerator()
        do {
            try await gen.generate(paths: paths, level: .brief, binary: script)
            XCTFail("expected error")
        } catch ClaudeNoteGenerator.GenerationError.nonZeroExit(let code, let out, let err) {
            XCTAssertEqual(code, 3)
            // stdout était jeté avant ce correctif : c'est ce qui a rendu
            // l'incident du 2026-09-07 indiagnosticable pendant deux jours.
            XCTAssertTrue(out.contains("out-boom"), "stdout must be preserved")
            XCTAssertTrue(err.contains("err-boom"), "stderr must be preserved")
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    /// Reproduction exacte de l'incident : le CLI sort en 1 et écrit son
    /// message d'auth sur stdout.
    func testAuthFailureOnStdoutIsClassified() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-auth-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("claude")
        try "#!/bin/bash\ncat > /dev/null\necho 'Not logged in · Please run /login'\nexit 1"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)

        let paths = try makeMeetingWithTranscript()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        do {
            try await ClaudeNoteGenerator().generate(paths: paths, level: .brief,
                                                     binary: script)
            XCTFail("expected authFailed")
        } catch ClaudeNoteGenerator.GenerationError.authFailed(let failure, let output) {
            XCTAssertEqual(failure, .notLoggedIn)
            XCTAssertTrue(output.contains("Not logged in"))
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }
```

- [ ] **Step 2: Lancer les tests pour vérifier qu'ils échouent**

Run: `swift test --filter ClaudeNoteGeneratorTests`
Expected: échec de compilation — `nonZeroExit` n'accepte pas trois associés, `authFailed`
n'existe pas.

- [ ] **Step 3: Modifier l'enum d'erreur**

Dans `Sources/RecorderCore/Notes/ClaudeNoteGenerator.swift`, remplace la ligne du cas
`nonZeroExit` par :

```swift
        /// `stdout` fait partie de l'erreur, pas seulement `stderr` : le CLI
        /// `claude` écrit ses diagnostics d'authentification sur stdout, et les
        /// jeter a rendu l'incident du 2026-09-07 (11 réunions sans résumé)
        /// invisible dans `job.json`.
        case nonZeroExit(code: Int32, stdout: String, stderr: String)
        /// Le CLI n'est plus authentifié. Cas distinct de `nonZeroExit` parce
        /// qu'il touchera *toutes* les réunions suivantes tant qu'il n'est pas
        /// réglé — c'est le seul échec de notes qui mérite une alerte.
        case authFailed(ClaudeAuthFailure, output: String)
```

- [ ] **Step 4: Modifier la sortie d'erreur de `runClaude`**

Toujours dans le même fichier, remplace le bloc `guard proc.terminationStatus == 0 else { … }` de
`runClaude` par :

```swift
        guard proc.terminationStatus == 0 else {
            let out = String(data: stdoutCollector.snapshot, encoding: .utf8) ?? ""
            let err = String(data: stderrCollector.snapshot, encoding: .utf8) ?? ""
            if let failure = ClaudeAuthClassifier.classify(
                exitCode: proc.terminationStatus, stdout: out, stderr: err) {
                throw GenerationError.authFailed(failure,
                                                 output: out.isEmpty ? err : out)
            }
            throw GenerationError.nonZeroExit(code: proc.terminationStatus,
                                              stdout: out, stderr: err)
        }
```

- [ ] **Step 5: Mettre à jour le seul autre lecteur de l'erreur**

Dans `Sources/Onyx/Viewer/ViewerStore.swift`, dans `describe(generationFailure:)`, remplace le
`case … nonZeroExit(let code, let stderr):` existant par :

```swift
        case ClaudeNoteGenerator.GenerationError.authFailed(let failure, _):
            switch failure {
            case .sessionExpired:
                return "Session Claude expirée : reconnecte-toi dans Réglages → Notes."
            case .notLoggedIn:
                return "Claude n'est pas connecté : reconnecte-toi dans Réglages → Notes."
            }
        case ClaudeNoteGenerator.GenerationError.nonZeroExit(let code, let stdout, let stderr):
            // Les deux flux, stdout d'abord : le CLI y met l'essentiel de ses
            // diagnostics, stderr est souvent vide.
            let joined = (stdout + "\n" + stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = joined.suffix(300)
            return tail.isEmpty
                ? "Claude a échoué (code \(code))."
                : "Claude a échoué (code \(code)) : \(tail)"
```

- [ ] **Step 6: Lancer les tests pour vérifier qu'ils passent**

Run: `swift test --filter ClaudeNoteGeneratorTests`
Expected: tous les tests de la classe passent.

- [ ] **Step 7: Vérifier la suite complète et le build de l'app**

Run: `swift test && swift build`
Expected: `Build complete` et aucun test en échec. Si un autre test référençait `nonZeroExit`,
corrige-le vers la signature à trois associés.

---

## Task 3 : `ClaudeAuthMonitor` — statut persistant

**Files:**
- Create: `Sources/RecorderCore/Notes/ClaudeAuthMonitor.swift`
- Test: `Tests/RecorderCoreTests/ClaudeAuthMonitorTests.swift`

- [ ] **Step 1: Écrire les tests qui échouent**

Crée `Tests/RecorderCoreTests/ClaudeAuthMonitorTests.swift` :

```swift
import XCTest
@testable import RecorderCore

final class ClaudeAuthMonitorTests: XCTestCase {
    /// Compteur d'appels du callback de transition, thread-safe : l'actor peut
    /// l'appeler depuis n'importe quel contexte.
    private final class ChangeSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [ClaudeAuthStatus] = []
        func record(_ s: ClaudeAuthStatus) { lock.lock(); seen.append(s); lock.unlock() }
        var all: [ClaudeAuthStatus] { lock.lock(); defer { lock.unlock() }; return seen }
    }

    private func tempStateFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-auth-\(UUID().uuidString).json")
    }

    func testStartsUnknownWithNoStateFile() async {
        let monitor = ClaudeAuthMonitor(stateFile: tempStateFile())
        let status = await monitor.status
        XCTAssertEqual(status, .unknown)
    }

    func testAuthFailureBecomesDisconnectedAndPersists() async throws {
        let file = tempStateFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let spy = ChangeSpy()
        let monitor = ClaudeAuthMonitor(stateFile: file) { spy.record($0) }

        let err = ClaudeNoteGenerator.GenerationError.authFailed(.sessionExpired, output: "x")
        await monitor.reportFailure(err)

        let status = await monitor.status
        guard case .disconnected(let failure, _) = status else {
            return XCTFail("expected disconnected, got \(status)")
        }
        XCTAssertEqual(failure, .sessionExpired)
        XCTAssertEqual(spy.all.count, 1)
        // Persisté : la bannière doit être correcte dès le prochain lancement,
        // sans attendre une première réunion.
        let reread = ClaudeAuthMonitor(stateFile: file)
        let rereadStatus = await reread.status
        XCTAssertEqual(rereadStatus, status)
    }

    /// Onze réunions ont échoué d'affilée pendant l'incident. Le callback ne
    /// doit tirer qu'une fois, sinon c'est onze notifications macOS.
    func testRepeatedFailuresNotifyOnce() async {
        let file = tempStateFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let spy = ChangeSpy()
        let monitor = ClaudeAuthMonitor(stateFile: file) { spy.record($0) }
        let err = ClaudeNoteGenerator.GenerationError.authFailed(.notLoggedIn, output: "")

        for _ in 0..<11 { await monitor.reportFailure(err) }

        XCTAssertEqual(spy.all.count, 1)
    }

    func testSuccessAfterDisconnectionReconnects() async {
        let file = tempStateFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let spy = ChangeSpy()
        let monitor = ClaudeAuthMonitor(stateFile: file) { spy.record($0) }
        await monitor.reportFailure(
            ClaudeNoteGenerator.GenerationError.authFailed(.notLoggedIn, output: ""))

        await monitor.reportSuccess()

        let status = await monitor.status
        guard case .connected = status else {
            return XCTFail("expected connected, got \(status)")
        }
        XCTAssertEqual(spy.all.count, 2)
    }

    /// Un timeout ou un quota n'est pas une déconnexion : le statut ne bouge
    /// pas et aucune bannière ne s'affiche.
    func testNonAuthFailureLeavesStatusUntouched() async {
        let file = tempStateFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let spy = ChangeSpy()
        let monitor = ClaudeAuthMonitor(stateFile: file) { spy.record($0) }

        await monitor.reportFailure(ClaudeNoteGenerator.GenerationError.timedOut)
        await monitor.reportFailure(
            ClaudeNoteGenerator.GenerationError.nonZeroExit(code: 1, stdout: "quota",
                                                            stderr: ""))

        let status = await monitor.status
        XCTAssertEqual(status, .unknown)
        XCTAssertTrue(spy.all.isEmpty)
    }

    /// Deux succès consécutifs rafraîchissent l'horodatage mais ne sont pas une
    /// transition — pas de callback pour le second.
    func testSecondSuccessDoesNotNotifyButRefreshesTimestamp() async {
        let file = tempStateFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let spy = ChangeSpy()
        let monitor = ClaudeAuthMonitor(stateFile: file) { spy.record($0) }

        let early = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)
        await monitor.reportSuccess(at: early)
        await monitor.reportSuccess(at: later)

        let status = await monitor.status
        XCTAssertEqual(status, .connected(checkedAt: later))
        XCTAssertEqual(spy.all.count, 1)
    }

    func testCorruptStateFileDegradesToUnknown() async throws {
        let file = tempStateFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try "{ not json".write(to: file, atomically: true, encoding: .utf8)

        let monitor = ClaudeAuthMonitor(stateFile: file)
        let status = await monitor.status
        XCTAssertEqual(status, .unknown)
    }
}
```

- [ ] **Step 2: Lancer les tests pour vérifier qu'ils échouent**

Run: `swift test --filter ClaudeAuthMonitorTests`
Expected: échec de compilation — `cannot find 'ClaudeAuthMonitor' in scope`.

- [ ] **Step 3: Écrire l'implémentation**

Crée `Sources/RecorderCore/Notes/ClaudeAuthMonitor.swift` :

```swift
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
        current = new
        do {
            try FileManager.default.createDirectory(
                at: stateFile.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try AtomicJSON.write(new, to: stateFile)
        } catch {
            Log.pipeline.warning(
                "Could not persist Claude auth status: \(String(describing: error), privacy: .public)")
        }
        if isTransition {
            Log.pipeline.info("Claude auth status → \(String(describing: new), privacy: .public)")
            onChange?(new)
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

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
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
        return .inconclusive(joined.isEmpty
            ? "Échec (code \(proc.terminationStatus))."
            : String(joined.suffix(200)))
    }
}
```

- [ ] **Step 4: Lancer les tests pour vérifier qu'ils passent**

Run: `swift test --filter ClaudeAuthMonitorTests`
Expected: `Executed 7 tests, with 0 failures`.

- [ ] **Step 5: Vérification**

Run: `swift build`
Expected: `Build complete`.

---

## Task 4 : Le pipeline rapporte au monitor

**Files:**
- Modify: `Sources/RecorderCore/Pipeline/Pipeline.swift` (`NoteGenerationConfig`, étape `.notes`)
- Test: `Tests/RecorderCoreTests/PipelineTests.swift`

- [ ] **Step 1: Écrire les tests qui échouent**

Ajoute à la fin de `Tests/RecorderCoreTests/PipelineTests.swift` (avant l'accolade de fermeture
de la classe) :

```swift
    /// Le chemin qui a manqué pendant l'incident : un échec d'auth de l'étape
    /// .notes doit remonter au monitor, sinon l'app reste muette.
    func testNotesAuthFailureIsReportedToMonitor() async throws {
        let (paths, storage) = try Self.makeMeetingWithArtifacts()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        // Message réel du CLI déconnecté, sur stdout, avec exit 1.
        let bin = try Self.makeFakeClaude(output: "Not logged in · Please run /login",
                                          exitCode: 1)
        defer { try? FileManager.default.removeItem(at: bin.deletingLastPathComponent()) }

        let stateFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-auth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stateFile) }
        let monitor = ClaudeAuthMonitor(stateFile: stateFile)

        let cfg = NoteGenerationConfig(binary: bin, level: .brief, authMonitor: monitor)
        let pipeline = Pipeline(storage: storage, whisper: Self.stubWhisper,
                                diarizer: Self.stubDiar, notes: cfg)
        try await pipeline.run(paths: paths)

        let status = await monitor.status
        guard case .disconnected(let failure, _) = status else {
            return XCTFail("expected disconnected, got \(status)")
        }
        XCTAssertEqual(failure, .notLoggedIn)
        // Le soft-fail reste inchangé : le transcript demeure valide.
        let job = try storage.loadJob(paths)
        XCTAssertEqual(job.state, .done)
        XCTAssertEqual(job.stepStatus(.notes), .failed)
    }

    func testNotesSuccessReportsConnected() async throws {
        let (paths, storage) = try Self.makeMeetingWithArtifacts()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let bin = try Self.makeFakeClaude(output: "# note")
        defer { try? FileManager.default.removeItem(at: bin.deletingLastPathComponent()) }

        let stateFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-auth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stateFile) }
        let monitor = ClaudeAuthMonitor(stateFile: stateFile)

        let cfg = NoteGenerationConfig(binary: bin, level: .brief, authMonitor: monitor)
        let pipeline = Pipeline(storage: storage, whisper: Self.stubWhisper,
                                diarizer: Self.stubDiar, notes: cfg)
        try await pipeline.run(paths: paths)

        let status = await monitor.status
        guard case .connected = status else {
            return XCTFail("expected connected, got \(status)")
        }
    }

    /// Un échec non-auth (ici exit 7 sans message reconnaissable) ne doit pas
    /// faire croire à une déconnexion.
    func testNotesNonAuthFailureLeavesMonitorUnknown() async throws {
        let (paths, storage) = try Self.makeMeetingWithArtifacts()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let bin = try Self.makeFakeClaude(output: "boom", exitCode: 7)
        defer { try? FileManager.default.removeItem(at: bin.deletingLastPathComponent()) }

        let stateFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-auth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stateFile) }
        let monitor = ClaudeAuthMonitor(stateFile: stateFile)

        let cfg = NoteGenerationConfig(binary: bin, level: .brief, authMonitor: monitor)
        let pipeline = Pipeline(storage: storage, whisper: Self.stubWhisper,
                                diarizer: Self.stubDiar, notes: cfg)
        try await pipeline.run(paths: paths)

        let status = await monitor.status
        XCTAssertEqual(status, .unknown)
    }
```

- [ ] **Step 2: Lancer les tests pour vérifier qu'ils échouent**

Run: `swift test --filter PipelineTests`
Expected: échec de compilation — `NoteGenerationConfig` n'a pas d'argument `authMonitor`.

- [ ] **Step 3: Ajouter `authMonitor` à la config**

Dans `Sources/RecorderCore/Pipeline/Pipeline.swift`, `struct NoteGenerationConfig` : ajoute le
champ après `model`, et propage-le dans **les deux** initialiseurs (le multi-niveaux et la
commodité mono-niveau — laisser le second en arrière équivaudrait à un monitor muet dans les
tests et les call sites chantier-2) :

```swift
    /// Destinataire des succès/échecs d'authentification. Optionnel : les tests
    /// et les call sites qui n'en ont pas besoin passent `nil`.
    public let authMonitor: ClaudeAuthMonitor?
```

Ajoute `authMonitor: ClaudeAuthMonitor? = nil` en dernier paramètre des deux `init`, et
`self.authMonitor = authMonitor` dans leurs corps.

- [ ] **Step 4: Rapporter depuis l'étape `.notes`**

Toujours dans `Pipeline.swift`, dans le corps de `await runStepSoft(.notes, …) { … }`, encadre le
`withThrowingTaskGroup` existant. Le `guard let cfg`, le calcul de `todo` et le
`withThrowingTaskGroup` ne changent pas : seul l'encadrement est nouveau.

```swift
            do {
                try await withThrowingTaskGroup(of: String?.self) { group in
                    // … corps existant, inchangé …
                }
                await cfg.authMonitor?.reportSuccess()
            } catch {
                // Report AVANT le rethrow : `runStepSoft` va avaler l'erreur
                // (par conception, une note manquante n'invalide pas un
                // transcript), donc c'est le dernier endroit où l'information
                // d'authentification existe encore.
                await cfg.authMonitor?.reportFailure(error)
                throw error
            }
```

- [ ] **Step 5: Lancer les tests pour vérifier qu'ils passent**

Run: `swift test --filter PipelineTests`
Expected: toute la classe passe, y compris les tests existants
`testPipelineTolerantToNotesFailure` et `testPipelineRunsNotesStepWhenConfigured`.

- [ ] **Step 6: Vérification**

Run: `swift test && swift build`
Expected: suite complète verte, `Build complete`.

---

## Task 5 : `NotesCatchUp` — sélection des réunions en retard

**Files:**
- Create: `Sources/RecorderCore/Notes/NotesCatchUp.swift`
- Test: `Tests/RecorderCoreTests/NotesCatchUpTests.swift`

- [ ] **Step 1: Écrire les tests qui échouent**

Crée `Tests/RecorderCoreTests/NotesCatchUpTests.swift` :

```swift
import XCTest
@testable import RecorderCore

final class NotesCatchUpTests: XCTestCase {
    private func makeStorage() throws -> (MeetingStorage, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-catchup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (MeetingStorage(root: root), root)
    }

    /// Crée une réunion au slug donné avec un `job.json` dont l'étape .notes
    /// porte le statut et l'erreur voulus.
    private func makeMeeting(_ storage: MeetingStorage, slug: String,
                             notesStatus: JobStepStatus,
                             notesError: String?) throws {
        let paths = MeetingPaths(root: storage.root, slug: slug)
        try FileManager.default.createDirectory(at: paths.root,
                                                withIntermediateDirectories: true)
        var job = JobState.fresh()
        for step in JobStep.allCases { job.markDone(step) }
        job.state = .done
        job.steps[.notes] = JobStepRecord(status: notesStatus, startedAt: Date(),
                                          completedAt: Date(), error: notesError)
        try storage.saveJob(job, at: paths)
    }

    func testSelectsOnlyAuthFailures() throws {
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }

        try makeMeeting(storage, slug: "2026-09-08_09h59", notesStatus: .failed,
                        notesError: "authFailed(RecorderCore.ClaudeAuthFailure.notLoggedIn, output: \"Not logged in\")")
        try makeMeeting(storage, slug: "2026-09-08_10h29", notesStatus: .failed,
                        notesError: "timedOut")
        try makeMeeting(storage, slug: "2026-09-08_11h01", notesStatus: .done,
                        notesError: nil)

        let pending = try NotesCatchUp.pendingSlugs(storage: storage)
        XCTAssertEqual(pending, ["2026-09-08_09h59"])
    }

    /// Les `job.json` écrits AVANT le correctif de la tâche 2 ne contiennent
    /// que `nonZeroExit(code: 1, stderr: "")` — aucun marqueur d'auth. Ils ne
    /// sont donc pas récupérables, et c'est assumé (voir le spec).
    func testLegacyErrorsWithoutMarkersAreNotSelected() throws {
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeMeeting(storage, slug: "2026-09-07_09h59", notesStatus: .failed,
                        notesError: "nonZeroExit(code: 1, stderr: \"\")")

        XCTAssertTrue(try NotesCatchUp.pendingSlugs(storage: storage).isEmpty)
    }

    /// Un `job.json` postérieur au correctif qui garde le message brut du CLI
    /// est reconnu par motif, même sans le nom du cas Swift.
    func testRawCliMessageIsRecognised() throws {
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeMeeting(storage, slug: "2026-09-08_14h46", notesStatus: .failed,
                        notesError: "nonZeroExit(code: 1, stdout: \"Not logged in · Please run /login\", stderr: \"\")")

        XCTAssertEqual(try NotesCatchUp.pendingSlugs(storage: storage),
                       ["2026-09-08_14h46"])
    }

    func testResultIsChronological() throws {
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let err = "authFailed(RecorderCore.ClaudeAuthFailure.notLoggedIn, output: \"\")"
        try makeMeeting(storage, slug: "2026-09-08_14h46", notesStatus: .failed, notesError: err)
        try makeMeeting(storage, slug: "2026-09-07_09h59", notesStatus: .failed, notesError: err)
        try makeMeeting(storage, slug: "2026-09-08_09h59", notesStatus: .failed, notesError: err)

        XCTAssertEqual(try NotesCatchUp.pendingSlugs(storage: storage),
                       ["2026-09-07_09h59", "2026-09-08_09h59", "2026-09-08_14h46"])
    }

    /// Un dossier sans `job.json` lisible est ignoré, sans faire échouer tout
    /// le balayage.
    func testUnreadableJobIsSkipped() throws {
        let (storage, root) = try makeStorage()
        defer { try? FileManager.default.removeItem(at: root) }
        let orphan = root.appendingPathComponent("2026-09-08_16h00", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try "not json".write(to: orphan.appendingPathComponent("job.json"),
                             atomically: true, encoding: .utf8)

        XCTAssertNoThrow(try NotesCatchUp.pendingSlugs(storage: storage))
        XCTAssertTrue(try NotesCatchUp.pendingSlugs(storage: storage).isEmpty)
    }
}
```

- [ ] **Step 2: Lancer les tests pour vérifier qu'ils échouent**

Run: `swift test --filter NotesCatchUpTests`
Expected: échec de compilation — `cannot find 'NotesCatchUp' in scope`.

- [ ] **Step 3: Écrire l'implémentation**

Crée `Sources/RecorderCore/Notes/NotesCatchUp.swift` :

```swift
import Foundation

/// Trouve les réunions dont les notes ont été perdues à cause d'une
/// déconnexion du CLI, pour les régénérer une fois l'authentification
/// rétablie.
public enum NotesCatchUp {
    /// Motifs cherchés dans l'erreur enregistrée dans `job.json`. Cette erreur
    /// est le `String(describing:)` d'une erreur Swift, donc on reconnaît :
    /// - le nom du cas (`authFailed`) pour les échecs postérieurs au correctif
    /// - les messages bruts du CLI, au cas où ils arrivent par un autre cas
    ///   d'erreur (ex. `nonZeroExit` qui embarque désormais stdout)
    private static let markers = [
        "authfailed",
        "not logged in",
        "please run /login",
        "oauth session expired",
    ]

    /// Slugs à rattraper, en ordre chronologique (le slug est daté, donc l'ordre
    /// lexicographique *est* l'ordre chronologique).
    ///
    /// Chronologique et non arbitraire : le rattrapage est séquentiel, et une
    /// réunion de continuation dépend de l'absorption de son parent.
    public static func pendingSlugs(storage: MeetingStorage) throws -> [String] {
        let listings = try storage.listMeetings()
        var out: [String] = []
        for listing in listings {
            let paths = MeetingPaths(root: storage.root, slug: listing.slug)
            // Un job illisible est ignoré : un dossier abîmé ne doit pas
            // empêcher le rattrapage des autres.
            guard let job = try? storage.loadJob(paths) else { continue }
            guard let record = job.steps[.notes], record.status == .failed,
                  let error = record.error?.lowercased() else { continue }
            if markers.contains(where: error.contains) { out.append(listing.slug) }
        }
        return out.sorted()
    }
}
```

- [ ] **Step 4: Lancer les tests pour vérifier qu'ils passent**

Run: `swift test --filter NotesCatchUpTests`
Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Vérification**

Run: `swift test && swift build`
Expected: suite verte, `Build complete`.

---

## Task 6 : Câblage dans `AppState` + notification

**Files:**
- Modify: `Sources/Onyx/Notifications/OptOutNotificationCenter.swift`
- Modify: `Sources/Onyx/AppState.swift`
- Modify: `Sources/Onyx/App.swift`

Aucun test : `Tests/RecorderCoreTests` ne couvre pas le target `Onyx` (convention du dépôt). La
logique est déjà testée aux tâches 1-5 ; ici on ne fait que câbler.

La notification est créée **dans cette tâche** et pas plus loin : `applyClaudeAuthStatus`
l'appelle, donc les séparer casserait le build entre deux tâches.

- [ ] **Step 1: Ajouter la notification macOS**

Dans `Sources/Onyx/Notifications/OptOutNotificationCenter.swift`, ajoute après `showIgnored` :

```swift
    /// Déconnexion du CLI Claude. Déclenchée par une *transition* de statut,
    /// donc une seule fois : pendant l'incident du 2026-09-07, onze réunions
    /// ont échoué d'affilée et onze notifications auraient été du bruit.
    public func showClaudeDisconnected(_ failure: ClaudeAuthFailure) {
        configureIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "Claude déconnecté"
        content.body = failure == .sessionExpired
            ? "La session Claude a expiré : les résumés de réunion ne sont plus "
              + "générés. Reconnecte-toi dans les Réglages d'Onyx."
            : "Claude n'est pas connecté : les résumés de réunion ne sont plus "
              + "générés. Reconnecte-toi dans les Réglages d'Onyx."
        // Identifiant FIXE (pas un UUID) : une nouvelle notification remplace la
        // précédente au lieu d'empiler des doublons dans le centre de
        // notifications.
        let req = UNNotificationRequest(identifier: "onyx.claude.disconnected",
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
```

- [ ] **Step 2: Déclarer l'état publié et le monitor**

Après `@Published public var lastError: String?` :

```swift
    /// État d'authentification du CLI `claude`, miroir du `ClaudeAuthMonitor`
    /// pour que les vues SwiftUI (bannière, menu, réglages) puissent le lire.
    @Published public var claudeAuthStatus: ClaudeAuthStatus = .unknown
    /// Progression du rattrapage des notes perdues : (fait, total). `nil` quand
    /// aucun rattrapage n'est en cours.
    @Published public var notesCatchUpProgress: (done: Int, total: Int)?
```

Puis, à côté de `private let pipeline: Pipeline` :

```swift
    public let claudeAuthMonitor: ClaudeAuthMonitor
```

- [ ] **Step 3: Construire le monitor dans `init`, avant le pipeline**

Dans `init()`, juste avant la construction du `pipeline` (ligne ~101), insère :

```swift
        // Même dossier que index.sqlite — c'est là que vit l'état applicatif
        // qui n'appartient à aucune réunion.
        let authStateURL = FileManager.default.urls(for: .applicationSupportDirectory,
                                                    in: .userDomainMask)[0]
            .appendingPathComponent("Onyx/claude-auth.json")
        // Le handler ne peut pas capturer `self` (pas encore initialisé) : il
        // passe par NotificationCenter, et `init` s'y abonne juste après.
        claudeAuthMonitor = ClaudeAuthMonitor(stateFile: authStateURL) { status in
            NotificationCenter.default.post(name: AppState.claudeAuthDidChange,
                                            object: nil,
                                            userInfo: ["status": status])
        }
```

Et modifie la construction du pipeline pour passer le monitor :

```swift
        pipeline = Pipeline(storage: storage, whisper: sharedWhisper,
                            notes: Self.notesConfig(from: settings,
                                                     authMonitor: claudeAuthMonitor))
```

- [ ] **Step 4: Déclarer le nom de notification et s'y abonner**

Ajoute au niveau du type (à côté des autres membres statiques) :

```swift
    /// Émise par le `ClaudeAuthMonitor` à chaque *transition* de statut — donc
    /// une seule fois par déconnexion, pas une par réunion en échec.
    public static let claudeAuthDidChange = Notification.Name("onyx.claudeAuthDidChange")
```

À la fin de `init()`, après les autres abonnements Combine :

```swift
        NotificationCenter.default.publisher(for: AppState.claudeAuthDidChange)
            .compactMap { $0.userInfo?["status"] as? ClaudeAuthStatus }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.applyClaudeAuthStatus(status) }
            .store(in: &cancellables)
```

- [ ] **Step 5: Mettre à jour `notesConfig(from:)`**

Remplace la signature et le `return` de la méthode statique existante :

```swift
    private static func notesConfig(from settings: SettingsStore,
                                    authMonitor: ClaudeAuthMonitor?)
        -> NoteGenerationConfig? {
        let binaryURL: URL? = settings.claudeBinaryPath.isEmpty
            ? nil : URL(fileURLWithPath: settings.claudeBinaryPath)
        let levels = settings.defaultNoteLevels.filter { $0 != .live }
        guard settings.autoNotesEnabled, binaryURL != nil, !levels.isEmpty else { return nil }
        return NoteGenerationConfig(binary: binaryURL, levels: levels,
                                    model: settings.claudeModel.isEmpty
                                           ? nil : settings.claudeModel,
                                    authMonitor: authMonitor)
    }
```

Et dans `reloadNotesConfig()`, remplace l'appel par :

```swift
        let cfg = Self.notesConfig(from: settings, authMonitor: claudeAuthMonitor)
```

- [ ] **Step 6: Réagir aux transitions et charger l'état au démarrage**

Ajoute ces méthodes à `AppState` (près de `regenerateNotes`) :

```swift
    /// Applique une transition de statut : met à jour l'UI, notifie une seule
    /// fois en cas de déconnexion, lance le rattrapage en cas de reconnexion.
    private func applyClaudeAuthStatus(_ status: ClaudeAuthStatus) {
        let wasDisconnected = claudeAuthStatus.isDisconnected
        claudeAuthStatus = status
        switch status {
        case .disconnected(let failure, _):
            OptOutNotificationCenter.shared.showClaudeDisconnected(failure)
        case .connected:
            // Rattrapage seulement au retour d'une déconnexion : au démarrage
            // normal, `bootClaudeAuth` s'en charge séparément.
            if wasDisconnected { catchUpNotes() }
        case .unknown:
            break
        }
    }

    /// Lit le statut persisté au lancement et rattrape ce qui traîne. Appelé
    /// depuis `App.swift` au même endroit que `bootAutotrigger()`.
    public func bootClaudeAuth() {
        let monitor = claudeAuthMonitor
        Task {
            let status = await monitor.status
            self.claudeAuthStatus = status
            if !status.isDisconnected { self.catchUpNotes() }
        }
    }

    /// Sonde explicite (bouton « Tester » des réglages / de la bannière).
    /// - Returns: un message affichable, décrivant le résultat.
    public func checkClaudeAuth() async -> String {
        let path = settings.claudeBinaryPath
        guard !path.isEmpty else { return "Chemin du binaire Claude non configuré." }
        let binary = URL(fileURLWithPath: path)
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return "Le binaire est introuvable ou non exécutable : \(path)"
        }
        let model = settings.claudeModel.isEmpty ? nil : settings.claudeModel
        let outcome = await claudeAuthMonitor.probe(binary: binary, model: model)
        // Le monitor a déjà appliqué (ou non) la transition ; on resynchronise
        // l'état publié pour le cas `inconclusive`, qui ne déclenche rien.
        claudeAuthStatus = await claudeAuthMonitor.status
        switch outcome {
        case .connected:
            return "Connecté — Claude a répondu."
        case .disconnected(let failure):
            return failure == .sessionExpired
                ? "Session expirée : reconnecte-toi."
                : "Non connecté : reconnecte-toi."
        case .inconclusive(let why):
            return "Vérification impossible : \(why)"
        }
    }

    /// Régénère séquentiellement les notes des réunions perdues pendant une
    /// déconnexion.
    ///
    /// Passe par `pipeline.run` plutôt que par un chemin de génération dédié :
    /// tous les autres steps étant `.done`, seule l'étape `.notes` s'exécute, et
    /// on hérite gratuitement du `waitWhileRecording` du pipeline — donc aucune
    /// rafale d'appels `claude` pendant une réunion (charge ANE).
    public func catchUpNotes() {
        guard notesCatchUpProgress == nil else { return } // déjà en cours
        let storage = self.storage
        let pipeline = self.pipeline
        let indexer = self.indexer
        let monitor = self.claudeAuthMonitor
        Task {
            let slugs = (try? NotesCatchUp.pendingSlugs(storage: storage)) ?? []
            guard !slugs.isEmpty else { return }
            Log.ui.info("Notes catch-up: \(slugs.count, privacy: .public) meeting(s)")
            self.notesCatchUpProgress = (done: 0, total: slugs.count)
            defer { self.notesCatchUpProgress = nil }
            let runner = RescanRunner(storage: storage, indexer: indexer)
            for (i, slug) in slugs.enumerated() {
                // Une nouvelle déconnexion en cours de route arrête tout :
                // enchaîner des appels condamnés n'aide personne.
                if await monitor.status.isDisconnected {
                    Log.ui.info("Notes catch-up aborted — Claude disconnected again")
                    break
                }
                let paths = MeetingPaths(root: storage.root, slug: slug)
                try? await pipeline.run(paths: paths)
                runner.reindex(slug: slug)
                self.notesCatchUpProgress = (done: i + 1, total: slugs.count)
            }
        }
    }
```

- [ ] **Step 7: Appeler `bootClaudeAuth()` au démarrage**

Dans `Sources/Onyx/App.swift`, à l'endroit où `bootAutotrigger()` et `resumePendingJobs()` sont
appelés, ajoute `app.bootClaudeAuth()` **avant** `resumePendingJobs()` (le rattrapage doit
connaître le statut avant de lancer quoi que ce soit).

- [ ] **Step 8: Vérification**

Run: `swift build`
Expected: `Build complete`. Le build doit être vert à la fin de cette tâche : tout ce qu'elle
appelle (`ClaudeAuthMonitor`, `NotesCatchUp`, `showClaudeDisconnected`) existe désormais.

---

## Task 7 : Lanceur de reconnexion

**Files:**
- Create: `Sources/Onyx/Notes/ClaudeReconnectLauncher.swift`

- [ ] **Step 1: Écrire l'implémentation**

Crée `Sources/Onyx/Notes/ClaudeReconnectLauncher.swift` :

```swift
import AppKit
import Foundation
import RecorderCore

/// Ouvre un vrai terminal sur `claude /login`. Le flux de login est interactif
/// (TUI + navigateur) : Onyx ne peut pas le faire à sa place, seulement
/// l'amorcer.
@MainActor
enum ClaudeReconnectLauncher {
    enum Outcome {
        /// Terminal ouvert : à l'utilisateur de finir le login.
        case launched
        /// Aucun terminal n'a pu être ouvert, la commande est dans le
        /// presse-papier.
        case copiedToClipboard(String)
        case failed(String)
    }

    static func launch(binary: URL) -> Outcome {
        let command = "\(shellQuoted(binary.path)) /login"

        // 1. AppleScript. Onyx utilise déjà osascript (détection Meet) et
        //    déclare NSAppleEventsUsageDescription.
        if runAppleScript("""
            tell application "Terminal"
                activate
                do script "\(appleScriptQuoted(command))"
            end tell
            """) {
            return .launched
        }

        // 2. Repli : un script .command ouvert par le Finder. Aucune
        //    autorisation Automation requise — c'est ce qui sauve la situation
        //    quand l'utilisateur a refusé la permission une fois pour toutes.
        if let script = writeCommandScript(command) {
            NSWorkspace.shared.open(script)
            return .launched
        }

        // 3. Dernier recours : la commande, à coller soi-même.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        return .copiedToClipboard(command)
    }

    // MARK: - Détails

    private static func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        script.executeAndReturnError(&error)
        if let error {
            // -1743 = l'utilisateur n'a pas accordé l'autorisation Automation.
            Log.ui.warning(
                "Terminal AppleScript failed: \(String(describing: error), privacy: .public)")
            return false
        }
        return true
    }

    private static func writeCommandScript(_ command: String) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-claude-login-\(UUID().uuidString).command")
        let body = """
        #!/bin/bash
        echo "Onyx : reconnexion à Claude. Termine le login, puis ferme cette fenêtre."
        \(command)
        """
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: url.path)
            return url
        } catch {
            Log.ui.error(
                "Could not write .command fallback: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Échappe un chemin pour le shell (le binaire vit sous
    /// ~/.nvm/versions/node/…, mais un chemin à espaces doit marcher).
    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Échappe pour une chaîne littérale AppleScript.
    private static func appleScriptQuoted(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
```

- [ ] **Step 2: Vérifier la compilation**

Run: `swift build`
Expected: `Build complete`.

---

## Task 8 : Libellés partagés + UI des réglages

**Files:**
- Create: `Sources/Onyx/Notes/ClaudeAuthLabels.swift`
- Modify: `Sources/Onyx/Settings/SettingsWindow.swift`

- [ ] **Step 1: Créer les libellés**

Crée `Sources/Onyx/Notes/ClaudeAuthLabels.swift` :

```swift
import SwiftUI
import RecorderCore

/// Libellés français d'un `ClaudeAuthStatus`, partagés par les trois surfaces
/// d'UI (réglages, bannière, menu) pour qu'elles ne puissent pas se
/// contredire.
extension ClaudeAuthStatus {
    var shortLabel: String {
        switch self {
        case .unknown: return "État inconnu"
        case .connected: return "Connecté"
        case .disconnected: return "Déconnecté"
        }
    }

    var detailLabel: String {
        switch self {
        case .unknown:
            return "aucune génération de notes depuis le dernier lancement"
        case .connected(let checkedAt):
            return "vérifié \(Self.relative(checkedAt))"
        case .disconnected(let failure, let since):
            let cause = failure == .sessionExpired ? "session expirée" : "non connecté"
            return "\(cause) depuis \(Self.relative(since))"
        }
    }

    var indicatorColor: Color {
        switch self {
        case .unknown: return .secondary
        case .connected: return .green
        case .disconnected: return .orange
        }
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}
```

- [ ] **Step 2: Remplacer la section « Claude » des réglages**

Dans `Sources/Onyx/Settings/SettingsWindow.swift`, remplace la `Section("Claude") { … }` du
`notesTab` par :

```swift
            Section("Claude") {
                Picker("Model", selection: $settings.claudeModel) {
                    Text("CLI default").tag("")
                    Text("Haiku").tag("haiku")
                    Text("Sonnet").tag("sonnet")
                    Text("Opus").tag("opus")
                }
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(app.claudeAuthStatus.indicatorColor)
                    Text(app.claudeAuthStatus.shortLabel).bold()
                    Text("— \(app.claudeAuthStatus.detailLabel)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Claude binary path", text: $settings.claudeBinaryPath)
                    // Un seul bouton, qui teste le binaire ET l'authentification.
                    // L'ancien « Test » ne lançait que `--version`, qui réussit
                    // même déconnecté : c'est ce faux positif qui a laissé
                    // l'incident du 2026-09-07 passer inaperçu deux jours.
                    Button(claudeTesting ? "Test…" : "Tester") { testClaude() }
                        .disabled(claudeTesting)
                }
                if !claudeTestResult.isEmpty {
                    Text(claudeTestResult).font(.caption).foregroundStyle(.secondary)
                }
                Button("Se reconnecter à Claude…") { reconnectClaude() }
                    .disabled(settings.claudeBinaryPath.isEmpty)
            }
```

- [ ] **Step 3: Remplacer `testClaudeBinary()` par les deux actions**

Dans le même fichier, remplace la méthode `testClaudeBinary()` par :

```swift
    /// Vérifie d'abord que le binaire répond (`--version`), puis que
    /// l'authentification passe (vraie mini-requête). Les deux comptent : un
    /// binaire présent mais déconnecté ne génère aucune note.
    private func testClaude() {
        let path = settings.claudeBinaryPath
        guard !path.isEmpty else { claudeTestResult = "Chemin vide."; return }
        claudeTesting = true
        claudeTestResult = "Vérification du binaire…"
        Task {
            let version = await Self.claudeVersion(at: path)
            switch version {
            case .failure(let message):
                claudeTestResult = message
                claudeTesting = false
            case .success(let v):
                claudeTestResult = "Binaire OK (\(v)) — vérification de la connexion…"
                let authMessage = await app.checkClaudeAuth()
                claudeTestResult = "Binaire OK (\(v)). \(authMessage)"
                claudeTesting = false
            }
        }
    }

    private static func claudeVersion(at path: String) async -> Result<String, String> {
        await Task.detached { () -> Result<String, String> in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["--version"]
            let out = Pipe(); p.standardOutput = out; p.standardError = out
            do {
                try p.run()
                p.waitUntilExit()
                let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
                let s = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return p.terminationStatus == 0
                    ? .success(s)
                    : .failure("Exit \(p.terminationStatus) : \(s)")
            } catch {
                return .failure("Lancement impossible : \(error.localizedDescription)")
            }
        }.value
    }

    private func reconnectClaude() {
        let binary = URL(fileURLWithPath: settings.claudeBinaryPath)
        // `launch` est `async` : l'AppleScript qui pilote Terminal peut bloquer
        // plusieurs secondes (dialogue d'autorisation Automation, lancement de
        // Terminal), et le faire sur le main actor gèlerait toute l'app.
        Task {
            switch await ClaudeReconnectLauncher.launch(binary: binary) {
            case .launched:
                claudeTestResult = "Terminal ouvert : termine le login, puis clique « Tester »."
            case .copiedToClipboard(let cmd):
                claudeTestResult = "Commande copiée : \(cmd) — lance-la dans un terminal."
            }
        }
    }
```

- [ ] **Step 4: Donner à la vue son état local et son accès à `AppState`**

`SettingsWindow` ne reçoit aujourd'hui que `settings`, `storage` et `indexer` : il lui faut
`AppState` pour lire `claudeAuthStatus` et appeler `checkClaudeAuth()`. En tête de la `struct`
(`Sources/Onyx/Settings/SettingsWindow.swift:6-12`), remplace le bloc de propriétés par :

```swift
struct SettingsWindow: View {
    @ObservedObject var settings: SettingsStore
    /// Nécessaire pour la ligne d'état Claude et la sonde d'authentification —
    /// les deux vivent dans AppState, seul détenteur du ClaudeAuthMonitor.
    @ObservedObject var app: AppState
    let storage: MeetingStorage
    let indexer: MeetingIndexer

    @State private var claudeTestResult: String = ""
    @State private var claudeTesting = false
    @State private var availableCalendars: [EKCalendar] = []
```

Puis, dans `AppState.showSettings()` (`Sources/Onyx/AppState.swift:378-379`), passe `self` :

```swift
        let host = NSHostingController(rootView: SettingsWindow(
            settings: settings, app: self, storage: storage, indexer: indexer))
```

- [ ] **Step 5: Vérification**

Run: `swift build`
Expected: `Build complete`.

---

## Task 9 : Bannière du viewer

**Files:**
- Create: `Sources/Onyx/Viewer/ClaudeAuthBanner.swift`
- Modify: `Sources/Onyx/Viewer/ViewerRootView.swift`

- [ ] **Step 1: Créer la bannière**

Crée `Sources/Onyx/Viewer/ClaudeAuthBanner.swift` :

```swift
import SwiftUI
import RecorderCore

/// Bandeau d'alerte affiché en haut du viewer quand le CLI `claude` est
/// déconnecté, ou pendant le rattrapage des notes perdues.
///
/// Le viewer est l'endroit où l'absence de résumé se remarque — et c'est
/// précisément là qu'il ne se passait rien pendant l'incident du 2026-09-07.
struct ClaudeAuthBanner: View {
    @ObservedObject var app: AppState
    @State private var message: String?

    var body: some View {
        if let progress = app.notesCatchUpProgress {
            row(icon: "arrow.triangle.2.circlepath", tint: .accentColor,
                text: "Rattrapage des résumés — \(progress.done)/\(progress.total)") {
                EmptyView()
            }
        } else if app.claudeAuthStatus.isDisconnected {
            row(icon: "exclamationmark.triangle.fill", tint: .orange,
                text: "Claude déconnecté — les résumés ne sont plus générés "
                    + "(\(app.claudeAuthStatus.detailLabel)).") {
                HStack(spacing: 8) {
                    Button("Se reconnecter…") { reconnect() }
                    Button("Tester") { test() }
                }
            }
        }
    }

    @ViewBuilder
    private func row<Actions: View>(icon: String, tint: Color, text: String,
                                    @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(text).font(.callout)
                Spacer()
                actions()
            }
            if let message {
                HStack {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12))
    }

    private func reconnect() {
        let path = app.settings.claudeBinaryPath
        guard !path.isEmpty else {
            message = "Chemin du binaire Claude non configuré (Réglages → Notes)."
            return
        }
        // `launch` est `async` — voir la note dans la tâche 8 : l'AppleScript
        // peut bloquer plusieurs secondes.
        Task {
            switch await ClaudeReconnectLauncher.launch(binary: URL(fileURLWithPath: path)) {
            case .launched:
                message = "Terminal ouvert : termine le login, puis clique « Tester »."
            case .copiedToClipboard(let cmd):
                message = "Commande copiée : \(cmd)"
            }
        }
    }

    private func test() {
        message = "Vérification…"
        Task { message = await app.checkClaudeAuth() }
    }
}
```

- [ ] **Step 2: Insérer la bannière dans le viewer et lui passer `AppState`**

`ViewerWindowController.init` ne reçoit que `store`, et crée la fenêtre paresseusement dans
`show()`. `AppState` ne peut donc pas passer `self` au constructeur (l'objet n'est pas encore
initialisé), mais peut l'affecter après coup — au moment de `show()`, la propriété est renseignée
depuis longtemps.

Dans `Sources/Onyx/Viewer/ViewerWindowController.swift`, ajoute la propriété à côté de
`onVisibilityChanged` :

```swift
    /// Affecté par `AppState.init` juste après la construction (impossible à
    /// passer au constructeur : `self` n'est pas encore initialisé à ce
    /// moment-là). `weak` parce qu'AppState détient ce contrôleur.
    public weak var app: AppState?
```

Dans `show()`, là où la vue racine est construite, passe-la : `ViewerRootView(store: store, app: app)`.

Dans `Sources/Onyx/Viewer/ViewerRootView.swift`, déclare la propriété **optionnelle** et
n'affiche la bannière que si elle est présente — `ClaudeAuthBanner` exige un `AppState`
non-optionnel, et forcer un déballage ferait planter le viewer pour une bannière :

```swift
struct ViewerRootView: View {
    @ObservedObject var store: ViewerStore
    /// Optionnel : le viewer doit s'afficher même sans AppState (cas
    /// théorique), simplement sans bannière d'alerte.
    let app: AppState?

    var body: some View {
        VStack(spacing: 0) {
            if let app { ClaudeAuthBanner(app: app) }
            HSplitView {
                MeetingsSidebar(store: store)
                MainPanel(
                    store: store,
                    currentDuration: store.currentDurationSeconds,
                    currentSourceListing: store.currentListing
                )
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        .background(.thickMaterial)
    }
}
```

Enfin, à la **fin** de `AppState.init()` (après l'initialisation de toutes les propriétés
stockées) :

```swift
        viewerController.app = self
```

- [ ] **Step 3: Vérification**

Run: `swift build`
Expected: `Build complete`.

---

## Task 10 : Item d'alerte dans le menu de la barre de menus

**Files:**
- Modify: `Sources/Onyx/Menu/MenuBarView.swift`

(La notification macOS a été ajoutée à la tâche 6, avec son appelant.)

- [ ] **Step 1: Ajouter l'item de menu**

Dans `Sources/Onyx/Menu/MenuBarView.swift`, tout au début du `Group { … }`, avant le
`switch app.uiState` :

```swift
            // Visible seulement en cas de problème : rien ne s'affiche quand
            // tout va bien.
            if app.claudeAuthStatus.isDisconnected {
                Button("⚠ Claude déconnecté — se reconnecter…") {
                    app.showSettings()
                }
                Divider()
            }
```

Renvoyer vers les Réglages plutôt que de lancer le Terminal directement : c'est là que se
trouvent le bouton « Tester » et le retour visuel, donc un seul endroit à comprendre.

- [ ] **Step 2: Vérification**

Run: `swift build && swift test`
Expected: `Build complete`, suite de tests verte.

---

## Task 11 : Vérification de bout en bout avec un faux binaire

**Files:** aucun (vérification manuelle)

Cette tâche prouve que la chaîne complète fonctionne sans attendre une vraie déconnexion.

- [ ] **Step 1: Fabriquer un faux `claude` déconnecté**

```bash
mkdir -p /tmp/fake-claude
cat > /tmp/fake-claude/claude <<'EOF'
#!/bin/bash
if [ "$1" = "--version" ]; then echo "9.9.9 (Fake Claude)"; exit 0; fi
cat > /dev/null
echo 'Not logged in · Please run /login'
exit 1
EOF
chmod +x /tmp/fake-claude/claude
```

- [ ] **Step 2: Lancer l'app et pointer les réglages vers le faux binaire**

```bash
scripts/build-app.sh && open dist/Onyx.app
```

Dans Réglages → Notes, mets `/tmp/fake-claude/claude` comme chemin, puis clique « Tester ».

Attendu : « Binaire OK (9.9.9 (Fake Claude)). Non connecté : reconnecte-toi. », le point passe à
l'orange, une notification macOS « Claude déconnecté » apparaît, et la bannière orange s'affiche
en haut du viewer avec le menu de la barre de menus qui affiche l'item d'alerte.

- [ ] **Step 3: Vérifier la persistance**

```bash
cat ~/Library/Application\ Support/Onyx/claude-auth.json
```
Attendu : un JSON contenant `disconnected` et `notLoggedIn`. Quitte puis relance l'app : la
bannière doit être là **immédiatement**, sans attendre une réunion.

- [ ] **Step 4: Vérifier le retour à la normale**

Remets le vrai chemin (`/Users/yvan.betremieux/.nvm/versions/node/v24.13.0/bin/claude`) dans les
réglages, clique « Tester ».

Attendu : « Connecté — Claude a répondu. », point vert, bannière disparue, item de menu disparu.

- [ ] **Step 5: Nettoyer**

```bash
rm -rf /tmp/fake-claude
```

---

## Task 12 : Rattrapage ponctuel des 11 réunions de l'incident

**Files:** aucun (opération de données)

Ces onze réunions portent `nonZeroExit(code: 1, stderr: "")` dans leur `job.json` : le message
d'auth avait été jeté à l'écriture, donc `NotesCatchUp` ne peut pas les reconnaître (voir la
décision assumée dans le spec). Elles se rattrapent une fois, à la main.

- [ ] **Step 1: Vérifier qu'aucun enregistrement n'est en cours**

```bash
ls -t ~/Meetings | head -1 | xargs -I{} sh -c 'python3 -c "import json;print(json.load(open(\"$HOME/Meetings/{}/job.json\"))[\"state\"])"'
```
Attendu : `done`. Si ce n'est pas `done`, **attends** : régénérer maintenant entrerait en
concurrence avec un pipeline en cours.

- [ ] **Step 2: Marquer l'étape `.notes` de ces réunions comme rattrapable**

Le plus simple et le plus sûr : réécrire l'erreur enregistrée pour qu'elle porte un marqueur
reconnu, puis laisser le mécanisme normal faire le travail au prochain lancement.

```bash
python3 - <<'EOF'
import json, pathlib
root = pathlib.Path.home() / "Meetings"
patched = []
for d in sorted(root.glob("2026-09-0[78]_*")):
    jf = d / "job.json"
    try:
        job = json.loads(jf.read_text())
    except Exception:
        continue
    step = job.get("steps", {}).get("notes", {})
    if step.get("status") != "failed":
        continue
    if 'stderr: ""' not in (step.get("error") or ""):
        continue
    # Marqueur reconnu par NotesCatchUp — l'erreur d'origine est conservée
    # entre parenthèses pour ne pas réécrire l'histoire.
    step["error"] = ('authFailed(notLoggedIn) [rattrapage manuel, erreur '
                     'd\'origine: %s]' % step["error"])
    jf.write_text(json.dumps(job, indent=2, sort_keys=True))
    patched.append(d.name)
print(len(patched), "patched:")
print("\n".join(patched))
EOF
```

Attendu : `11 patched:` suivi des slugs du 7 et 8 septembre.

- [ ] **Step 3: Relancer l'app pour déclencher le rattrapage**

```bash
pkill -x Onyx; scripts/build-app.sh && open dist/Onyx.app
```

`bootClaudeAuth()` lit le statut (connecté), appelle `catchUpNotes()`, qui régénère les onze
réunions **séquentiellement**. La bannière affiche « Rattrapage des résumés — n/11 ».

- [ ] **Step 4: Vérifier le résultat**

```bash
for d in $(ls -d ~/Meetings/2026-09-0[78]_*); do
  printf "%s %s\n" "$(basename $d)" "$(test -s $d/notes/brief.md && echo OK || echo MANQUANT)"
done
```
Attendu : `OK` pour les onze. Une réunion encore `MANQUANT` après la fin du rattrapage se
diagnostique dans `job.json` (l'erreur y est désormais complète, stdout inclus — c'était tout
l'objet de la tâche 2).

- [ ] **Step 5: Vérification finale**

Run: `swift test`
Expected: suite complète verte. Pas de commit — le propriétaire du dépôt s'en charge (ou non).

---

## Couverture du spec

| Section du spec | Tâche(s) |
|---|---|
| §1 Classification | 1 |
| §2 Correctif du générateur | 2 |
| §3 État persistant + sonde | 3 |
| §4 Report depuis le pipeline | 4 |
| §5 Sélection des retards | 5 |
| §6 Pilotage du rattrapage | 6 |
| §7 Lanceur de reconnexion | 7 |
| §8 UI — réglages | 8 |
| §8 UI — bannière viewer | 9 |
| §8 UI — notification macOS | 6 |
| §8 UI — item de menu | 10 |
| Gestion des erreurs (tableau) | 1, 3, 6, 7 + vérif. 11 |
| Les 11 réunions de l'incident | 12 |

---

## État d'exécution (2026-09-09)

**Tâches 1 à 10 : terminées et revues** (conformité au spec puis qualité, avec correctifs
appliqués). Suite complète : 466 tests, 0 échec.

Correctifs notables issus des revues, au-delà du plan initial :
- Tâche 3 : `since` glissait à chaque échec répété — la bannière aurait annoncé « déconnecté à
  l'instant » au lieu de « depuis deux jours ». Épinglé au premier échec + test de régression.
- Tâche 3 : le test de persistance du plan supposait un aller-retour `Date` sans perte, or
  `AtomicJSON` encode en ISO-8601 sans fraction de seconde. Test rendu déterministe ; la
  stratégie d'encodage n'a **pas** été touchée (le décodeur casserait sur `meta.json`/`job.json`).
- Tâche 4 : avec plusieurs niveaux de notes, `withThrowingTaskGroup` pouvait laisser un échec
  non-auth masquer un échec d'auth. Groupe désormais vidé entièrement avant décision, l'échec
  d'auth prime. Test prouvé défaillant contre l'ancienne implémentation.
- Tâche 6 : `NotesCatchUp.pendingSlugs` tournait sur le main actor (un `Task {}` d'une classe
  `@MainActor` hérite du main actor) → ~90 lectures synchrones au lancement. Passé en
  `Task.detached`. Garde de réentrance rendue synchrone.
- Tâche 7 : `launch` passé en `async` (l'AppleScript bloquait le main actor plusieurs secondes),
  cas `Outcome.failed` mort supprimé, script `.command` à nom fixe.
- Tâche 8 : `Result<String, String>` du plan ne compile pas (`Failure` doit être `Error`) →
  petite enum locale.
- Tâche 9 : le `@State message` de la bannière survivait à la résolution de l'incident et
  réapparaissait lors d'une déconnexion ultérieure sans rapport → apparié au statut.

**Tâche 12 : prérequis fait.** Les 11 `job.json` du 7-8 septembre portent désormais un marqueur
reconnaissable (erreur d'origine conservée entre crochets ; sauvegardes dans le scratchpad de
session). Vérifié en exécutant le vrai `NotesCatchUp.pendingSlugs` contre `~/Meetings` : il
retourne exactement ces 11 slugs, en ordre chronologique, et aucune des ~90 autres réunions.

**Tâche 12 : faite (2026-09-10).** Les 11 résumés manquants ont été régénérés en pilotant le
vrai `ClaudeNoteGenerator` contre le vrai binaire `claude`, séquentiellement, via un harness de
test temporaire (supprimé depuis) — même chemin de génération que `catchUpNotes`, faute de
pouvoir redéployer l'app. Résultat : 11/11, `notes=done` partout, `brief.md` non vide, aucun
fichier contenant un message d'erreur. Quatre titres ont été détectés et écrits dans `meta.json`
(07_11h02, 07_15h43, 08_11h01, 08_14h46) — l'index SQLite les affichera après un « Rescan
meetings ».

**Déploiement : fait (2026-09-10).** Le certificat « Onyx Local » avait disparu du trousseau
(qui n'était pas verrouillé — le certificat était bien absent). `scripts/setup-cert.sh` a été
corrigé au passage : sous OpenSSL 3, l'export PKCS#12 utilise AES-256/MAC SHA-256 que
`security import` d'Apple ne sait pas vérifier, d'où un « MAC verification failed … (wrong
password?) » trompeur ; le script passe désormais `-legacy` (avec repli SHA1/3DES) et ajoute
l'EKU `codeSigning`. Nouveau certificat créé, `codesign` vérifié sur un binaire jetable, app
construite, signée (`valid on disk`, `satisfies its Designated Requirement`), ancienne version
sauvegardée dans le scratchpad de session, puis installée dans `/Applications/Onyx.app` et
relancée. Présence des nouvelles chaînes (`onyx.claudeAuthDidChange`, `claude-auth.json`,
`onyx.claude.disconnected`) vérifiée dans le binaire déployé et absente de la sauvegarde.

**Conséquence à surveiller :** le nouveau certificat a une empreinte différente, donc macOS
traite Onyx comme une app neuve et réinitialise les autorisations TCC (micro, calendrier,
enregistrement d'écran). À revérifier dans Réglages Système avant la réunion suivante.

**Reste : tâche 11.** La vérification visuelle (bannière, item de menu, notification, avec un
faux binaire `claude` déconnecté) demande des clics dans l'app — la recette est décrite plus
haut dans la tâche 11. Le chemin passif se vérifiera tout seul : à la prochaine génération de
notes réussie, `~/Library/Application Support/Onyx/claude-auth.json` doit apparaître avec un
statut `connected`.
