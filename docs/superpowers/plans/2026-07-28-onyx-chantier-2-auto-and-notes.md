# Onyx Chantier 2 — Auto-trigger + Claude Code Notes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Note on commits:** The user handles git commits themselves. Do NOT run `git commit` / `git add` / `git push` at the end of tasks. Stage-and-review is fine; the user will commit at their own cadence.

**Goal:** Ajouter à Onyx l'auto-trigger d'enregistrement (calendar EventKit + détection Meet/Slack Huddle) et la génération de notes via `claude -p` en 3 niveaux (brief / synthese / detaillee).

**Architecture:** Cinq nouveaux composants dans `RecorderCore` (`CalendarWatcher`, deux détecteurs + `DetectionCoordinator`, `AutoTriggerOrchestrator`, `ClaudeNoteGenerator`) et un step `.notes` ajouté au pipeline existant. UI/onboarding étendus dans le target `Onyx`. Communication par `AsyncStream` internes + disque (comme le Chantier 1). Chaque composant est isolé, mockable via un protocol.

**Tech Stack:** Swift 5.9 / macOS 13+, EventKit, AppleScript-ObjC (JXA), NSWorkspace + CGWindowList, UserNotifications, Foundation `Process` (pour spawn `claude`).

**Spec de référence :** `docs/superpowers/specs/2026-07-28-onyx-chantier-2-auto-and-notes-design.md`.

---

## File Structure

Nouveaux fichiers dans `Sources/RecorderCore/`:

```
Calendar/
  CalendarWatcher.swift        (poll EventKit, émet MatchedEvent)
  MatchedEvent.swift           (struct + Codable)

Detection/
  MeetingAppDetector.swift     (protocol + enums)
  MeetDetector.swift           (JXA polling)
  SlackHuddleDetector.swift    (CGWindowList polling)
  DetectionCoordinator.swift   (merge + debounce)

Autotrigger/
  AutoTriggerOrchestrator.swift (state machine)

Notes/
  NoteLevel.swift              (enum public)
  NotePromptTemplates.swift    (constants)
  ClaudeNoteGenerator.swift    (Process wrapper)
```

Nouveaux fichiers dans `Sources/Onyx/`:

```
Notifications/
  OptOutNotificationCenter.swift  (UN wrapper avec action Stop)

Onboarding/
  CalendarPermissionView.swift
  CalendarPickerView.swift
  BrowserAutomationView.swift
  ClaudeBinaryView.swift
```

Modifications existantes ciblées :

- `Sources/RecorderCore/Storage/MeetingMetadata.swift` — nouveaux champs Codable.
- `Sources/RecorderCore/Storage/JobState.swift` — nouveau case `.notes` dans `JobStep`.
- `Sources/RecorderCore/Support/MeetingPaths.swift` — accesseurs `notesDir`, `notesFile(level:)`.
- `Sources/RecorderCore/Recorder/Recorder.swift` — méthode `cancel()`.
- `Sources/RecorderCore/Pipeline/Pipeline.swift` — nouveau step `.notes`.
- `Sources/RecorderCore/Index/IndexSchema.swift` + `MeetingIndexer.swift` — colonne `title`, méthode `recentMeetings(limit:)`.
- `Sources/Onyx/Settings/SettingsStore.swift` — nouveaux champs.
- `Sources/Onyx/Settings/SettingsWindow.swift` — nouveaux tabs.
- `Sources/Onyx/AppState.swift` — wiring de l'orchestrator.
- `Sources/Onyx/Menu/MenuBarView.swift` — sous-menu "Recent Meetings".
- `Sources/Onyx/Onboarding/OnboardingWindow.swift` — nouvelles étapes.

Nouveaux fichiers de tests :

```
Tests/RecorderCoreTests/
  NotePromptTemplatesTests.swift
  ClaudeNoteGeneratorTests.swift
  MeetingMetadataMigrationTests.swift
  JobStateNotesStepTests.swift
  MeetingPathsNotesTests.swift
  RecorderCancelTests.swift
  DetectionCoordinatorTests.swift
  CalendarMatchRulesTests.swift
  AutoTriggerOrchestratorTests.swift
  MeetingIndexerRecentTests.swift
```

---

## Task 1: `NoteLevel` enum + `MeetingPaths` notes accessors

**Files:**
- Create: `Sources/RecorderCore/Notes/NoteLevel.swift`
- Modify: `Sources/RecorderCore/Support/MeetingPaths.swift`
- Test: `Tests/RecorderCoreTests/MeetingPathsNotesTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/RecorderCoreTests/MeetingPathsNotesTests.swift
import XCTest
@testable import RecorderCore

final class MeetingPathsNotesTests: XCTestCase {
    func testNotesDirIsNotesSubfolder() {
        let root = URL(fileURLWithPath: "/tmp/onyx-test")
        let paths = MeetingPaths(root: root, slug: "2026-07-28_10h00")
        XCTAssertEqual(paths.notesDir.lastPathComponent, "notes")
        XCTAssertTrue(paths.notesDir.path.hasSuffix("/2026-07-28_10h00/notes"))
    }

    func testNotesFilePerLevel() {
        let root = URL(fileURLWithPath: "/tmp/onyx-test")
        let paths = MeetingPaths(root: root, slug: "s")
        XCTAssertEqual(paths.notesFile(.brief).lastPathComponent, "brief.md")
        XCTAssertEqual(paths.notesFile(.synthese).lastPathComponent, "synthese.md")
        XCTAssertEqual(paths.notesFile(.detaillee).lastPathComponent, "detaillee.md")
    }

    func testNoteLevelRawValues() {
        XCTAssertEqual(NoteLevel.brief.rawValue, "brief")
        XCTAssertEqual(NoteLevel.synthese.rawValue, "synthese")
        XCTAssertEqual(NoteLevel.detaillee.rawValue, "detaillee")
    }

    func testNoteLevelAllCases() {
        XCTAssertEqual(NoteLevel.allCases.count, 3)
    }
}
```

- [ ] **Step 2: Run test — expect compile failure (`NoteLevel` unknown)**

Run: `swift test --filter MeetingPathsNotesTests`
Expected: FAIL with "cannot find 'NoteLevel' in scope".

- [ ] **Step 3: Create `NoteLevel.swift`**

```swift
// Sources/RecorderCore/Notes/NoteLevel.swift
import Foundation

public enum NoteLevel: String, Codable, CaseIterable, Sendable {
    case brief
    case synthese
    case detaillee
}
```

- [ ] **Step 4: Extend `MeetingPaths.swift`**

Ouvre `Sources/RecorderCore/Support/MeetingPaths.swift` et ajoute à la fin du fichier :

```swift
public extension MeetingPaths {
    var notesDir: URL { root.appendingPathComponent("notes", isDirectory: true) }
    func notesFile(_ level: NoteLevel) -> URL {
        notesDir.appendingPathComponent("\(level.rawValue).md")
    }
}
```

- [ ] **Step 5: Run test — expect pass**

Run: `swift test --filter MeetingPathsNotesTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Stop (do not commit — user commits themselves)**

---

## Task 2: `MeetingMetadata` évolution (backwards compatible)

**Files:**
- Modify: `Sources/RecorderCore/Storage/MeetingMetadata.swift`
- Test: `Tests/RecorderCoreTests/MeetingMetadataMigrationTests.swift`

**Contexte :** ajouter `title?`, `source`, `calendarEventId?`, `detectedApp?`, `detectedCode?` sans casser les meetings Chantier 1 déjà sur disque (leur `meta.json` n'a pas ces champs).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/RecorderCoreTests/MeetingMetadataMigrationTests.swift
import XCTest
@testable import RecorderCore

final class MeetingMetadataMigrationTests: XCTestCase {
    func testDecodesChantier1JSONWithMissingFields() throws {
        // JSON as written by Chantier 1 (no title/source/etc.)
        let json = """
        {"slug":"2026-07-01_10h00","startedAt":"2026-07-01T08:00:00Z"}
        """.data(using: .utf8)!
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let meta = try dec.decode(MeetingMetadata.self, from: json)
        XCTAssertEqual(meta.slug, "2026-07-01_10h00")
        XCTAssertNil(meta.title)
        XCTAssertEqual(meta.source, .manual)
        XCTAssertNil(meta.calendarEventId)
        XCTAssertNil(meta.detectedApp)
        XCTAssertNil(meta.detectedCode)
    }

    func testEncodesAllFieldsWhenPresent() throws {
        let meta = MeetingMetadata(
            slug: "s",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            stoppedAt: nil,
            title: "Design review",
            source: .calendar,
            calendarEventId: "EK-12345",
            detectedApp: "meet",
            detectedCode: "abc-defg-hij"
        )
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(meta)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["title"] as? String, "Design review")
        XCTAssertEqual(dict["source"] as? String, "calendar")
        XCTAssertEqual(dict["calendarEventId"] as? String, "EK-12345")
        XCTAssertEqual(dict["detectedApp"] as? String, "meet")
        XCTAssertEqual(dict["detectedCode"] as? String, "abc-defg-hij")
    }

    func testRoundTripAllFields() throws {
        let original = MeetingMetadata(
            slug: "s",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            stoppedAt: Date(timeIntervalSince1970: 1_700_003_600),
            title: "T",
            source: .detected,
            calendarEventId: nil,
            detectedApp: "slack_huddle",
            detectedCode: "42"
        )
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let data = try enc.encode(original)
        let round = try dec.decode(MeetingMetadata.self, from: data)
        XCTAssertEqual(round, original)
    }
}
```

- [ ] **Step 2: Run test — expect compile failure (new fields)**

Run: `swift test --filter MeetingMetadataMigrationTests`
Expected: FAIL (missing initializer args).

- [ ] **Step 3: Extend `MeetingMetadata.swift`**

Ouvre `Sources/RecorderCore/Storage/MeetingMetadata.swift`. Repère le `public struct MeetingMetadata: Codable, Equatable { ... }`. Remplace-le par :

```swift
public struct MeetingMetadata: Codable, Equatable {
    public let slug: String
    public let startedAt: Date
    public var stoppedAt: Date?
    // Chantier 2 additions:
    public var title: String?
    public var source: Source
    public var calendarEventId: String?
    public var detectedApp: String?
    public var detectedCode: String?

    public enum Source: String, Codable, Equatable, Sendable {
        case manual, calendar, detected
    }

    public init(slug: String,
                startedAt: Date,
                stoppedAt: Date? = nil,
                title: String? = nil,
                source: Source = .manual,
                calendarEventId: String? = nil,
                detectedApp: String? = nil,
                detectedCode: String? = nil) {
        self.slug = slug
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
        self.title = title
        self.source = source
        self.calendarEventId = calendarEventId
        self.detectedApp = detectedApp
        self.detectedCode = detectedCode
    }

    private enum CodingKeys: String, CodingKey {
        case slug, startedAt, stoppedAt, title, source,
             calendarEventId, detectedApp, detectedCode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        stoppedAt = try c.decodeIfPresent(Date.self, forKey: .stoppedAt)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .manual
        calendarEventId = try c.decodeIfPresent(String.self, forKey: .calendarEventId)
        detectedApp = try c.decodeIfPresent(String.self, forKey: .detectedApp)
        detectedCode = try c.decodeIfPresent(String.self, forKey: .detectedCode)
    }
}
```

- [ ] **Step 4: Run test — expect pass**

Run: `swift test --filter MeetingMetadataMigrationTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Sanity check — full test suite doesn't regress**

Run: `swift test`
Expected: all Chantier 1 tests still pass (20 tests) + 3 new ones. If any Chantier 1 test that constructs `MeetingMetadata` fails, update it to use the new positional args (they have defaults, most call sites are fine).

- [ ] **Step 6: Stop (do not commit).**

---

## Task 3: `JobState` — add `.notes` step + `.generatingNotes` state

**Files:**
- Modify: `Sources/RecorderCore/Storage/JobState.swift`
- Test: `Tests/RecorderCoreTests/JobStateNotesStepTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/RecorderCoreTests/JobStateNotesStepTests.swift
import XCTest
@testable import RecorderCore

final class JobStateNotesStepTests: XCTestCase {
    func testFreshHasNotesStepPending() {
        let s = JobState.fresh()
        XCTAssertEqual(s.stepStatus(.notes), .pending)
    }

    func testAllCasesIncludesNotesLast() {
        // .notes must appear after .cleanup so the pipeline runs it last.
        let order = JobStep.allCases
        let cleanupIdx = order.firstIndex(of: .cleanup)!
        let notesIdx = order.firstIndex(of: .notes)!
        XCTAssertGreaterThan(notesIdx, cleanupIdx)
    }

    func testDecodesChantier1JobJSONWithMissingNotesStep() throws {
        // Chantier 1 job.json has all six existing steps but not .notes.
        let json = """
        {
          "state":"done",
          "steps":{
            "normalize":{"status":"done"},
            "whisper_mic":{"status":"done"},
            "whisper_system":{"status":"done"},
            "diarize":{"status":"done"},
            "merge":{"status":"done"},
            "render":{"status":"done"},
            "cleanup":{"status":"done"}
          }
        }
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(JobState.self, from: json)
        XCTAssertEqual(s.stepStatus(.notes), .pending,
                       "missing .notes must default to .pending")
    }

    func testGeneratingNotesOverallState() {
        var s = JobState.fresh()
        s.state = .generatingNotes
        XCTAssertEqual(s.state, .generatingNotes)
    }
}
```

- [ ] **Step 2: Run — expect FAIL (`.notes` and `.generatingNotes` unknown)**

Run: `swift test --filter JobStateNotesStepTests`

- [ ] **Step 3: Update `JobState.swift`**

Ouvre `Sources/RecorderCore/Storage/JobState.swift`. Ajoute `notes` à la fin de `JobStep`, et `generatingNotes` à `JobOverallState`. Les deux enums doivent rester Codable :

```swift
public enum JobStep: String, CaseIterable, Codable {
    case normalize
    case whisperMic = "whisper_mic"
    case whisperSystem = "whisper_system"
    case diarize
    case merge
    case render
    case cleanup
    case notes            // Chantier 2
}

public enum JobOverallState: String, Codable {
    case recording, normalizing, transcribing, diarizing,
         merging, rendering, cleanup, generatingNotes, done, failed
}
```

Le décodeur existant (`init(from:)`) itère déjà sur `JobStep.allCases` pour remplir les manquants en `.pending` (cf. lignes 81-82 du fichier existant) — le nouveau case sera donc naturellement défaulté.

- [ ] **Step 4: Run tests — expect PASS**

Run: `swift test --filter JobStateNotesStepTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Full suite regression check**

Run: `swift test`
Expected: all existing tests pass.

- [ ] **Step 6: Stop (do not commit).**

---

## Task 4: `Recorder.cancel()` method

**Contexte :** l'auto-trigger déclenche une notif "Recording X — [Stop]". Un clic dans les ≤30 sec doit **annuler** l'enregistrement (delete du dossier meeting, pas de pipeline). Au-delà, c'est un stop normal. Il faut donc une méthode `cancel()` distincte de `stop()`.

**Files:**
- Modify: `Sources/RecorderCore/Recorder/Recorder.swift`
- Test: `Tests/RecorderCoreTests/RecorderCancelTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/RecorderCoreTests/RecorderCancelTests.swift
import XCTest
@testable import RecorderCore

@available(macOS 13.0, *)
final class RecorderCancelTests: XCTestCase {
    func testCancelDeletesMeetingFolderAndReturnsToIdle() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let storage = MeetingStorage(root: tmp)
        let recorder = Recorder(storage: storage)

        // Simulate start (start() may fail without mic access in CI — we build
        // the meeting folder manually using MeetingStorage instead).
        let paths = try storage.createMeeting(startedAt: Date())
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.root.path))

        try recorder.cancel(paths: paths)

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.root.path),
                       "cancel() must delete the meeting folder")
    }
}
```

- [ ] **Step 2: Run — expect FAIL (`cancel(paths:)` unknown)**

Run: `swift test --filter RecorderCancelTests`

- [ ] **Step 3: Add `cancel(paths:)` to `Recorder.swift`**

Ouvre `Sources/RecorderCore/Recorder/Recorder.swift`. À l'intérieur de `public final class Recorder`, ajoute :

```swift
/// Cancels an ongoing recording — stops the mic/system capture without running
/// the pipeline, and deletes the meeting folder entirely. Used by the auto-trigger
/// opt-out flow within ~30s of start.
public func cancel(paths: MeetingPaths) throws {
    flushTimer?.invalidate()
    flushTimer = nil
    // Best-effort stop of underlying capture — errors ignored on cancel path.
    try? mic.stop()
    try? system.stop()
    try FileManager.default.removeItem(at: paths.root)
}
```

Si les méthodes `stop()` sur `mic` / `system` ne sont pas `throws`, retire le `try?`. Aligne-toi sur les signatures existantes dans `MicRecorder.swift` et `SystemAudioRecorder.swift`.

- [ ] **Step 4: Run — expect PASS**

Run: `swift test --filter RecorderCancelTests`
Expected: PASS.

- [ ] **Step 5: Stop (do not commit).**

---

## Task 5: `NotePromptTemplates` (constants)

**Files:**
- Create: `Sources/RecorderCore/Notes/NotePromptTemplates.swift`
- Test: `Tests/RecorderCoreTests/NotePromptTemplatesTests.swift`

**Contexte :** trois prompts constants hardcodés (spec §7.3). Chaque prompt a une structure commune + une section d'instructions spécifique. Le contenu du transcript est injecté via un placeholder `{{TRANSCRIPT}}`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/RecorderCoreTests/NotePromptTemplatesTests.swift
import XCTest
@testable import RecorderCore

final class NotePromptTemplatesTests: XCTestCase {
    func testHasOnePromptPerLevel() {
        for level in NoteLevel.allCases {
            let prompt = NotePromptTemplates.prompt(for: level, transcript: "T")
            XCTAssertFalse(prompt.isEmpty, "prompt missing for \(level)")
        }
    }

    func testTranscriptPlaceholderIsReplaced() {
        let p = NotePromptTemplates.prompt(for: .synthese,
                                           transcript: "MOI: hello world")
        XCTAssertTrue(p.contains("MOI: hello world"),
                      "transcript must be inlined")
        XCTAssertFalse(p.contains("{{TRANSCRIPT}}"),
                       "placeholder must be replaced")
    }

    func testPromptsAreDistinctPerLevel() {
        let b = NotePromptTemplates.prompt(for: .brief, transcript: "X")
        let s = NotePromptTemplates.prompt(for: .synthese, transcript: "X")
        let d = NotePromptTemplates.prompt(for: .detaillee, transcript: "X")
        XCTAssertNotEqual(b, s)
        XCTAssertNotEqual(s, d)
        XCTAssertNotEqual(b, d)
    }

    func testPromptMentionsSpeakerConvention() {
        // Every prompt must inform Claude about MOI / SPEAKER_N convention.
        for level in NoteLevel.allCases {
            let p = NotePromptTemplates.prompt(for: level, transcript: "")
            XCTAssertTrue(p.contains("MOI"), "\(level) prompt missing MOI marker")
            XCTAssertTrue(p.contains("SPEAKER"), "\(level) prompt missing SPEAKER marker")
        }
    }
}
```

- [ ] **Step 2: Run — expect FAIL (`NotePromptTemplates` unknown)**

Run: `swift test --filter NotePromptTemplatesTests`

- [ ] **Step 3: Create `NotePromptTemplates.swift`**

```swift
// Sources/RecorderCore/Notes/NotePromptTemplates.swift
import Foundation

public enum NotePromptTemplates {
    /// Returns the full prompt (system + instructions + transcript) for the given
    /// level, with `{{TRANSCRIPT}}` already replaced by the provided transcript.
    public static func prompt(for level: NoteLevel, transcript: String) -> String {
        let instructions: String
        switch level {
        case .brief:
            instructions = """
            Niveau demandé : BRIEF.
            3 à 5 bullets. TL;DR en une phrase, décisions prises, action items \
            (avec owner si mentionné). Zéro contexte, zéro détail. ~150 mots max.
            """
        case .synthese:
            instructions = """
            Niveau demandé : SYNTHESE.
            Sections en Markdown :
            ## Contexte (2-3 phrases)
            ## Décisions
            ## Points clés discutés
            ## Action items (owner + deadline si mentionnés)
            ## Questions ouvertes

            ~500 mots. Ton neutre. Pas de verbatim, tu reformules.
            """
        case .detaillee:
            instructions = """
            Niveau demandé : DETAILLE.
            Synthèse structurée (mêmes sections que le niveau SYNTHESE) suivie \
            d'une section :
            ## Détail par thème
            avec sous-sections thématiques. Utilise des quotes verbatim \
            (entre guillemets) pour les points-clés à citer. Ajoute des \
            timestamps `[MM:SS]` pour les moments notables.

            ~1500-2000 mots.
            """
        }

        return """
        Tu es un preneur de notes de meeting. Tu reçois la transcription d'un \
        meeting avec speakers identifiés :
        - "MOI" = moi-même (l'utilisateur d'Onyx)
        - "SPEAKER_N" = autres intervenants (N = 0, 1, 2, ...)

        Génère les notes en français, format Markdown.

        \(instructions)

        Transcript :
        \(transcript)
        """
    }
}
```

- [ ] **Step 4: Run — expect PASS (4 tests)**

Run: `swift test --filter NotePromptTemplatesTests`

- [ ] **Step 5: Stop (do not commit).**

---

## Task 6: `ClaudeNoteGenerator` (Process wrapper)

**Files:**
- Create: `Sources/RecorderCore/Notes/ClaudeNoteGenerator.swift`
- Test: `Tests/RecorderCoreTests/ClaudeNoteGeneratorTests.swift`

**Contexte :** wrapper autour de `Process` qui spawn `<binary> -p --output-format text`, envoie le prompt sur stdin, capture stdout, écrit `notes/<level>.md`. Testable en substituant `<binary>` par un script bash qui echo un output prévisible.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/RecorderCoreTests/ClaudeNoteGeneratorTests.swift
import XCTest
@testable import RecorderCore

final class ClaudeNoteGeneratorTests: XCTestCase {
    /// Creates a temporary bash script that reads stdin and echoes a marker
    /// wrapping it — makes it easy to assert the input was passed through.
    private func makeFakeBinary() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-fake-claude-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("claude")
        let body = """
        #!/bin/bash
        # Ignore all args, echo a header, then everything from stdin, then a footer.
        echo "# Test note"
        echo
        cat
        echo
        echo "END"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        return script
    }

    private func makeMeetingWithTranscript() throws -> MeetingPaths {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-notegen-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        let storage = MeetingStorage(root: root)
        let paths = try storage.createMeeting(startedAt: Date())
        try "MOI: hello\nSPEAKER_00: hi there".write(to: paths.transcriptMd,
                                                     atomically: true,
                                                     encoding: .utf8)
        return paths
    }

    func testGeneratesNotesFile() async throws {
        let binary = try makeFakeBinary()
        defer { try? FileManager.default.removeItem(at: binary.deletingLastPathComponent()) }
        let paths = try makeMeetingWithTranscript()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let gen = ClaudeNoteGenerator()
        try await gen.generate(paths: paths, level: .brief, binary: binary)

        let target = paths.notesFile(.brief)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        let out = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(out.contains("# Test note"))
        XCTAssertTrue(out.contains("hello"), "transcript must reach stdin")
        XCTAssertTrue(out.contains("END"))
    }

    func testCreatesNotesDirIfMissing() async throws {
        let binary = try makeFakeBinary()
        defer { try? FileManager.default.removeItem(at: binary.deletingLastPathComponent()) }
        let paths = try makeMeetingWithTranscript()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.notesDir.path))
        let gen = ClaudeNoteGenerator()
        try await gen.generate(paths: paths, level: .synthese, binary: binary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.notesDir.path))
    }

    func testTimesOutOnHangingBinary() async throws {
        // Fake binary that sleeps way past our timeout.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-hang-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("claude")
        try "#!/bin/bash\nsleep 30".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)

        let paths = try makeMeetingWithTranscript()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let gen = ClaudeNoteGenerator(timeoutSeconds: 1)
        do {
            try await gen.generate(paths: paths, level: .brief, binary: script)
            XCTFail("expected timeout error")
        } catch ClaudeNoteGenerator.GenerationError.timedOut {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testNonZeroExitRaisesError() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-fail-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("claude")
        try "#!/bin/bash\necho boom >&2\nexit 3".write(to: script, atomically: true,
                                                       encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)

        let paths = try makeMeetingWithTranscript()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let gen = ClaudeNoteGenerator()
        do {
            try await gen.generate(paths: paths, level: .brief, binary: script)
            XCTFail("expected error")
        } catch ClaudeNoteGenerator.GenerationError.nonZeroExit(let code, _) {
            XCTAssertEqual(code, 3)
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }
}
```

- [ ] **Step 2: Run — expect FAIL (`ClaudeNoteGenerator` unknown)**

Run: `swift test --filter ClaudeNoteGeneratorTests`

- [ ] **Step 3: Create `ClaudeNoteGenerator.swift`**

```swift
// Sources/RecorderCore/Notes/ClaudeNoteGenerator.swift
import Foundation

/// Spawns `claude -p` as a subprocess to generate meeting notes from the
/// transcript. The prompt (built by `NotePromptTemplates`) is fed via stdin;
/// stdout is captured and written to `paths.notesFile(level)`.
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

    /// Reads `paths.transcriptMd`, spawns `binary -p --output-format text`,
    /// pipes the composed prompt through stdin, writes stdout to
    /// `paths.notesFile(level)`. Overwrites the target file if present.
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

    // MARK: - Process plumbing

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

        // Write stdin then close it — allow the child to see EOF.
        if let data = stdin.data(using: .utf8) {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        }
        try stdinPipe.fileHandleForWriting.close()

        // Wait with timeout.
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while proc.isRunning {
            if Date() >= deadline {
                proc.terminate()
                // Give it a beat to die, then force kill if still hanging.
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
```

- [ ] **Step 4: Run — expect PASS (4 tests)**

Run: `swift test --filter ClaudeNoteGeneratorTests`

Ces tests peuvent être un peu lents (~1-2s cumulés à cause du sleep du timeout test).

- [ ] **Step 5: Stop (do not commit).**

---

## Task 7: Intégration du step `.notes` dans le Pipeline

**Files:**
- Modify: `Sources/RecorderCore/Pipeline/Pipeline.swift`
- Test: `Tests/RecorderCoreTests/PipelineTests.swift` (append)

**Contexte :** ajouter un step `.notes` après `.cleanup`. Le step est **conditionnel** : il ne s'exécute que si un `ClaudeNoteGenerator` + binary path + level sont fournis. Sinon skip (utile quand le binary n'est pas résolu, ou en tests).

L'idempotence naturelle du Pipeline (skip si step `.done`) + un check "notes file already exists" empêche la re-génération inutile.

Un échec du step `.notes` **ne fait pas basculer** `job.state` en `failed` (spec §7 "échec du step") : le transcript reste utilisable, seul le step `.notes` est marqué `failed` en interne.

- [ ] **Step 1: Extend Pipeline API for notes injection**

Ouvre `Sources/RecorderCore/Pipeline/Pipeline.swift`. En haut du fichier, sous les protocols existants, ajoute :

```swift
/// Config for the optional `.notes` step. If `binary` is nil the step is a no-op.
public struct NoteGenerationConfig: Sendable {
    public let generator: ClaudeNoteGenerator
    public let binary: URL?
    public let level: NoteLevel
    public init(generator: ClaudeNoteGenerator = ClaudeNoteGenerator(),
                binary: URL?,
                level: NoteLevel) {
        self.generator = generator
        self.binary = binary
        self.level = level
    }
}
```

Puis étends `Pipeline` :

```swift
public actor Pipeline {
    private let storage: MeetingStorage
    private let whisper: any WhisperTranscribing
    private let diarizer: any Diarizing
    private let notes: NoteGenerationConfig?      // NEW

    public init(storage: MeetingStorage,
                whisper: any WhisperTranscribing = WhisperTranscriber(),
                diarizer: any Diarizing = Diarizer(),
                notes: NoteGenerationConfig? = nil) {
        self.storage = storage
        self.whisper = whisper
        self.diarizer = diarizer
        self.notes = notes
    }
    // ... existing methods unchanged ...
}
```

Puis, à la fin de `run(paths:)`, **avant** le `job.state = .done` block, ajoute le nouveau step :

```swift
try await runStepSoft(.notes, paths: paths, overall: .generatingNotes) {
    guard let cfg = self.notes,
          let binary = cfg.binary else { return }
    // Skip if already generated for this level.
    if FileManager.default.fileExists(atPath: paths.notesFile(cfg.level).path) { return }
    try await cfg.generator.generate(paths: paths, level: cfg.level, binary: binary)
}

var job = try storage.loadJob(paths)
job.state = .done
try storage.saveJob(job, at: paths)
```

Le `runStepSoft` est une variante **non-fatale** de `runStep` : si le body throw, on marque le step `failed` mais **on ne propage pas l'erreur**. Ajoute-la à la classe :

```swift
private func runStepSoft(_ step: JobStep, paths: MeetingPaths,
                         overall: JobOverallState,
                         body: @Sendable () async throws -> Void) async {
    do {
        var job = try storage.loadJob(paths)
        if job.stepStatus(step) == .done {
            Log.pipeline.info("Skip \(step.rawValue) — already done for \(paths.slug)")
            return
        }
        job.state = overall
        job.markStarted(step)
        try storage.saveJob(job, at: paths)
        try await body()
        var updated = try storage.loadJob(paths)
        updated.markDone(step)
        try storage.saveJob(updated, at: paths)
    } catch {
        Log.pipeline.error("Soft step \(step.rawValue) failed: \(String(describing: error))")
        if var job = try? storage.loadJob(paths) {
            // Mark step failed but DO NOT flip overall state to .failed —
            // the transcript is still usable.
            job.markFailed(step, error: String(describing: error))
            job.state = .done   // override the flip done by markFailed
            job.error = nil
            try? storage.saveJob(job, at: paths)
        }
    }
}
```

Note : `job.markFailed` (Chantier 1) flip `state = .failed`. Le soft override ci-dessus le remet à `.done` puisque, pour `.notes`, l'échec du step ne doit pas contaminer l'état global.

- [ ] **Step 2: Add a test for notes step success + skip**

Append to `Tests/RecorderCoreTests/PipelineTests.swift`:

```swift
    func testPipelineRunsNotesStepWhenConfigured() async throws {
        let (paths, storage) = try Self.makeMeetingWithArtifacts()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        // Fake binary that echoes a fixed note.
        let bin = try Self.makeFakeClaude(output: "# fake note\nok")
        defer { try? FileManager.default.removeItem(at: bin.deletingLastPathComponent()) }

        let cfg = NoteGenerationConfig(binary: bin, level: .brief)
        let pipeline = Pipeline(storage: storage,
                                whisper: Self.stubWhisper,
                                diarizer: Self.stubDiar,
                                notes: cfg)
        try await pipeline.run(paths: paths)

        let target = paths.notesFile(.brief)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        let content = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(content.contains("# fake note"))

        let job = try storage.loadJob(paths)
        XCTAssertEqual(job.state, .done)
        XCTAssertEqual(job.stepStatus(.notes), .done)
    }

    func testPipelineTolerantToNotesFailure() async throws {
        let (paths, storage) = try Self.makeMeetingWithArtifacts()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        // Fake binary that always fails.
        let bin = try Self.makeFakeClaude(output: "", exitCode: 7)
        defer { try? FileManager.default.removeItem(at: bin.deletingLastPathComponent()) }

        let cfg = NoteGenerationConfig(binary: bin, level: .brief)
        let pipeline = Pipeline(storage: storage,
                                whisper: Self.stubWhisper,
                                diarizer: Self.stubDiar,
                                notes: cfg)
        try await pipeline.run(paths: paths)

        // Job overall must stay .done (transcript still usable).
        let job = try storage.loadJob(paths)
        XCTAssertEqual(job.state, .done)
        XCTAssertEqual(job.stepStatus(.notes), .failed)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.notesFile(.brief).path))
    }
```

Et ajoute les helpers en bas du fichier de test (si pas déjà présents) :

```swift
    // Test helpers used by notes tests.
    static func makeMeetingWithArtifacts() throws -> (MeetingPaths, MeetingStorage) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-pipe-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = MeetingStorage(root: root)
        let paths = try storage.createMeeting(startedAt: Date())
        // Provide the two normalized wav files the pipeline expects.
        try Data().write(to: paths.micNormalized)
        try Data().write(to: paths.systemNormalized)
        // And a mic.wav / system.wav so the pipeline sees something to normalize.
        try Data().write(to: paths.micWav)
        try Data().write(to: paths.systemWav)
        // Pre-write a transcript so notes step has something to read.
        try FileManager.default.createDirectory(at: paths.root.appendingPathComponent("transcripts"),
                                                withIntermediateDirectories: true)
        try "content".data(using: .utf8)!.write(to: paths.transcriptMd)
        return (paths, storage)
    }

    static let stubWhisper: any WhisperTranscribing = _StubWhisper()
    static let stubDiar: any Diarizing = _StubDiar()

    static func makeFakeClaude(output: String, exitCode: Int = 0) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-fclaude-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("claude")
        let escaped = output.replacingOccurrences(of: "'", with: "'\\''")
        let body = "#!/bin/bash\ncat > /dev/null\nprintf '%s' '\(escaped)'\nexit \(exitCode)\n"
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        return script
    }
}

private struct _StubWhisper: WhisperTranscribing {
    func transcribe(wavPath: URL, to jsonPath: URL) async throws {
        try "[]".data(using: .utf8)!.write(to: jsonPath)
    }
}

private struct _StubDiar: Diarizing {
    func diarize(wavPath: URL, to jsonPath: URL) throws {
        try "[]".data(using: .utf8)!.write(to: jsonPath)
    }
}
```

**Attention** : les tests existants `PipelineTests` peuvent utiliser des helpers similaires — évite les doublons de types. Si `_StubWhisper` / `_StubDiar` existent déjà dans le fichier, réutilise-les.

- [ ] **Step 3: Run — expect PASS**

Run: `swift test --filter PipelineTests`
Expected: tous les tests Chantier 1 + les 2 nouveaux PASS.

- [ ] **Step 4: Full suite**

Run: `swift test`
Expected: aucun test cassé.

- [ ] **Step 5: Stop (do not commit).**

---

## Task 8: `SettingsStore` — nouveaux champs

**Files:**
- Modify: `Sources/Onyx/Settings/SettingsStore.swift`

**Contexte :** ajouter les 7 nouveaux champs (spec §7.4) au `SettingsStore` existant. Structure exacte du store existant à lire d'abord — il utilise probablement `@AppStorage` / `UserDefaults` ou un fichier JSON. Aligne-toi sur le pattern déjà en place.

- [ ] **Step 1: Read existing store**

Ouvre `Sources/Onyx/Settings/SettingsStore.swift`. Note la façon dont `meetingsFolder` est persisté (UserDefaults key, JSON file, etc.). Les nouveaux champs suivent le même pattern.

- [ ] **Step 2: Add fields**

Ajoute (dans l'ordre logique du fichier) :

```swift
// Chantier 2 additions.
@AppStorage("autoTriggerEnabled") public var autoTriggerEnabled: Bool = true
@AppStorage("autoNotesEnabled") public var autoNotesEnabled: Bool = true
@AppStorage("detectionMeetEnabled") public var detectionMeetEnabled: Bool = true
@AppStorage("detectionHuddleEnabled") public var detectionHuddleEnabled: Bool = true
@AppStorage("claudeBinaryPath") public var claudeBinaryPath: String = ""
@AppStorage("defaultNoteLevelRaw") private var defaultNoteLevelRaw: String = NoteLevel.synthese.rawValue

public var defaultNoteLevel: NoteLevel {
    get { NoteLevel(rawValue: defaultNoteLevelRaw) ?? .synthese }
    set { defaultNoteLevelRaw = newValue.rawValue }
}

// EKCalendar identifiers whitelist, stored as a JSON-encoded [String] in
// a single UserDefaults key (AppStorage doesn't support [String] directly).
@AppStorage("enabledCalendarIdsJSON") private var enabledCalendarIdsJSON: String = "[]"

public var enabledCalendarIds: [String] {
    get {
        guard let data = enabledCalendarIdsJSON.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return arr
    }
    set {
        let data = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8)
        enabledCalendarIdsJSON = String(data: data, encoding: .utf8) ?? "[]"
    }
}
```

Si le `SettingsStore` existant n'utilise pas `@AppStorage` mais un fichier JSON custom, adapte : ajoute les champs à la struct `Codable`, met des valeurs par défaut, et incrémente une éventuelle `schemaVersion`.

- [ ] **Step 3: Compile check**

Run: `swift build -c release --arch arm64`
Expected: build OK. Pas de tests pour ce store (persisté via UserDefaults, considéré comme surface trop simple pour un test unitaire — les usages sont testés via les composants qui le consomment).

- [ ] **Step 4: Stop (do not commit).**

---

## Task 9: `MeetingAppDetector` protocol + types

**Files:**
- Create: `Sources/RecorderCore/Detection/MeetingAppDetector.swift`

- [ ] **Step 1: Create the file**

```swift
// Sources/RecorderCore/Detection/MeetingAppDetector.swift
import Foundation

public enum MeetingApp: String, Codable, Sendable {
    case meet
    case slackHuddle = "slack_huddle"
}

public enum CallLifecycle: Sendable, Equatable {
    case started(code: String)
    case ended(code: String)
}

public struct CallEvent: Sendable, Equatable {
    public let app: MeetingApp
    public let kind: Kind
    public let code: String
    public let at: Date

    public enum Kind: Sendable, Equatable { case started, ended }

    public init(app: MeetingApp, kind: Kind, code: String, at: Date = Date()) {
        self.app = app; self.kind = kind; self.code = code; self.at = at
    }
}

public protocol MeetingAppDetector: Sendable {
    var app: MeetingApp { get }
    /// Async stream of `.started(code)` / `.ended(code)` — must be idempotent
    /// (don't re-emit same state without a change). Detector is expected to
    /// run its polling loop for the lifetime of the returned stream.
    func events() -> AsyncStream<CallLifecycle>
}
```

- [ ] **Step 2: Compile check**

Run: `swift build -c release --arch arm64`
Expected: OK.

- [ ] **Step 3: Stop (do not commit).**

---

## Task 10: `MeetDetector` (JXA polling of browser tabs)

**Files:**
- Create: `Sources/RecorderCore/Detection/MeetDetector.swift`

**Contexte :** poll toutes les 5s via `osascript -l JavaScript` (JXA) sur chaque navigateur scriptable. Extrait les URLs matchant `meet.google.com/xxx-yyyy-zzz`. Diff avec l'état précédent → émet started/ended.

Pas de test unitaire strict (dépendance macOS + permissions automation). La correctness sera validée par la checklist E2E (Task 24).

- [ ] **Step 1: Create the file**

```swift
// Sources/RecorderCore/Detection/MeetDetector.swift
import Foundation

public final class MeetDetector: MeetingAppDetector {
    public let app: MeetingApp = .meet

    private let pollSeconds: TimeInterval
    /// Bundle IDs of scriptable Chromium/WebKit browsers.
    private let browserBundles: [String]

    public init(pollSeconds: TimeInterval = 5,
                browserBundles: [String] = [
                    "com.google.Chrome",
                    "com.apple.Safari",
                    "company.thebrowser.Browser", // Arc
                    "com.brave.Browser",
                ]) {
        self.pollSeconds = pollSeconds
        self.browserBundles = browserBundles
    }

    private static let meetURLRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"meet\.google\.com/([a-z]{3}-[a-z]{4}-[a-z]{3})"#,
            options: [.caseInsensitive])
    }()

    public func events() -> AsyncStream<CallLifecycle> {
        AsyncStream { continuation in
            let task = Task.detached { [pollSeconds, browserBundles] in
                var active = Set<String>()
                while !Task.isCancelled {
                    let current = Self.pollAllBrowsers(bundles: browserBundles)
                    let newlyStarted = current.subtracting(active)
                    let ended = active.subtracting(current)
                    for c in newlyStarted { continuation.yield(.started(code: c)) }
                    for c in ended { continuation.yield(.ended(code: c)) }
                    active = current
                    try? await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs a JXA script against each browser and returns the union of meeting codes found.
    static func pollAllBrowsers(bundles: [String]) -> Set<String> {
        var codes = Set<String>()
        for bundle in bundles {
            let urls = jxaURLs(forBundle: bundle)
            for url in urls {
                let range = NSRange(url.startIndex..<url.endIndex, in: url)
                if let m = meetURLRegex.firstMatch(in: url, range: range),
                   let codeRange = Range(m.range(at: 1), in: url) {
                    codes.insert(String(url[codeRange]))
                }
            }
        }
        return codes
    }

    /// Returns URLs of all tabs across all windows of the given browser, or []
    /// if the browser isn't running or automation is denied.
    static func jxaURLs(forBundle bundle: String) -> [String] {
        let script = """
        function run() {
          try {
            var app = Application(\"\(bundle)\");
            if (!app.running()) return \"\";
            var urls = [];
            app.windows().forEach(function(w) {
              try {
                w.tabs().forEach(function(t) { urls.push(t.url()); });
              } catch(e) {}
            });
            return urls.join(\"\\n\");
          } catch(e) { return \"\"; }
        }
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-l", "JavaScript", "-e", script]
        let out = Pipe(); let err = Pipe()
        proc.standardOutput = out; proc.standardError = err
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            Log.pipeline.warning("JXA launch failed for \(bundle, privacy: .public): \(error)")
            return []
        }
        guard proc.terminationStatus == 0 else { return [] }
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        guard let s = String(data: data, encoding: .utf8), !s.isEmpty else { return [] }
        return s.split(separator: "\n").map(String.init)
    }
}
```

Note : `Log.pipeline` (existant Chantier 1) est déjà défini dans `Sources/RecorderCore/Support/Log.swift`. Si l'API `os.log` diffère, adapte.

- [ ] **Step 2: Compile check**

Run: `swift build -c release --arch arm64`
Expected: OK.

- [ ] **Step 3: Smoke test manuel**

Ce détecteur ne se teste pas en CI. À la Task 24 (E2E), la checklist inclut : "ouvrir un Meet dans Chrome, vérifier que la détection log `.started`".

- [ ] **Step 4: Stop (do not commit).**

---

## Task 11: `SlackHuddleDetector` (CGWindowList polling)

**Files:**
- Create: `Sources/RecorderCore/Detection/SlackHuddleDetector.swift`

**Contexte :** observe `NSRunningApplication` pour Slack.app ; quand présent, poll les fenêtres via `CGWindowListCopyWindowInfo`, match titre contenant `"Huddle"`.

Pas de nouvelle permission — Screen Recording (Chantier 1) suffit.

- [ ] **Step 1: Create the file**

```swift
// Sources/RecorderCore/Detection/SlackHuddleDetector.swift
import Foundation
import AppKit
import CoreGraphics

public final class SlackHuddleDetector: MeetingAppDetector {
    public let app: MeetingApp = .slackHuddle

    private let pollSeconds: TimeInterval
    private let slackBundle = "com.tinyspeck.slackmacgap"

    public init(pollSeconds: TimeInterval = 5) {
        self.pollSeconds = pollSeconds
    }

    public func events() -> AsyncStream<CallLifecycle> {
        AsyncStream { continuation in
            let task = Task.detached { [pollSeconds, slackBundle] in
                var active = Set<String>()
                while !Task.isCancelled {
                    let current = Self.currentHuddleWindowIDs(slackBundle: slackBundle)
                    let started = current.subtracting(active)
                    let ended = active.subtracting(current)
                    for c in started { continuation.yield(.started(code: c)) }
                    for c in ended { continuation.yield(.ended(code: c)) }
                    active = current
                    try? await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Returns the set of Slack window IDs (as decimal strings) whose title
    /// contains "Huddle". Empty if Slack isn't running.
    static func currentHuddleWindowIDs(slackBundle: String) -> Set<String> {
        let slackRunning = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == slackBundle }
        guard slackRunning else { return [] }

        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        var codes = Set<String>()
        for w in windows {
            guard let owner = w[kCGWindowOwnerName as String] as? String,
                  owner == "Slack" else { continue }
            guard let title = w[kCGWindowName as String] as? String else { continue }
            if title.range(of: "Huddle", options: .caseInsensitive) != nil {
                if let id = w[kCGWindowNumber as String] as? Int {
                    codes.insert(String(id))
                }
            }
        }
        return codes
    }
}
```

- [ ] **Step 2: Compile check**

Run: `swift build -c release --arch arm64`

- [ ] **Step 3: Stop (do not commit).**

---

## Task 12: `DetectionCoordinator` (merge + debounce)

**Files:**
- Create: `Sources/RecorderCore/Detection/DetectionCoordinator.swift`
- Test: `Tests/RecorderCoreTests/DetectionCoordinatorTests.swift`

**Contexte :** merge N détecteurs, applique un debounce de 3s sur `.ended` (annule si un `.started` du même `(app, code)` revient dans les 3s).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/RecorderCoreTests/DetectionCoordinatorTests.swift
import XCTest
@testable import RecorderCore

final class DetectionCoordinatorTests: XCTestCase {

    /// Test double: replays a fixed sequence of lifecycle events at controlled
    /// timings, then keeps the stream open.
    final class FakeDetector: MeetingAppDetector, @unchecked Sendable {
        let app: MeetingApp
        private let script: [(TimeInterval, CallLifecycle)]
        init(app: MeetingApp, script: [(TimeInterval, CallLifecycle)]) {
            self.app = app; self.script = script
        }
        func events() -> AsyncStream<CallLifecycle> {
            AsyncStream { continuation in
                let s = script
                Task.detached {
                    for (delay, ev) in s {
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continuation.yield(ev)
                    }
                    // Keep open — do not finish so the coordinator's merge loop
                    // does not tear down early.
                }
            }
        }
    }

    func testMergesEventsFromMultipleDetectors() async throws {
        let a = FakeDetector(app: .meet, script: [(0.05, .started(code: "meetA"))])
        let b = FakeDetector(app: .slackHuddle, script: [(0.10, .started(code: "hudB"))])
        let coord = DetectionCoordinator(detectors: [a, b], debounceEndedSeconds: 3)

        var seen: [CallEvent] = []
        let listener = Task {
            for await ev in coord.events() {
                seen.append(ev)
                if seen.count == 2 { break }
            }
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        listener.cancel()
        XCTAssertEqual(seen.count, 2)
        XCTAssertTrue(seen.contains { $0.app == .meet && $0.kind == .started && $0.code == "meetA" })
        XCTAssertTrue(seen.contains { $0.app == .slackHuddle && $0.kind == .started && $0.code == "hudB" })
    }

    func testDebounceCancelsEndedIfRestartedFast() async throws {
        let d = FakeDetector(app: .meet, script: [
            (0.00, .started(code: "M1")),
            (0.10, .ended(code: "M1")),
            (0.50, .started(code: "M1")),   // flicker — must cancel the .ended
        ])
        let coord = DetectionCoordinator(detectors: [d], debounceEndedSeconds: 3)

        var seen: [CallEvent] = []
        let listener = Task {
            for await ev in coord.events() { seen.append(ev) }
        }
        try await Task.sleep(nanoseconds: 4_000_000_000)  // 4s > debounce window
        listener.cancel()

        // We should see: started, (debounced ended cancelled), then no re-started
        // because state was still .started when the .started came back.
        XCTAssertEqual(seen.filter { $0.kind == .started }.count, 1)
        XCTAssertEqual(seen.filter { $0.kind == .ended }.count, 0,
                       ".ended should have been cancelled by the flicker .started")
    }

    func testDebounceLetsEndedThroughIfStable() async throws {
        let d = FakeDetector(app: .meet, script: [
            (0.00, .started(code: "M2")),
            (0.10, .ended(code: "M2")),
        ])
        let coord = DetectionCoordinator(detectors: [d], debounceEndedSeconds: 1)

        var seen: [CallEvent] = []
        let listener = Task {
            for await ev in coord.events() { seen.append(ev) }
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)  // > debounce
        listener.cancel()

        XCTAssertEqual(seen.filter { $0.kind == .started }.count, 1)
        XCTAssertEqual(seen.filter { $0.kind == .ended }.count, 1)
    }
}
```

- [ ] **Step 2: Run — expect FAIL (`DetectionCoordinator` unknown)**

Run: `swift test --filter DetectionCoordinatorTests`

- [ ] **Step 3: Create `DetectionCoordinator.swift`**

```swift
// Sources/RecorderCore/Detection/DetectionCoordinator.swift
import Foundation

public actor DetectionCoordinator {
    private let detectors: [any MeetingAppDetector]
    private let debounceEndedSeconds: TimeInterval

    /// Pending .ended timers: keyed by "app:code", value is the Task that will
    /// emit the .ended after the debounce window if not cancelled.
    private var pendingEnded: [String: Task<Void, Never>] = [:]

    public init(detectors: [any MeetingAppDetector],
                debounceEndedSeconds: TimeInterval = 3) {
        self.detectors = detectors
        self.debounceEndedSeconds = debounceEndedSeconds
    }

    public nonisolated func events() -> AsyncStream<CallEvent> {
        AsyncStream { continuation in
            let task = Task {
                await self.run(continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(continuation: AsyncStream<CallEvent>.Continuation) async {
        await withTaskGroup(of: Void.self) { group in
            for detector in detectors {
                group.addTask { [weak self] in
                    let app = detector.app
                    for await lifecycle in detector.events() {
                        await self?.handle(lifecycle, from: app, sink: continuation)
                    }
                }
            }
            // Keep the group alive; loops end when detectors finish or cancel.
        }
        continuation.finish()
    }

    private func handle(_ ev: CallLifecycle,
                        from app: MeetingApp,
                        sink: AsyncStream<CallEvent>.Continuation) {
        switch ev {
        case .started(let code):
            let key = "\(app.rawValue):\(code)"
            // If we had a pending .ended for the same (app, code), cancel it.
            if let pending = pendingEnded.removeValue(forKey: key) {
                pending.cancel()
            }
            sink.yield(CallEvent(app: app, kind: .started, code: code))

        case .ended(let code):
            let key = "\(app.rawValue):\(code)"
            // Cancel any older pending .ended for the same key (dedup).
            pendingEnded[key]?.cancel()
            let delaySeconds = debounceEndedSeconds
            let task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.emitEnded(app: app, code: code, sink: sink)
            }
            pendingEnded[key] = task
        }
    }

    private func emitEnded(app: MeetingApp,
                           code: String,
                           sink: AsyncStream<CallEvent>.Continuation) {
        let key = "\(app.rawValue):\(code)"
        pendingEnded[key] = nil
        sink.yield(CallEvent(app: app, kind: .ended, code: code))
    }
}
```

- [ ] **Step 4: Run — expect PASS (3 tests)**

Run: `swift test --filter DetectionCoordinatorTests`

Ces tests durent quelques secondes cumulés à cause des `sleep` (debounce timing). C'est attendu.

- [ ] **Step 5: Stop (do not commit).**

---

## Task 13: `MatchedEvent` type + `CalendarMatcher` (rules pures, testable)

**Files:**
- Create: `Sources/RecorderCore/Calendar/MatchedEvent.swift`
- Create: `Sources/RecorderCore/Calendar/CalendarMatcher.swift`
- Test: `Tests/RecorderCoreTests/CalendarMatchRulesTests.swift`

**Contexte :** avant de coder l'accès EventKit (impur, non-testable en CI), on isole les **règles de match pures** dans un `CalendarMatcher` qui prend un DTO (indépendant d'`EKEvent`) et retourne un `MatchedEvent?`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/RecorderCoreTests/CalendarMatchRulesTests.swift
import XCTest
@testable import RecorderCore

final class CalendarMatchRulesTests: XCTestCase {

    private func input(title: String = "Team sync",
                       calendarId: String = "cal-work",
                       attendeeCount: Int = 2,
                       notes: String? = nil,
                       location: String? = nil,
                       start: Date = .init(timeIntervalSince1970: 1_700_000_000),
                       end: Date = .init(timeIntervalSince1970: 1_700_003_600),
                       id: String = "e-1") -> CalendarEventInput {
        CalendarEventInput(id: id, title: title, calendarId: calendarId,
                           attendeeCount: attendeeCount, notes: notes,
                           location: location, startDate: start, endDate: end)
    }

    func testMatchesEventInWhitelistWithMeetLinkInNotes() {
        let m = CalendarMatcher(whitelistedCalendarIds: ["cal-work"])
        let ev = input(notes: "Join at https://meet.google.com/abc-defg-hij")
        let matched = m.match(ev)
        XCTAssertNotNil(matched)
        XCTAssertEqual(matched?.meetURL.absoluteString,
                       "https://meet.google.com/abc-defg-hij")
    }

    func testRejectsEventFromOtherCalendar() {
        let m = CalendarMatcher(whitelistedCalendarIds: ["cal-work"])
        let ev = input(calendarId: "cal-perso",
                       notes: "https://meet.google.com/aaa-bbbb-ccc")
        XCTAssertNil(m.match(ev))
    }

    func testRejectsEventWithNoOtherAttendees() {
        let m = CalendarMatcher(whitelistedCalendarIds: ["cal-work"])
        let ev = input(attendeeCount: 1,
                       notes: "https://meet.google.com/aaa-bbbb-ccc")
        XCTAssertNil(m.match(ev))
    }

    func testRejectsEventTaggedNoRec() {
        let m = CalendarMatcher(whitelistedCalendarIds: ["cal-work"])
        let ev = input(title: "Standup [no-rec]",
                       notes: "https://meet.google.com/aaa-bbbb-ccc")
        XCTAssertNil(m.match(ev))
    }

    func testRejectsEventWithoutMeetLink() {
        let m = CalendarMatcher(whitelistedCalendarIds: ["cal-work"])
        let ev = input(notes: "Zoom link: https://zoom.us/j/12345")
        XCTAssertNil(m.match(ev))
    }

    func testAcceptsMeetLinkInLocationField() {
        let m = CalendarMatcher(whitelistedCalendarIds: ["cal-work"])
        let ev = input(location: "meet.google.com/qrs-tuvw-xyz")
        XCTAssertNotNil(m.match(ev))
    }

    func testCaseInsensitiveNoRecMarker() {
        let m = CalendarMatcher(whitelistedCalendarIds: ["cal-work"])
        let ev = input(title: "Standup [NO-REC]",
                       notes: "https://meet.google.com/aaa-bbbb-ccc")
        XCTAssertNil(m.match(ev))
    }
}
```

- [ ] **Step 2: Run — expect FAIL (types unknown)**

Run: `swift test --filter CalendarMatchRulesTests`

- [ ] **Step 3: Create `MatchedEvent.swift`**

```swift
// Sources/RecorderCore/Calendar/MatchedEvent.swift
import Foundation

public struct MatchedEvent: Sendable, Equatable {
    public let id: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let meetURL: URL
    public let calendarId: String

    public init(id: String, title: String, startDate: Date, endDate: Date,
                meetURL: URL, calendarId: String) {
        self.id = id; self.title = title
        self.startDate = startDate; self.endDate = endDate
        self.meetURL = meetURL; self.calendarId = calendarId
    }
}

/// EventKit-independent DTO passed to `CalendarMatcher.match`. Populated by
/// `CalendarWatcher` from an `EKEvent`.
public struct CalendarEventInput: Sendable, Equatable {
    public let id: String
    public let title: String
    public let calendarId: String
    public let attendeeCount: Int
    public let notes: String?
    public let location: String?
    public let startDate: Date
    public let endDate: Date

    public init(id: String, title: String, calendarId: String,
                attendeeCount: Int, notes: String?, location: String?,
                startDate: Date, endDate: Date) {
        self.id = id; self.title = title; self.calendarId = calendarId
        self.attendeeCount = attendeeCount; self.notes = notes
        self.location = location; self.startDate = startDate; self.endDate = endDate
    }
}
```

- [ ] **Step 4: Create `CalendarMatcher.swift`**

```swift
// Sources/RecorderCore/Calendar/CalendarMatcher.swift
import Foundation

public struct CalendarMatcher: Sendable {
    public let whitelistedCalendarIds: Set<String>

    public init(whitelistedCalendarIds: [String]) {
        self.whitelistedCalendarIds = Set(whitelistedCalendarIds)
    }

    private static let meetRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"meet\.google\.com/([a-z]{3}-[a-z]{4}-[a-z]{3})"#,
            options: [.caseInsensitive])
    }()

    public func match(_ ev: CalendarEventInput) -> MatchedEvent? {
        guard whitelistedCalendarIds.contains(ev.calendarId) else { return nil }
        guard ev.attendeeCount > 1 else { return nil }
        if ev.title.range(of: "[no-rec]", options: .caseInsensitive) != nil { return nil }

        let haystack = (ev.notes ?? "") + " " + (ev.location ?? "")
        let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
        guard let m = Self.meetRegex.firstMatch(in: haystack, range: range),
              let codeRange = Range(m.range(at: 1), in: haystack)
        else { return nil }
        let code = String(haystack[codeRange])
        guard let url = URL(string: "https://meet.google.com/\(code)") else { return nil }

        return MatchedEvent(id: ev.id, title: ev.title,
                            startDate: ev.startDate, endDate: ev.endDate,
                            meetURL: url, calendarId: ev.calendarId)
    }
}
```

- [ ] **Step 5: Run — expect PASS (7 tests)**

Run: `swift test --filter CalendarMatchRulesTests`

- [ ] **Step 6: Stop (do not commit).**

---

## Task 14: `CalendarWatcher` (EventKit polling loop)

**Files:**
- Create: `Sources/RecorderCore/Calendar/CalendarWatcher.swift`

**Contexte :** poll toutes les 60s, horizon `now → now + 15min`, produit un `AsyncStream<MatchedEvent>`. L'accès EventKit doit être async (permission déjà accordée via onboarding). Pas de test unitaire — testable seulement en E2E avec un vrai `EKEventStore`.

- [ ] **Step 1: Create the file**

```swift
// Sources/RecorderCore/Calendar/CalendarWatcher.swift
import Foundation
import EventKit

public final class CalendarWatcher {
    private let store: EKEventStore
    private let horizonMinutes: TimeInterval
    private let pollSeconds: TimeInterval

    public init(store: EKEventStore = EKEventStore(),
                horizonMinutes: TimeInterval = 15,
                pollSeconds: TimeInterval = 60) {
        self.store = store
        self.horizonMinutes = horizonMinutes
        self.pollSeconds = pollSeconds
    }

    /// Requests full access to events. Returns true if granted.
    /// Call once from onboarding.
    public func requestAccess() async -> Bool {
        do {
            if #available(macOS 14.0, *) {
                return try await store.requestFullAccessToEvents()
            } else {
                return try await withCheckedThrowingContinuation { cont in
                    store.requestAccess(to: .event) { granted, error in
                        if let error { cont.resume(throwing: error) }
                        else { cont.resume(returning: granted) }
                    }
                }
            }
        } catch {
            Log.pipeline.warning("Calendar access request failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Streams `MatchedEvent`s whose `startDate` is within `[now, now + horizonMinutes]`.
    /// Each event is emitted at most once per its `id`.
    public func matches(matcher: CalendarMatcher) -> AsyncStream<MatchedEvent> {
        AsyncStream { continuation in
            let task = Task.detached { [horizonMinutes, pollSeconds, store] in
                var armed = Set<String>()
                while !Task.isCancelled {
                    let now = Date()
                    let horizon = now.addingTimeInterval(horizonMinutes * 60)
                    let predicate = store.predicateForEvents(withStart: now,
                                                             end: horizon,
                                                             calendars: nil)
                    let events = store.events(matching: predicate)
                    for ekEvent in events {
                        guard let id = ekEvent.eventIdentifier else { continue }
                        let key = "\(id)|\(Int(ekEvent.startDate.timeIntervalSince1970))"
                        if armed.contains(key) { continue }
                        let input = CalendarEventInput(
                            id: id,
                            title: ekEvent.title ?? "",
                            calendarId: ekEvent.calendar.calendarIdentifier,
                            attendeeCount: (ekEvent.attendees?.count ?? 0) + 1, // +1 for self
                            notes: ekEvent.notes,
                            location: ekEvent.location,
                            startDate: ekEvent.startDate,
                            endDate: ekEvent.endDate
                        )
                        if let matched = matcher.match(input) {
                            continuation.yield(matched)
                            armed.insert(key)
                        }
                    }
                    // GC: drop armed keys whose start time was > 5 min ago.
                    let cutoff = Int(Date().addingTimeInterval(-300).timeIntervalSince1970)
                    armed = armed.filter { key in
                        guard let ts = Int(key.split(separator: "|").last ?? "") else { return false }
                        return ts >= cutoff
                    }
                    try? await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Returns the list of calendars the user can pick from during onboarding.
    public func availableCalendars() -> [EKCalendar] {
        store.calendars(for: .event)
    }
}
```

- [ ] **Step 2: Compile check**

Run: `swift build -c release --arch arm64`
Expected: build OK. Le test suite ne s'exécute pas contre EventKit en CI ; les règles ont déjà été testées via `CalendarMatcher`.

- [ ] **Step 3: Stop (do not commit).**

---

## Task 15: `AutoTriggerOrchestrator` (state machine)

**Files:**
- Create: `Sources/RecorderCore/Autotrigger/AutoTriggerOrchestrator.swift`
- Test: `Tests/RecorderCoreTests/AutoTriggerOrchestratorTests.swift`

**Contexte :** actor stateful qui applique la table de transitions de la spec §6. On isole complètement la logique métier du `Recorder` réel en la faisant parler à un **protocol `RecordingSession`** (mockable en test).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/RecorderCoreTests/AutoTriggerOrchestratorTests.swift
import XCTest
@testable import RecorderCore

final class AutoTriggerOrchestratorTests: XCTestCase {

    /// Test double that records calls, doesn't actually record audio.
    actor FakeSession: RecordingSession {
        struct Log: Equatable {
            enum Op { case start, stop, cancel, patch }
            let op: Op
            let meta: MeetingMetadata?
        }
        private(set) var log: [Log] = []
        private(set) var currentMeta: MeetingMetadata?

        func start(meta: MeetingMetadata) async throws {
            currentMeta = meta
            log.append(.init(op: .start, meta: meta))
        }
        func stop() async throws {
            log.append(.init(op: .stop, meta: currentMeta))
            currentMeta = nil
        }
        func cancel() async throws {
            log.append(.init(op: .cancel, meta: currentMeta))
            currentMeta = nil
        }
        func patchMeta(_ mut: (inout MeetingMetadata) -> Void) async throws {
            guard var m = currentMeta else { return }
            mut(&m); currentMeta = m
            log.append(.init(op: .patch, meta: m))
        }
    }

    private func now() -> Date { Date() }

    func testCalendarStartTriggersRecording() async throws {
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session)
        let match = MatchedEvent(id: "e1", title: "Design review",
                                 startDate: now(), endDate: now().addingTimeInterval(1800),
                                 meetURL: URL(string: "https://meet.google.com/aaa-bbbb-ccc")!,
                                 calendarId: "cal-work")
        try await orch.onCalendarEvent(match)
        let log = await session.log
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log.first?.op, .start)
        XCTAssertEqual(log.first?.meta?.source, .calendar)
        XCTAssertEqual(log.first?.meta?.title, "Design review")
        XCTAssertEqual(log.first?.meta?.calendarEventId, "e1")
    }

    func testCallStartedWithNoMatchingEventStartsAsDetected() async throws {
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session)
        let ev = CallEvent(app: .meet, kind: .started, code: "xyz")
        try await orch.onCallEvent(ev)
        let log = await session.log
        XCTAssertEqual(log.first?.meta?.source, .detected)
        XCTAssertEqual(log.first?.meta?.detectedApp, "meet")
        XCTAssertEqual(log.first?.meta?.detectedCode, "xyz")
    }

    func testCallStartedLinksToRecentCalendarEvent() async throws {
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session)
        // Register a matched event with start ~ now (within ±5min).
        let match = MatchedEvent(id: "e1", title: "Team sync",
                                 startDate: now(), endDate: now().addingTimeInterval(1800),
                                 meetURL: URL(string: "https://meet.google.com/xxx-yyyy-zzz")!,
                                 calendarId: "cal-work")
        await orch.registerRecentMatchedEvent(match)
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "xxx-yyyy-zzz"))
        let log = await session.log
        XCTAssertEqual(log.first?.meta?.source, .calendar,
                       ".calendar (with detectedApp filled) when linked")
        XCTAssertEqual(log.first?.meta?.calendarEventId, "e1")
        XCTAssertEqual(log.first?.meta?.detectedApp, "meet")
    }

    func testSecondCalendarEventIgnoredWhileRecording() async throws {
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session)
        let m1 = MatchedEvent(id: "e1", title: "A", startDate: now(),
                              endDate: now().addingTimeInterval(1800),
                              meetURL: URL(string: "https://meet.google.com/aaa-bbbb-ccc")!,
                              calendarId: "cal-work")
        let m2 = MatchedEvent(id: "e2", title: "B", startDate: now(),
                              endDate: now().addingTimeInterval(1800),
                              meetURL: URL(string: "https://meet.google.com/ddd-eeee-fff")!,
                              calendarId: "cal-work")
        try await orch.onCalendarEvent(m1)
        try await orch.onCalendarEvent(m2)
        let log = await session.log
        XCTAssertEqual(log.filter { $0.op == .start }.count, 1)
    }

    func testCallEndedForTrackedAppStops() async throws {
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session)
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "M"))
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .ended, code: "M"))
        let log = await session.log
        XCTAssertEqual(log.map { $0.op }, [.start, .stop])
    }

    func testCallEndedForOtherAppIgnored() async throws {
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session)
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "M"))
        try await orch.onCallEvent(CallEvent(app: .slackHuddle, kind: .ended, code: "OTHER"))
        let log = await session.log
        XCTAssertEqual(log.map { $0.op }, [.start])  // no stop
    }

    func testDetectionLinksToCurrentCalendarRecording() async throws {
        // Currently recording via calendar (no detectedApp yet). A .started
        // for any app should patch the meta to link the detection.
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session)
        let match = MatchedEvent(id: "e1", title: "T", startDate: now(),
                                 endDate: now().addingTimeInterval(1800),
                                 meetURL: URL(string: "https://meet.google.com/aaa-bbbb-ccc")!,
                                 calendarId: "cal-work")
        try await orch.onCalendarEvent(match)
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "aaa-bbbb-ccc"))
        let log = await session.log
        XCTAssertEqual(log.count, 2)
        XCTAssertEqual(log[1].op, .patch)
        XCTAssertEqual(log[1].meta?.detectedApp, "meet")
        XCTAssertEqual(log[1].meta?.detectedCode, "aaa-bbbb-ccc")
    }

    func testManualStopWorksFromRecording() async throws {
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session)
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "M"))
        try await orch.manualStop()
        let log = await session.log
        XCTAssertEqual(log.map { $0.op }, [.start, .stop])
    }

    func testOptOutWithinCancelWindowCallsCancel() async throws {
        let session = FakeSession()
        let orch = AutoTriggerOrchestrator(session: session, cancelWindowSeconds: 999)
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "M"))
        try await orch.optOut()
        let log = await session.log
        XCTAssertEqual(log.map { $0.op }, [.start, .cancel])
    }

    func testOptOutOutsideCancelWindowActsAsStop() async throws {
        let session = FakeSession()
        // 0-second cancel window → any opt-out is a stop.
        let orch = AutoTriggerOrchestrator(session: session, cancelWindowSeconds: 0)
        try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "M"))
        try await Task.sleep(nanoseconds: 20_000_000)
        try await orch.optOut()
        let log = await session.log
        XCTAssertEqual(log.map { $0.op }, [.start, .stop])
    }
}
```

- [ ] **Step 2: Run — expect FAIL (types unknown)**

Run: `swift test --filter AutoTriggerOrchestratorTests`

- [ ] **Step 3: Create `AutoTriggerOrchestrator.swift`**

```swift
// Sources/RecorderCore/Autotrigger/AutoTriggerOrchestrator.swift
import Foundation

/// Abstraction over the real `Recorder` so the orchestrator can be tested
/// without touching AVAudioEngine / ScreenCaptureKit.
public protocol RecordingSession: Sendable {
    func start(meta: MeetingMetadata) async throws
    func stop() async throws
    func cancel() async throws
    func patchMeta(_ mut: (inout MeetingMetadata) -> Void) async throws
}

public actor AutoTriggerOrchestrator {
    public enum State: Equatable {
        case idle
        case recording(startedAt: Date, meta: MeetingMetadata)
    }

    private let session: any RecordingSession
    private let cancelWindowSeconds: TimeInterval
    private let matchLinkWindowSeconds: TimeInterval

    /// Recent matched calendar events, indexed by Meet code for cross-linking
    /// with detection. Populated by `registerRecentMatchedEvent`.
    private var recentMatchedByMeetCode: [String: (event: MatchedEvent, at: Date)] = [:]

    public private(set) var state: State = .idle

    public init(session: any RecordingSession,
                cancelWindowSeconds: TimeInterval = 30,
                matchLinkWindowSeconds: TimeInterval = 300) {
        self.session = session
        self.cancelWindowSeconds = cancelWindowSeconds
        self.matchLinkWindowSeconds = matchLinkWindowSeconds
    }

    // MARK: - Public entry points

    public func onCalendarEvent(_ match: MatchedEvent) async throws {
        registerRecentMatchedEvent(match)
        switch state {
        case .idle:
            let meta = MeetingMetadata(
                slug: Self.slug(for: match.startDate),
                startedAt: Date(),
                title: match.title,
                source: .calendar,
                calendarEventId: match.id
            )
            try await session.start(meta: meta)
            state = .recording(startedAt: Date(), meta: meta)
        case .recording:
            Log.pipeline.info("Calendar event \(match.id, privacy: .public) ignored — already recording")
        }
    }

    public func onCallEvent(_ ev: CallEvent) async throws {
        switch (state, ev.kind) {
        case (.idle, .started):
            let now = Date()
            // Try to link to a recent matched calendar event by Meet code.
            let code = ev.code
            var meta: MeetingMetadata
            if let linked = recentMatchedByMeetCode[code],
               abs(now.timeIntervalSince(linked.at)) <= matchLinkWindowSeconds {
                meta = MeetingMetadata(
                    slug: Self.slug(for: now),
                    startedAt: now,
                    title: linked.event.title,
                    source: .calendar,
                    calendarEventId: linked.event.id,
                    detectedApp: ev.app.rawValue,
                    detectedCode: ev.code
                )
            } else {
                meta = MeetingMetadata(
                    slug: Self.slug(for: now),
                    startedAt: now,
                    source: .detected,
                    detectedApp: ev.app.rawValue,
                    detectedCode: ev.code
                )
            }
            try await session.start(meta: meta)
            state = .recording(startedAt: now, meta: meta)

        case (.recording(let startedAt, var meta), .started):
            // Link detection to a calendar-triggered recording that didn't have one yet.
            if meta.detectedApp == nil {
                meta.detectedApp = ev.app.rawValue
                meta.detectedCode = ev.code
                try await session.patchMeta { m in
                    m.detectedApp = ev.app.rawValue
                    m.detectedCode = ev.code
                }
                state = .recording(startedAt: startedAt, meta: meta)
            }
            // Else assume same session — ignore.

        case (.recording(_, let meta), .ended):
            // Only stop if the ended app+code matches the one we're tracking.
            if meta.detectedApp == ev.app.rawValue,
               meta.detectedCode == ev.code {
                try await session.stop()
                state = .idle
            }
            // Else ignore.

        case (.idle, .ended):
            return
        }
    }

    public func manualStart() async throws {
        switch state {
        case .idle:
            let now = Date()
            let meta = MeetingMetadata(
                slug: Self.slug(for: now),
                startedAt: now,
                source: .manual
            )
            try await session.start(meta: meta)
            state = .recording(startedAt: now, meta: meta)
        case .recording:
            return
        }
    }

    public func manualStop() async throws {
        guard case .recording = state else { return }
        try await session.stop()
        state = .idle
    }

    /// User clicked the "Stop" action on the auto-start notification. Within
    /// `cancelWindowSeconds` this is a cancel (delete the meeting); after,
    /// it acts as a normal stop.
    public func optOut() async throws {
        guard case .recording(let startedAt, _) = state else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed <= cancelWindowSeconds {
            try await session.cancel()
        } else {
            try await session.stop()
        }
        state = .idle
    }

    /// Called by the CalendarWatcher for every match, keeps a rolling cache
    /// keyed by Meet code so late-arriving detection events can link back.
    public func registerRecentMatchedEvent(_ match: MatchedEvent) {
        let code = match.meetURL.lastPathComponent
        recentMatchedByMeetCode[code] = (match, Date())
        // GC entries older than the link window.
        let cutoff = Date().addingTimeInterval(-matchLinkWindowSeconds)
        recentMatchedByMeetCode = recentMatchedByMeetCode.filter { $0.value.at >= cutoff }
    }

    // MARK: - Helpers

    private static func slug(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd_HH'h'mm"
        return fmt.string(from: date)
    }
}
```

- [ ] **Step 4: Run — expect PASS (9 tests)**

Run: `swift test --filter AutoTriggerOrchestratorTests`

- [ ] **Step 5: Stop (do not commit).**

---

## Task 16: `OptOutNotificationCenter` — macOS notification avec bouton Stop

**Files:**
- Create: `Sources/Onyx/Notifications/OptOutNotificationCenter.swift`

**Contexte :** wrapper autour de `UNUserNotificationCenter` qui affiche une notif "Recording X — [Stop]" et route le clic vers `AutoTriggerOrchestrator.optOut()`. Pas de test unitaire (UI + framework Apple non-mockable en CI). Validation E2E.

- [ ] **Step 1: Create the file**

```swift
// Sources/Onyx/Notifications/OptOutNotificationCenter.swift
import Foundation
import UserNotifications
import RecorderCore

@MainActor
public final class OptOutNotificationCenter: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = OptOutNotificationCenter()
    private let stopActionId = "onyx.optout.stop"
    private let categoryId = "onyx.recording.optout"

    /// Provider closure resolved lazily so the orchestrator can be injected
    /// once at app startup.
    public var optOutHandler: (@Sendable () async -> Void)?

    private var configured = false

    public func configureIfNeeded() {
        guard !configured else { return }
        let stop = UNNotificationAction(identifier: stopActionId,
                                        title: "Stop",
                                        options: [.destructive])
        let cat = UNNotificationCategory(identifier: categoryId,
                                         actions: [stop],
                                         intentIdentifiers: [],
                                         options: [])
        UNUserNotificationCenter.current().setNotificationCategories([cat])
        UNUserNotificationCenter.current().delegate = self
        Task { await requestAuthorizationIfNeeded() }
        configured = true
    }

    public func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    public func showRecordingStarted(title: String, subtitle: String? = nil) {
        configureIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = "Recording — \(title)"
        if let subtitle { content.subtitle = subtitle }
        content.body = "Click Stop to cancel or end early."
        content.categoryIdentifier = categoryId
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content,
                                        trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    public func showIgnored(title: String) {
        let content = UNMutableNotificationContent()
        content.title = "Event ignored"
        content.body = "\(title) — already recording."
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    public func showNotesFailed(slug: String) {
        let content = UNMutableNotificationContent()
        content.title = "Notes generation failed"
        content.body = "\(slug) — retry from menu."
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - UNUserNotificationCenterDelegate

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == stopActionId, let handler = optOutHandler {
            Task { await handler(); completionHandler() }
        } else {
            completionHandler()
        }
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler:
                                       @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
```

- [ ] **Step 2: Compile check**

Run: `swift build -c release --arch arm64`
Expected: OK.

- [ ] **Step 3: Stop (do not commit).**

---

## Task 17: `RecordingSession` implementation contre le `Recorder` réel

**Files:**
- Modify: `Sources/RecorderCore/Recorder/Recorder.swift`
- Create: `Sources/RecorderCore/Autotrigger/RecorderSession.swift`

**Contexte :** l'orchestrator parle à un protocol. Il faut une classe concrète qui l'implémente en s'appuyant sur le `Recorder` du Chantier 1. Le `Recorder` existant a `start()` / `stop()` mais retourne des `MeetingPaths` — il faut réconcilier avec le nouveau contrat qui prend une `MeetingMetadata` en entrée.

Décision : la `MeetingMetadata` **prescrit** ce qui doit être écrit sur disque au démarrage. Le `Recorder.start()` actuel écrit une meta par défaut ; on l'étend pour accepter une meta pré-remplie.

- [ ] **Step 1: Extend `Recorder.start` to accept a pre-built meta**

Ouvre `Sources/RecorderCore/Recorder/Recorder.swift`. Ajoute une variante :

```swift
/// Same as `start()` but writes the given pre-built metadata to disk instead
/// of the default one. Used by the auto-trigger orchestrator to carry
/// title/source/eventId/detectedApp/detectedCode from the moment of start.
public func start(metadata: MeetingMetadata) async throws -> MeetingPaths {
    // Reuse the same path-creation logic as start().
    let paths = try storage.createMeeting(slug: metadata.slug,
                                          startedAt: metadata.startedAt)
    try storage.saveMetadata(metadata, at: paths)
    // Boot the mic + system capture as in the existing start().
    try mic.start(outputWav: paths.micWav)
    try system.start(outputWav: paths.systemWav)
    flushTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
        try? self?.mic.flushHeader()
        try? self?.system.flushHeader()
    }
    self.currentPaths = paths
    self.state = .recording
    return paths
}
```

Assure-toi que `MeetingStorage.createMeeting(slug:startedAt:)` existe (variante permettant un slug custom). Si l'existant n'accepte que la version qui compute son propre slug, ajoute :

```swift
// In MeetingStorage.swift:
public func createMeeting(slug: String, startedAt: Date) throws -> MeetingPaths {
    let paths = MeetingPaths(root: root, slug: slug)
    try FileManager.default.createDirectory(at: paths.root,
                                            withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: paths.audioDir,
                                            withIntermediateDirectories: true)
    let job = JobState.fresh()
    try saveJob(job, at: paths)
    return paths
}
```

Et une méthode `patchMetadata` :

```swift
public func patchMetadata(_ mut: (inout MeetingMetadata) -> Void,
                          at paths: MeetingPaths) throws {
    var meta = try loadMetadata(paths)
    mut(&meta)
    try saveMetadata(meta, at: paths)
}
```

- [ ] **Step 2: Create `RecorderSession.swift`**

```swift
// Sources/RecorderCore/Autotrigger/RecorderSession.swift
import Foundation

/// Concrete `RecordingSession` bridging the orchestrator to the real Recorder.
/// Also drives the post-stop pipeline execution.
public final class RecorderSession: RecordingSession, @unchecked Sendable {
    private let recorder: Recorder
    private let storage: MeetingStorage
    private let pipeline: Pipeline

    private var currentPaths: MeetingPaths?
    private let lock = NSLock()

    public init(recorder: Recorder, storage: MeetingStorage, pipeline: Pipeline) {
        self.recorder = recorder
        self.storage = storage
        self.pipeline = pipeline
    }

    public func start(meta: MeetingMetadata) async throws {
        let paths = try await recorder.start(metadata: meta)
        lock.lock(); currentPaths = paths; lock.unlock()
    }

    public func stop() async throws {
        let paths = try await recorder.stop()
        lock.lock(); currentPaths = nil; lock.unlock()
        // Kick pipeline in background; we don't await it in this call path
        // so the orchestrator can immediately go back to .idle.
        Task.detached { [pipeline] in
            do { try await pipeline.run(paths: paths) }
            catch { Log.pipeline.error("Pipeline failed for \(paths.slug, privacy: .public): \(String(describing: error), privacy: .public)") }
        }
    }

    public func cancel() async throws {
        guard let paths = currentPaths else { return }
        try recorder.cancel(paths: paths)
        lock.lock(); currentPaths = nil; lock.unlock()
    }

    public func patchMeta(_ mut: (inout MeetingMetadata) -> Void) async throws {
        guard let paths = currentPaths else { return }
        try storage.patchMetadata(mut, at: paths)
    }
}
```

- [ ] **Step 3: Compile check**

Run: `swift build -c release --arch arm64`
Expected: OK.

- [ ] **Step 4: Stop (do not commit).**

---

## Task 18: `MeetingIndexer.recentMeetings` + colonne `title`

**Files:**
- Modify: `Sources/RecorderCore/Index/IndexSchema.swift`
- Modify: `Sources/RecorderCore/Index/MeetingIndexer.swift`
- Test: `Tests/RecorderCoreTests/MeetingIndexerRecentTests.swift`

**Contexte :** SQLite migration incrémentale — on ajoute une colonne `title TEXT` et une méthode `recentMeetings(limit:)` triée par `startedAt DESC`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/RecorderCoreTests/MeetingIndexerRecentTests.swift
import XCTest
@testable import RecorderCore

final class MeetingIndexerRecentTests: XCTestCase {
    func testRecentMeetingsReturnsMostRecentFirst() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-idx-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let idx = try MeetingIndexer(dbPath: dbURL)

        let earlier = MeetingMetadata(slug: "2026-07-27_10h00",
                                      startedAt: Date(timeIntervalSince1970: 1),
                                      title: "Earlier")
        let later = MeetingMetadata(slug: "2026-07-28_10h00",
                                    startedAt: Date(timeIntervalSince1970: 2),
                                    title: "Later")

        try idx.upsert(meta: earlier,
                       folderPath: URL(fileURLWithPath: "/tmp/e"),
                       transcriptState: "done", transcript: [])
        try idx.upsert(meta: later,
                       folderPath: URL(fileURLWithPath: "/tmp/l"),
                       transcriptState: "done", transcript: [])

        let listings = try idx.recentMeetings(limit: 5)
        XCTAssertEqual(listings.count, 2)
        XCTAssertEqual(listings.first?.slug, "2026-07-28_10h00")
        XCTAssertEqual(listings.first?.title, "Later")
    }

    func testRecentMeetingsRespectsLimit() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-idx-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let idx = try MeetingIndexer(dbPath: dbURL)
        for i in 0..<10 {
            let meta = MeetingMetadata(slug: "m\(i)",
                                       startedAt: Date(timeIntervalSince1970: TimeInterval(i)),
                                       title: "t\(i)")
            try idx.upsert(meta: meta,
                           folderPath: URL(fileURLWithPath: "/tmp/m\(i)"),
                           transcriptState: "done", transcript: [])
        }
        let listings = try idx.recentMeetings(limit: 3)
        XCTAssertEqual(listings.count, 3)
        XCTAssertEqual(listings.map(\.slug), ["m9", "m8", "m7"])
    }
}
```

- [ ] **Step 2: Run — expect FAIL (method missing or column missing)**

Run: `swift test --filter MeetingIndexerRecentTests`

- [ ] **Step 3: Add migration and method**

Ouvre `Sources/RecorderCore/Index/IndexSchema.swift`. À la fin des `CREATE TABLE`, ajoute (idempotent via `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` si dispo, sinon try-except sur `ALTER TABLE`) :

```swift
public static let migrations: [String] = [
    // ... existing ...
    "ALTER TABLE meetings ADD COLUMN title TEXT"   // Chantier 2
]
```

Dans `MeetingIndexer.swift`, si les migrations sont exécutées dans une boucle qui logue-et-continue sur erreur, l'ajout d'une colonne déjà présente sera silencieusement toléré. Sinon wrap le `try` dans un `do { ... } catch { /* likely already exists */ }`.

Puis, dans `upsert`, ajoute `title` aux paramètres INSERT/UPDATE :

```swift
// In the SQL:
INSERT INTO meetings (slug, started_at, stopped_at, folder_path,
                      transcript_state, title)
VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT(slug) DO UPDATE SET
    stopped_at=excluded.stopped_at,
    folder_path=excluded.folder_path,
    transcript_state=excluded.transcript_state,
    title=excluded.title;
```

Bind `meta.title` en dernier paramètre.

Puis ajoute :

```swift
public func recentMeetings(limit: Int = 5) throws -> [MeetingListing] {
    let rows = try db.query(
        "SELECT slug, started_at, stopped_at, folder_path, title, transcript_state FROM meetings ORDER BY started_at DESC LIMIT ?",
        bindings: [limit]
    )
    return rows.map { row in
        MeetingListing(
            slug: row["slug"] as! String,
            startedAt: Date(timeIntervalSince1970: row["started_at"] as! Double),
            stoppedAt: (row["stopped_at"] as? Double).map { Date(timeIntervalSince1970: $0) },
            folderPath: URL(fileURLWithPath: row["folder_path"] as! String),
            title: row["title"] as? String,
            transcriptState: row["transcript_state"] as? String ?? "unknown"
        )
    }
}
```

Assure-toi que `MeetingListing` (défini dans le Chantier 1) a un champ `title: String?`. Sinon ajoute-le. Adapte les signatures selon l'API réelle de `db.query` / la lib SQLite utilisée (GRDB probablement, vu `Package.swift`) — la syntaxe ci-dessus est indicative.

**Note importante pour GRDB** : les queries paramétrées passent par `Row` avec `row["column"]?.storage`. Adapte les casts aux types GRDB. Cf. `MeetingIndexer.swift` Chantier 1 pour le style local.

- [ ] **Step 4: Run — expect PASS**

Run: `swift test --filter MeetingIndexerRecentTests`

- [ ] **Step 5: Stop (do not commit).**

---

## Task 19: MenuBar "Recent Meetings" submenu + Regenerate

**Files:**
- Modify: `Sources/Onyx/Menu/MenuBarView.swift`

**Contexte :** ajouter, sous "Start recording", une section "Recent Meetings" (5 derniers via `MeetingIndexer.recentMeetings`) avec un sous-menu par meeting : Open folder / Open transcript / Regenerate notes as ▸ (brief|synthese|detaillee).

Pas de test unitaire (SwiftUI menu → non testable en CI hors XCUITest). Validation E2E.

- [ ] **Step 1: Read existing MenuBarView**

Ouvre `Sources/Onyx/Menu/MenuBarView.swift`. Repère la structure existante (probablement un `some View` avec des `Button` + `Divider`).

- [ ] **Step 2: Add Recent Meetings section**

Insère entre le `Button("Start recording")` et le `Button("Settings")` :

```swift
Divider()

// Recent Meetings section
Menu("Recent Meetings") {
    let recents = (try? app.indexer.recentMeetings(limit: 5)) ?? []
    if recents.isEmpty {
        Text("No recordings yet").disabled(true)
    } else {
        ForEach(recents, id: \.slug) { m in
            Menu("\(shortTime(m.startedAt)) — \(m.title ?? "Untitled")") {
                Button("Open folder") {
                    NSWorkspace.shared.open(m.folderPath)
                }
                Button("Open transcript.md") {
                    let tr = m.folderPath.appendingPathComponent("transcript.md")
                    NSWorkspace.shared.open(tr)
                }
                Menu("Regenerate notes as") {
                    ForEach(NoteLevel.allCases, id: \.self) { level in
                        Button(level.rawValue.capitalized) {
                            app.regenerateNotes(for: m.slug, level: level)
                        }
                    }
                }
            }
        }
    }
}
```

Helper à ajouter dans la struct :

```swift
private func shortTime(_ d: Date) -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm"
    return f.string(from: d)
}
```

- [ ] **Step 3: Add `regenerateNotes` to `AppState`**

Dans `Sources/Onyx/AppState.swift`, ajoute :

```swift
public func regenerateNotes(for slug: String, level: NoteLevel) {
    Task {
        let paths = MeetingPaths(root: storage.root, slug: slug)
        guard let binPathStr = settings.claudeBinaryPath.isEmpty ? nil : settings.claudeBinaryPath,
              !binPathStr.isEmpty else {
            lastError = "Claude binary path not configured"
            return
        }
        let binary = URL(fileURLWithPath: binPathStr)
        do {
            let gen = ClaudeNoteGenerator()
            try await gen.generate(paths: paths, level: level, binary: binary)
        } catch {
            lastError = "Regenerate failed: \(String(describing: error))"
            await MainActor.run {
                OptOutNotificationCenter.shared.showNotesFailed(slug: slug)
            }
        }
    }
}
```

- [ ] **Step 4: Compile check**

Run: `swift build -c release --arch arm64`

- [ ] **Step 5: Stop (do not commit).**

---

## Task 20: Settings tabs — Calendar / Detection / Notes / Advanced

**Files:**
- Modify: `Sources/Onyx/Settings/SettingsWindow.swift`

**Contexte :** UI SwiftUI. Pas de test — validation par l'usage.

- [ ] **Step 1: Read existing SettingsWindow**

Note comment le tab "General" est structuré.

- [ ] **Step 2: Add three new tabs**

```swift
TabView {
    generalTab.tabItem { Label("General", systemImage: "gearshape") }
    calendarTab.tabItem { Label("Calendar", systemImage: "calendar") }
    detectionTab.tabItem { Label("Detection", systemImage: "waveform") }
    notesTab.tabItem { Label("Notes", systemImage: "doc.text") }
    advancedTab.tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
}
.frame(width: 520, height: 380)
```

Contenu des nouveaux tabs :

```swift
@ViewBuilder private var calendarTab: some View {
    VStack(alignment: .leading, spacing: 12) {
        Toggle("Enable auto-trigger from calendar",
               isOn: $settings.autoTriggerEnabled)
        Text("Calendars to watch:").font(.headline)
        let calendars = watcher.availableCalendars()
        if calendars.isEmpty {
            Text("Calendar access not granted. Grant in onboarding or System Settings > Privacy > Calendars.").foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(calendars, id: \.calendarIdentifier) { cal in
                        Toggle(cal.title, isOn: Binding(
                            get: { settings.enabledCalendarIds.contains(cal.calendarIdentifier) },
                            set: { on in
                                var s = settings.enabledCalendarIds
                                if on { s.append(cal.calendarIdentifier) }
                                else { s.removeAll { $0 == cal.calendarIdentifier } }
                                settings.enabledCalendarIds = s
                            }
                        ))
                    }
                }
            }.frame(maxHeight: 200)
        }
    }.padding()
}

@ViewBuilder private var detectionTab: some View {
    VStack(alignment: .leading, spacing: 12) {
        Toggle("Detect Google Meet in browser", isOn: $settings.detectionMeetEnabled)
        Toggle("Detect Slack Huddles", isOn: $settings.detectionHuddleEnabled)
        Text("Note: Firefox and Slack web app are not detected.")
            .font(.caption).foregroundStyle(.secondary)
    }.padding()
}

@ViewBuilder private var notesTab: some View {
    VStack(alignment: .leading, spacing: 12) {
        Toggle("Auto-generate notes after recording",
               isOn: $settings.autoNotesEnabled)
        Picker("Default level:", selection: Binding(
            get: { settings.defaultNoteLevel },
            set: { settings.defaultNoteLevel = $0 }
        )) {
            ForEach(NoteLevel.allCases, id: \.self) { l in
                Text(l.rawValue.capitalized).tag(l)
            }
        }.pickerStyle(.segmented)
        HStack {
            Text("Claude binary:")
            TextField("/path/to/claude", text: $settings.claudeBinaryPath)
            Button("Test") { testClaudeBinary() }
        }
        if !lastTestResult.isEmpty {
            Text(lastTestResult).font(.caption).foregroundStyle(.secondary)
        }
    }.padding()
}

@ViewBuilder private var advancedTab: some View {
    VStack(alignment: .leading, spacing: 12) {
        Toggle("Auto-trigger master switch", isOn: $settings.autoTriggerEnabled)
        Button("Reset onboarding") {
            UserDefaults.standard.removeObject(forKey: "onboardingDone")
            UserDefaults.standard.removeObject(forKey: "onboardingV2Done")
        }
    }.padding()
}

@State private var lastTestResult: String = ""

private func testClaudeBinary() {
    let path = settings.claudeBinaryPath
    guard !path.isEmpty else { lastTestResult = "Path is empty."; return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = ["--version"]
    let out = Pipe(); p.standardOutput = out; p.standardError = out
    do {
        try p.run(); p.waitUntilExit()
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lastTestResult = p.terminationStatus == 0
            ? "OK: \(s)"
            : "Exit \(p.terminationStatus): \(s)"
    } catch {
        lastTestResult = "Failed to launch: \(error.localizedDescription)"
    }
}
```

Ajoute une prop `let watcher: CalendarWatcher` (passée depuis `AppState`) à `SettingsWindow`.

- [ ] **Step 3: Wire `SettingsWindow` in App.swift**

Ouvre `Sources/Onyx/App.swift`. Passe `appState.calendarWatcher` au constructor de `SettingsWindow`. (Le champ `calendarWatcher` sera ajouté à `AppState` en Task 21.)

- [ ] **Step 4: Compile check**

Run: `swift build -c release --arch arm64`

- [ ] **Step 5: Stop (do not commit).**

---

## Task 21: AppState wiring — orchestrator + calendar + detection loops

**Files:**
- Modify: `Sources/Onyx/AppState.swift`

**Contexte :** instancier tous les nouveaux composants et connecter leurs streams à l'orchestrator. Lancer les boucles au démarrage seulement si les toggles Settings sont on.

- [ ] **Step 1: Extend `AppState.init` and add loops**

Ouvre `Sources/Onyx/AppState.swift`. Ajoute les properties, remplace l'init et ajoute une méthode `bootAutotrigger()` :

```swift
// Add these stored properties to AppState:
public let calendarWatcher: CalendarWatcher
private let detectionCoordinator: DetectionCoordinator
private let orchestrator: AutoTriggerOrchestrator
private let claudeGen = ClaudeNoteGenerator()

// Also add a helper the notification callback can use:
public func handleOptOut() async {
    try? await orchestrator.optOut()
}
```

Dans `init()` (après le `pipeline = Pipeline(...)`), remplace la construction du Pipeline pour injecter la config notes :

```swift
let binPath = settings.claudeBinaryPath.isEmpty ? nil
    : URL(fileURLWithPath: settings.claudeBinaryPath)
let noteCfg: NoteGenerationConfig? = settings.autoNotesEnabled
    ? NoteGenerationConfig(generator: claudeGen, binary: binPath,
                           level: settings.defaultNoteLevel)
    : nil
pipeline = Pipeline(storage: storage, notes: noteCfg)

calendarWatcher = CalendarWatcher()

var detectors: [any MeetingAppDetector] = []
if settings.detectionMeetEnabled { detectors.append(MeetDetector()) }
if settings.detectionHuddleEnabled { detectors.append(SlackHuddleDetector()) }
detectionCoordinator = DetectionCoordinator(detectors: detectors)

let session = RecorderSession(recorder: recorder, storage: storage, pipeline: pipeline)
orchestrator = AutoTriggerOrchestrator(session: session)

// Wire the opt-out button on notifications.
OptOutNotificationCenter.shared.optOutHandler = { [weak self] in
    guard let self else { return }
    await self.handleOptOut()
}
OptOutNotificationCenter.shared.configureIfNeeded()
```

Puis ajoute `bootAutotrigger()` qui lance les deux boucles :

```swift
public func bootAutotrigger() {
    guard settings.autoTriggerEnabled else { return }

    // Calendar loop
    Task { [orchestrator, calendarWatcher, settings] in
        let matcher = CalendarMatcher(whitelistedCalendarIds: settings.enabledCalendarIds)
        for await match in calendarWatcher.matches(matcher: matcher) {
            OptOutNotificationCenter.shared.showRecordingStarted(title: match.title)
            do { try await orchestrator.onCalendarEvent(match) }
            catch { Log.pipeline.error("orchestrator calendar: \(String(describing: error), privacy: .public)") }
        }
    }

    // Detection loop
    Task { [orchestrator, detectionCoordinator] in
        for await ev in detectionCoordinator.events() {
            if ev.kind == .started {
                OptOutNotificationCenter.shared.showRecordingStarted(title: "Meet/Huddle detected")
            }
            do { try await orchestrator.onCallEvent(ev) }
            catch { Log.pipeline.error("orchestrator call: \(String(describing: error), privacy: .public)") }
        }
    }
}
```

Modifie la méthode existante `toggleRecording` pour déléguer au orchestrator dans le cas manuel :

```swift
public func toggleRecording() {
    Task {
        do {
            switch uiState {
            case .idle:
                try await orchestrator.manualStart()
                uiState = .recording
            case .recording:
                try await orchestrator.manualStop()
                uiState = .idle
            case .transcribing:
                try await orchestrator.manualStart()
                uiState = .recording
            }
        } catch { lastError = String(describing: error); uiState = .idle }
    }
}
```

- [ ] **Step 2: Call `bootAutotrigger()` from `App.swift` onAppear**

Ouvre `Sources/Onyx/App.swift`. Dans le `.onAppear` du `MenuBarExtra` (existant), ajoute :

```swift
.onAppear {
    appState.resumePendingJobs()
    appState.bootAutotrigger()   // NEW
    hotkey.register { Task { @MainActor in appState.toggleRecording() } }
}
```

- [ ] **Step 3: Compile check**

Run: `swift build -c release --arch arm64`
Expected: OK.

- [ ] **Step 4: Stop (do not commit).**

---

## Task 22: Onboarding — Calendar permission + picker

**Files:**
- Create: `Sources/Onyx/Onboarding/CalendarPermissionView.swift`
- Create: `Sources/Onyx/Onboarding/CalendarPickerView.swift`
- Modify: `Sources/Onyx/Onboarding/OnboardingWindow.swift`

- [ ] **Step 1: Create `CalendarPermissionView.swift`**

```swift
// Sources/Onyx/Onboarding/CalendarPermissionView.swift
import SwiftUI
import RecorderCore

struct CalendarPermissionView: View {
    let watcher: CalendarWatcher
    let onDone: (Bool) -> Void
    @State private var status: String = "Onyx needs access to your calendars to auto-start recording."

    var body: some View {
        VStack(spacing: 16) {
            Text("Calendar access").font(.title2).bold()
            Text(status).multilineTextAlignment(.center)
            HStack {
                Button("Skip") { onDone(false) }
                Button("Grant access") {
                    Task {
                        let ok = await watcher.requestAccess()
                        status = ok ? "Granted." : "Denied — can be enabled later in System Settings."
                        onDone(ok)
                    }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(40).frame(width: 460)
    }
}
```

- [ ] **Step 2: Create `CalendarPickerView.swift`**

```swift
// Sources/Onyx/Onboarding/CalendarPickerView.swift
import SwiftUI
import EventKit
import RecorderCore

struct CalendarPickerView: View {
    let watcher: CalendarWatcher
    let settings: SettingsStore
    let onDone: () -> Void

    @State private var selected: Set<String> = []
    @State private var calendars: [EKCalendar] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick calendars to watch").font(.title2).bold()
            Text("Onyx will only auto-record events in the calendars you check.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(calendars, id: \.calendarIdentifier) { cal in
                        Toggle(cal.title, isOn: Binding(
                            get: { selected.contains(cal.calendarIdentifier) },
                            set: { on in
                                if on { selected.insert(cal.calendarIdentifier) }
                                else { selected.remove(cal.calendarIdentifier) }
                            }
                        ))
                    }
                }
            }.frame(maxHeight: 220)
            HStack {
                Spacer()
                Button("Continue") {
                    settings.enabledCalendarIds = Array(selected)
                    onDone()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .frame(width: 460)
        .onAppear {
            calendars = watcher.availableCalendars()
            // Pre-select calendars whose name contains Work/Travail.
            selected = Set(calendars
                .filter { $0.title.range(of: "work", options: .caseInsensitive) != nil
                       || $0.title.range(of: "travail", options: .caseInsensitive) != nil }
                .map(\.calendarIdentifier))
        }
    }
}
```

- [ ] **Step 3: Insert into `OnboardingWindow.swift`**

Ouvre `Sources/Onyx/Onboarding/OnboardingWindow.swift`. Repère la state machine actuelle (probablement un `enum Step { case permissions, models }` ou équivalent). Ajoute deux nouveaux cases `.calendarPermission` et `.calendarPicker` entre `.models` et la fin :

```swift
enum Step {
    case permissions
    case models
    case calendarPermission
    case calendarPicker
    case browserAutomation
    case claudeBinary
    case done
}
```

Et le switch de rendering :

```swift
switch step {
case .permissions: PermissionsView(...) { step = .models }
case .models: ModelDownloadView(...) { step = .calendarPermission }
case .calendarPermission:
    CalendarPermissionView(watcher: app.calendarWatcher) { granted in
        step = granted ? .calendarPicker : .browserAutomation
    }
case .calendarPicker:
    CalendarPickerView(watcher: app.calendarWatcher, settings: app.settings) {
        step = .browserAutomation
    }
case .browserAutomation:
    BrowserAutomationView { step = .claudeBinary }   // Task 23
case .claudeBinary:
    ClaudeBinaryView(settings: app.settings) { step = .done }   // Task 23
case .done: /* close window */ onClose()
}
```

- [ ] **Step 4: Compile check**

Run: `swift build -c release --arch arm64`

- [ ] **Step 5: Stop (do not commit).**

---

## Task 23: Onboarding — Browser automation prompt + Claude binary detection

**Files:**
- Create: `Sources/Onyx/Onboarding/BrowserAutomationView.swift`
- Create: `Sources/Onyx/Onboarding/ClaudeBinaryView.swift`

- [ ] **Step 1: Create `BrowserAutomationView.swift`**

```swift
// Sources/Onyx/Onboarding/BrowserAutomationView.swift
import SwiftUI

struct BrowserAutomationView: View {
    let onDone: () -> Void
    @State private var results: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Browser detection permissions").font(.title2).bold()
            Text("""
                Onyx uses AppleScript to see when a Google Meet tab is open. \
                macOS will show a permission popup for each browser we \
                probe — click OK for the ones you use.
                """).multilineTextAlignment(.leading)
            Button("Probe browsers") { probe() }
            if !results.isEmpty {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(results, id: \.self) { r in
                            Text(r).font(.system(.body, design: .monospaced))
                        }
                    }
                }.frame(maxHeight: 150)
            }
            HStack { Spacer()
                Button("Continue") { onDone() }.keyboardShortcut(.defaultAction)
            }
        }.padding(30).frame(width: 460)
    }

    private func probe() {
        results.removeAll()
        let bundles = ["com.google.Chrome", "com.apple.Safari",
                       "company.thebrowser.Browser", "com.brave.Browser"]
        for b in bundles {
            let script = "tell application id \"\(b)\" to return name"
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            let out = Pipe(); proc.standardOutput = out; proc.standardError = out
            do { try proc.run(); proc.waitUntilExit() }
            catch { results.append("\(b): \(error.localizedDescription)"); continue }
            let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
            let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            results.append("\(b): \(proc.terminationStatus == 0 ? "OK — \(s)" : "denied/not installed")")
        }
    }
}
```

- [ ] **Step 2: Create `ClaudeBinaryView.swift`**

```swift
// Sources/Onyx/Onboarding/ClaudeBinaryView.swift
import SwiftUI

struct ClaudeBinaryView: View {
    let settings: SettingsStore
    let onDone: () -> Void
    @State private var detected: String = ""
    @State private var custom: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Code binary").font(.title2).bold()
            Text("Onyx spawns `claude -p` to generate meeting notes. Locating your installation:")
            Text(detected.isEmpty ? "Searching…" : detected)
                .font(.system(.body, design: .monospaced))
            HStack {
                TextField("Or paste a path…", text: $custom)
                Button("Use") {
                    settings.claudeBinaryPath = custom
                    detected = "Using: \(custom)"
                }
            }
            HStack { Spacer()
                Button("Continue") { onDone() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(30).frame(width: 460)
        .onAppear { detectBinary() }
    }

    private func detectBinary() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [URL] = [
            home.appendingPathComponent(".claude/local/claude"),
            home.appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c.path) {
            detected = "Found: \(c.path)"
            settings.claudeBinaryPath = c.path
            return
        }
        // Fallback: login-shell PATH lookup.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-lc", "which claude"]
        let out = Pipe(); proc.standardOutput = out; proc.standardError = Pipe()
        do { try proc.run(); proc.waitUntilExit() } catch {
            detected = "Claude not found — auto notes disabled. Set manually later in Settings."
            return
        }
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if proc.terminationStatus == 0, !s.isEmpty {
            detected = "Found via shell: \(s)"
            settings.claudeBinaryPath = s
        } else {
            detected = "Claude not found — auto notes disabled. Set manually later in Settings."
        }
    }
}
```

- [ ] **Step 3: Verify onboarding V2 flag persistence**

Dans `OnboardingWindow.swift`, quand `step == .done`, set `UserDefaults.standard.set(true, forKey: "onboardingV2Done")`. Le check dans `App.swift.init` doit tester `onboardingV2Done` en plus de `onboardingDone` :

```swift
if !UserDefaults.standard.bool(forKey: "onboardingV2Done") {
    DispatchQueue.main.async { Self.showOnboarding() }
}
```

Les utilisateurs qui avaient déjà `onboardingDone: true` (Chantier 1) verront donc l'onboarding V2 à leur premier lancement post-update, mais seulement les nouvelles étapes (les anciennes peuvent être skippées si `PermissionsChecker` détecte que tout est déjà accordé — à toi de l'implémenter en early-continue dans `PermissionsView`).

- [ ] **Step 4: Compile check**

Run: `swift build -c release --arch arm64`

- [ ] **Step 5: Stop (do not commit).**

---

## Task 24: Manual end-to-end validation checklist

**Files:**
- Rien à coder — c'est une checklist à cocher par l'utilisateur après build.

Après avoir tout compilé et signé (`./scripts/build-app.sh` + copie Sparkle + rpath + re-sign), lancer l'app fraîchement et exécuter la séquence suivante. Tick chaque case après vérification.

- [ ] **Étape 1 — Onboarding V2**
  - Supprimer les clés defaults : `defaults delete com.yvanbetremieux.onyx onboardingV2Done`.
  - Lancer l'app. L'onboarding V2 s'ouvre à l'étape Calendar permission.
  - Cliquer "Grant access" → popup système Calendar apparaît → accepter → passer au calendar picker.
  - Cocher un calendar de test (ex : "Home"), continuer.
  - Onglet Browser automation : cliquer "Probe browsers" → popups automation pour Chrome/Safari → accepter → chaque ligne devient "OK — <name>".
  - Onglet Claude binary : le champ doit se remplir automatiquement (via detection). Continuer.

- [ ] **Étape 2 — Auto-record calendar**
  - Créer un event dans le calendar coché, titre "Test Chantier 2", début dans 90 secondes, description contenant `https://meet.google.com/aaa-bbbb-ccc`.
  - Attendre. À l'heure de start (±60s), une notif macOS "Recording — Test Chantier 2" doit apparaître, avec bouton "Stop".
  - Vérifier dans `~/Meetings/` : un nouveau dossier avec `meta.json` contenant `"source":"calendar"` et `"title":"Test Chantier 2"`.

- [ ] **Étape 3 — Détection Meet spontané**
  - Ouvrir Chrome, aller sur `https://meet.google.com/new`, créer une réunion.
  - Dans les 5-10 secondes, une notif "Recording — Meet/Huddle detected" doit apparaître.
  - Fermer l'onglet Meet. Après ~3s de debounce, l'enregistrement s'arrête et le pipeline démarre.

- [ ] **Étape 4 — Slack Huddle**
  - Ouvrir Slack.app, démarrer un huddle solo (ou avec un collègue de test).
  - Notif d'auto-start doit apparaître.
  - Quitter le huddle → enregistrement s'arrête.

- [ ] **Étape 5 — Overlap ignoré**
  - Créer un event avec Meet link dans 30s, laisser tourner un enregistrement en cours.
  - À l'heure de l'event, une notif "Event ignored — already recording" apparaît. Aucun deuxième dossier de meeting créé.

- [ ] **Étape 6 — Notes auto**
  - Après un enregistrement terminé, attendre la fin du pipeline (l'icône menu passe d'orange à vert).
  - Vérifier `~/Meetings/<slug>/notes/synthese.md` (ou le niveau default configuré) existe et contient un markdown structuré crédible.

- [ ] **Étape 7 — Régénération manuelle**
  - Ouvrir la barre menu → Recent Meetings → sélectionner un meeting → Regenerate notes as ▸ brief.
  - Après ~30-60s, `~/Meetings/<slug>/notes/brief.md` apparaît avec un contenu ≤150 mots.

- [ ] **Étape 8 — Crash + reprise**
  - Lancer un enregistrement, laisser tourner 30s.
  - `pkill -x Onyx` pendant que l'enregistrement tourne.
  - Relancer l'app. Ouvrir la barre menu → `AppState.resumePendingJobs` doit picker le meeting incomplet, le pipeline s'enchaîne, notes générées.

- [ ] **Étape 9 — Claude binary absent**
  - Renommer temporairement `~/.claude/local/claude` (ou le chemin actuel).
  - Faire un enregistrement.
  - Le pipeline complet passe jusqu'à `.notes` → notif "Notes generation failed for <slug>".
  - `transcript.md` existe. `notes/*.md` n'existe pas. `job.state == .done`, `job.steps.notes.status == "failed"`.
  - Restaurer le binaire, "Regenerate notes as synthese" depuis le menu → note apparaît.

- [ ] **Étape 10 — Safety cap 3h**
  - Optionnel / difficile à tester en direct. Vérifier plutôt par un test unitaire ou log-inspection sur un long enregistrement.

Chaque étape doit passer avant considération du Chantier 2 comme livrable.

---

## Self-review notes

**Spec coverage recap :**

| Section spec | Task(s) qui l'implémentent |
|---|---|
| §4 CalendarWatcher | Task 13, 14 |
| §5 Detection (Meet, Huddle, Coordinator) | Task 9, 10, 11, 12 |
| §6 AutoTriggerOrchestrator + state machine + opt-out notif | Task 15, 16, 17, 21 |
| §7 ClaudeNoteGenerator + prompts + step .notes + regénération UI | Task 5, 6, 7, 19 |
| §8 MeetingMetadata / JobState / MeetingPaths / filesystem layout | Task 1, 2, 3 |
| §9 Settings (fields + UI) / MenuBar / Onboarding | Task 8, 19, 20, 22, 23 |
| §10 Recorder.cancel + Pipeline .notes + AppState wiring + MeetingIndexer.recentMeetings | Task 4, 7, 17, 18, 21 |
| §11 Non-fonctionnels (perf, permissions, offline, safety) | Traité au fil des Task ; safety cap = orchestrator timer optionnel (à ajouter si Étape 10 le nécessite) |
| §12 Tests | Tests intégrés dans Tasks 1-15 |
| §13 Décisions ouvertes | Explicitement hors périmètre v1 |

Un point non fully implementé : le **safety cap 3h** du §6 de la spec. Il peut être ajouté au `AutoTriggerOrchestrator` via un `Task.detached { try? await Task.sleep(3h); if state == .recording { manualStop() } }` armé dans `start`, mais je le laisse en amendement post-Task 15 seulement si l'Étape 10 de la checklist E2E révèle le besoin en pratique.

