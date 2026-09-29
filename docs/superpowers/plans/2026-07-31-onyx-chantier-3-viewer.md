# Onyx Chantier 3 — Viewer SwiftUI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Note on commits:** The user handles git commits themselves. Do NOT run `git commit` / `git add` / `git push` at the end of tasks. Stage-and-review is fine; the user will commit at their own cadence.

**Goal:** Livrer la fenêtre SwiftUI viewer d'Onyx (chantier 3) : browse/search/édition des meetings + notes en direct pendant l'enregistrement injectées dans le prompt Claude.

**Architecture:** Nouvelle fenêtre indépendante dans le target `Onyx` sous `Sources/Onyx/Viewer/`, layout 3-panneaux (sidebar meetings · notes centrales · transcript de côté), consomme les APIs existantes de `RecorderCore` + 2 nouvelles (search FTS avec timestamps, listAllGrouped). Le pipeline chantier 1/2 est enrichi de deux extensions purement additives : un fichier `notes/live.md` créé à `Recorder.start()` et injecté dans le prompt Claude, une `waveform.json` pré-calculée au step `.render`.

**Tech Stack:** Swift 5.9 / macOS 13+, SwiftUI + AppKit hybrid (NSWindow custom + SwiftUI views), GRDB (SQLite FTS5), AVFoundation (AVAudioPlayer), NSVisualEffectView (translucence sidebar), CoreText metrics pour la waveform.

**Spec de référence :** `docs/superpowers/specs/2026-07-31-onyx-chantier-3-viewer-design.md`
**Mockup de référence :** `docs/superpowers/mockups/chantier-3/viewer.html`

---

## File Structure

### Nouveaux fichiers dans `Sources/RecorderCore/`

```
Index/
  SearchHit.swift                  (struct + AttributedString snippet)
Waveform/
  WaveformGenerator.swift          (peaks RMS depuis WAV)
  WaveformFile.swift               (Codable [Float] + read/write)
```

Note : les migrations v2/v3 se font **dans** `IndexSchema.swift` existant (pas de fichier séparé).

### Nouveaux fichiers dans `Sources/Onyx/Viewer/`

```
ViewerWindowController.swift       (NSWindowController + NSHostingView, single instance)
ViewerStore.swift                  (@Observable state root)
ViewerRootView.swift               (composition SwiftUI 3-panneaux)
Persistence/
  ViewerState.swift                (Codable snapshot disk)
  ViewerStatePersistence.swift     (load/save avec debounce)
Sidebar/
  MeetingsSidebar.swift            (sidebar racine, switch browse↔search)
  MeetingRow.swift                 (ligne meeting)
  DateGroupSection.swift           (header groupe + rows)
  SearchField.swift                (input + kbd shortcut ⌘K)
  SearchResultsList.swift          (résultats FTS)
  SearchResultRow.swift            (snippet highlighted)
  MeetingGroups.swift              (helper : bucketize par date)
  SourceBadge.swift                (Manual/Cal/Meet/Huddle)
Main/
  MainPanel.swift                  (header + split notes/transcript + audio bar)
  MeetingHeaderView.swift          (titre, participants, actions)
  AvatarStack.swift                (avatars empilés)
  ResizableSplit.swift             (divider draggable, min widths)
  NotesPanel.swift                 (4 tabs, editor, banner régénération)
  NotesEditor.swift                (TextView Markdown-aware)
  RegenerateWarningBanner.swift    (banner ocre)
  TranscriptPanel.swift            (header + LazyVStack turns)
  TurnView.swift                   (timestamp, speaker chip, body éditable)
  ShowPanelFAB.swift               (bouton ré-affichage transcript)
  (EmptyStateView est définie inline dans MainPanel.swift)
Audio/
  AudioPlayer.swift                (wrapper AVAudioPlayer + published time)
  AudioScrubberBar.swift           (play, waveform, time, speed)
  WaveformView.swift               (Canvas dessin barres)
```

### Modifications existantes ciblées

- `Sources/RecorderCore/Support/MeetingPaths.swift` — accesseur `liveNotes`, `waveformJson`.
- `Sources/RecorderCore/Storage/MeetingStorage.swift` — création `notes/` + `live.md` vide dans `createMeeting()`.
- `Package.swift` — ajout du test target `OnyxTests` (dépend du target exécutable `Onyx`).
- `Sources/RecorderCore/Notes/NotePromptTemplates.swift` — paramètre `liveNotes: String?` optionnel.
- `Sources/RecorderCore/Notes/ClaudeNoteGenerator.swift` — lecture `live.md`, injection dans le prompt.
- `Sources/RecorderCore/Index/IndexSchema.swift` — bump version + migration v2.
- `Sources/RecorderCore/Index/MeetingIndexer.swift` — `search(_:limit:)`, `listAllGrouped()`, upsert avec `start_ms`.
- `Sources/RecorderCore/Pipeline/Pipeline.swift` — writes `waveform.json` au step `.render`.
- `Sources/RecorderCore/Index/RescanRunner.swift` — regen live-note-absent + start_ms.
- `Sources/Onyx/App.swift` — enregistre `ViewerWindowController` singleton.
- `Sources/Onyx/AppState.swift` — accès partagé au controller viewer.
- `Sources/Onyx/Menu/MenuBarView.swift` — entrée "Open viewer… ⌘⇧V" + "Open live notes ⌘⇧L".

### Nouveaux fichiers de tests

```
Tests/RecorderCoreTests/
  MeetingPathsLiveNotesTests.swift
  RecorderLiveNotesCreationTests.swift
  NotePromptTemplatesLiveNotesTests.swift
  ClaudeNoteGeneratorLiveInjectionTests.swift
  IndexSchemaMigrationV2Tests.swift
  MeetingIndexerSearchTests.swift
  MeetingIndexerListAllGroupedTests.swift
  WaveformGeneratorTests.swift
  WaveformFileTests.swift
  PipelineWaveformStepTests.swift
Tests/OnyxTests/                   (nouveau test target — ajouté à Package.swift en Task 11)
  MeetingGroupsTests.swift
  ViewerStateTests.swift
  ViewerStorePersistenceTests.swift
  RegenerateWarningStateTests.swift
```

---

## Phase 1 — Backend additions (RecorderCore)

Ces 10 tâches ajoutent tout ce dont le viewer aura besoin côté modèle et pipeline, sans toucher à l'UI. Elles sont indépendantes du viewer et peuvent être livrées d'un bloc.

### Task 1: `MeetingPaths.liveNotes` + `waveformJson`

**Files:**
- Modify: `Sources/RecorderCore/Support/MeetingPaths.swift`
- Test: `Tests/RecorderCoreTests/MeetingPathsLiveNotesTests.swift` (new)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/RecorderCoreTests/MeetingPathsLiveNotesTests.swift
import XCTest
@testable import RecorderCore

final class MeetingPathsLiveNotesTests: XCTestCase {
    func test_liveNotes_isNotesDirLiveMd() {
        let root = URL(fileURLWithPath: "/tmp/onyx-test")
        let paths = MeetingPaths(root: root, slug: "2026-07-31_15h10")
        XCTAssertEqual(paths.liveNotes.lastPathComponent, "live.md")
        XCTAssertEqual(paths.liveNotes.deletingLastPathComponent().lastPathComponent, "notes")
    }

    func test_waveformJson_isAudioDirWaveformJson() {
        let root = URL(fileURLWithPath: "/tmp/onyx-test")
        let paths = MeetingPaths(root: root, slug: "2026-07-31_15h10")
        XCTAssertEqual(paths.waveformJson.lastPathComponent, "waveform.json")
        XCTAssertEqual(paths.waveformJson.deletingLastPathComponent().lastPathComponent, "audio")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MeetingPathsLiveNotesTests`
Expected: FAIL — `paths.liveNotes` and `paths.waveformJson` unresolved.

- [ ] **Step 3: Add accessors**

Modify `Sources/RecorderCore/Support/MeetingPaths.swift`. Append to the existing `extension MeetingPaths` block at the bottom:

```swift
public extension MeetingPaths {
    /// User-editable live notes taken during the meeting. Created empty at
    /// `Recorder.start()`, never overwritten by regeneration, injected into
    /// the Claude prompt during the `.notes` pipeline step.
    var liveNotes: URL { notesDir.appendingPathComponent("live.md") }

    /// Pre-computed waveform peaks (Codable `[Float]`) written at the pipeline
    /// `.render` step. Falls back to on-the-fly generation in the viewer if
    /// absent (meetings from before chantier 3).
    var waveformJson: URL { audio.appendingPathComponent("waveform.json") }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MeetingPathsLiveNotesTests`
Expected: PASS.

- [ ] **Step 5: Stage for user review**

```bash
git add Sources/RecorderCore/Support/MeetingPaths.swift \
        Tests/RecorderCoreTests/MeetingPathsLiveNotesTests.swift
git status
```

---

### Task 2: `MeetingStorage.createMeeting()` creates empty `live.md`

**Files:**
- Modify: `Sources/RecorderCore/Storage/MeetingStorage.swift:14-30`
- Test: `Tests/RecorderCoreTests/RecorderLiveNotesCreationTests.swift` (new)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/RecorderCoreTests/RecorderLiveNotesCreationTests.swift
import XCTest
@testable import RecorderCore

@available(macOS 13.0, *)
final class RecorderLiveNotesCreationTests: XCTestCase {
    var tmpRoot: URL!

    override func setUp() {
        super.setUp()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpRoot)
        super.tearDown()
    }

    func test_createMeeting_writesEmptyLiveNotesFile() throws {
        let storage = MeetingStorage(root: tmpRoot)
        let paths = try storage.createMeeting(startedAt: Date())
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.liveNotes.path),
                      "live.md should be created at meeting start")
        let content = try String(contentsOf: paths.liveNotes)
        XCTAssertEqual(content, "", "live.md must be created empty")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RecorderLiveNotesCreationTests`
Expected: FAIL — file does not exist.

- [ ] **Step 3: Modify `MeetingStorage.createMeeting`**

The file creation is more naturally placed in `MeetingStorage.createMeeting` (which already creates the `audio` and `transcripts` subdirs) than in `Recorder.start`. Modify `Sources/RecorderCore/Storage/MeetingStorage.swift`, in `createMeeting`, right after the existing `try fileManager.createDirectory(at: paths.transcripts, ...)`:

```swift
        // Create notes/ dir + empty live.md immediately so the viewer can let
        // the user type notes during the meeting. Never overwritten by the
        // pipeline; injected into the Claude prompt at generation time.
        try fileManager.createDirectory(at: paths.notesDir, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: paths.liveNotes.path) {
            try Data().write(to: paths.liveNotes, options: .atomic)
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter RecorderLiveNotesCreationTests`
Expected: PASS.

- [ ] **Step 5: Verify no existing tests broke**

Run: `swift test --filter RecorderCoreTests`
Expected: All previous tests still pass (the change is additive).

- [ ] **Step 6: Stage for user review**

```bash
git add Sources/RecorderCore/Storage/MeetingStorage.swift \
        Tests/RecorderCoreTests/RecorderLiveNotesCreationTests.swift
git status
```

---

### Task 3: `NotePromptTemplates.prompt(for:transcript:liveNotes:)`

**Files:**
- Modify: `Sources/RecorderCore/Notes/NotePromptTemplates.swift`
- Test: `Tests/RecorderCoreTests/NotePromptTemplatesLiveNotesTests.swift` (new)

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/RecorderCoreTests/NotePromptTemplatesLiveNotesTests.swift
import XCTest
@testable import RecorderCore

final class NotePromptTemplatesLiveNotesTests: XCTestCase {
    func test_nilLiveNotes_promptUnchangedFromChantier2() {
        let p = NotePromptTemplates.prompt(
            for: .synthese, transcript: "MOI: hello", liveNotes: nil
        )
        XCTAssertFalse(p.contains("Notes prises par l'utilisateur"),
                       "no live-notes block when liveNotes is nil")
        XCTAssertTrue(p.contains("Transcript :"))
        XCTAssertTrue(p.contains("MOI: hello"))
    }

    func test_emptyLiveNotes_treatedAsNil() {
        let p1 = NotePromptTemplates.prompt(for: .brief, transcript: "x", liveNotes: "")
        let p2 = NotePromptTemplates.prompt(for: .brief, transcript: "x", liveNotes: "   \n  ")
        XCTAssertFalse(p1.contains("Notes prises par l'utilisateur"))
        XCTAssertFalse(p2.contains("Notes prises par l'utilisateur"))
    }

    func test_liveNotesPresent_blockInjectedBeforeTranscript() {
        let p = NotePromptTemplates.prompt(
            for: .synthese,
            transcript: "MOI: transcript body",
            liveNotes: "- decision X\n- action Y"
        )
        XCTAssertTrue(p.contains("Notes prises par l'utilisateur en direct pendant le meeting"))
        XCTAssertTrue(p.contains("- decision X"))
        XCTAssertTrue(p.contains("- action Y"))
        // The live block must appear before the transcript block.
        let iLive = p.range(of: "Notes prises par l'utilisateur")!.lowerBound
        let iTr   = p.range(of: "Transcript :")!.lowerBound
        XCTAssertLessThan(iLive, iTr)
    }

    func test_liveNotesInstruction_mentionsIntegration() {
        let p = NotePromptTemplates.prompt(
            for: .synthese, transcript: "x", liveNotes: "note"
        )
        XCTAssertTrue(p.lowercased().contains("intègre"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter NotePromptTemplatesLiveNotesTests`
Expected: FAIL — `prompt(for:transcript:liveNotes:)` overload missing.

- [ ] **Step 3: Add the new overload**

Replace the whole body of `Sources/RecorderCore/Notes/NotePromptTemplates.swift`:

```swift
import Foundation

public enum NotePromptTemplates {
    /// Backward-compatible signature (chantier 2 call sites unchanged).
    public static func prompt(for level: NoteLevel, transcript: String) -> String {
        return prompt(for: level, transcript: transcript, liveNotes: nil)
    }

    /// New signature with optional live notes injection (chantier 3).
    /// - Parameter liveNotes: content of `notes/live.md` if non-empty. When nil
    ///   or blank, the prompt is identical to the chantier-2 output.
    public static func prompt(for level: NoteLevel,
                              transcript: String,
                              liveNotes: String?) -> String {
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

        let trimmedLive = liveNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let liveBlock: String
        if trimmedLive.isEmpty {
            liveBlock = ""
        } else {
            liveBlock = """

            Notes prises par l'utilisateur en direct pendant le meeting :
            ---
            \(trimmedLive)
            ---

            Ces notes reflètent ce que l'utilisateur a jugé important sur le \
            moment. Intègre-les dans ta synthèse : reprends les points, décisions \
            et actions qu'il a notées, corrige-les si le transcript les \
            contredit, et complète avec ce qui manque. Ne les recopie pas mot \
            pour mot, restructure-les proprement dans la sortie demandée.

            """
        }

        return """
        Tu es un preneur de notes de meeting. Tu reçois la transcription d'un \
        meeting avec speakers identifiés :
        - "MOI" = moi-même (l'utilisateur d'Onyx)
        - "SPEAKER_N" = autres intervenants (N = 0, 1, 2, ...)

        Génère les notes en français, format Markdown.

        \(instructions)
        \(liveBlock)
        Transcript :
        \(transcript)
        """
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter NotePromptTemplatesLiveNotesTests`
Expected: PASS.

- [ ] **Step 5: Verify existing chantier 2 tests still pass**

Run: `swift test --filter NotePromptTemplatesTests`
Expected: PASS (backward-compat overload preserves them).

- [ ] **Step 6: Stage for user review**

```bash
git add Sources/RecorderCore/Notes/NotePromptTemplates.swift \
        Tests/RecorderCoreTests/NotePromptTemplatesLiveNotesTests.swift
git status
```

---

### Task 4: `ClaudeNoteGenerator` reads `live.md` and injects

**Files:**
- Modify: `Sources/RecorderCore/Notes/ClaudeNoteGenerator.swift:17-35`
- Test: `Tests/RecorderCoreTests/ClaudeNoteGeneratorLiveInjectionTests.swift` (new)

- [ ] **Step 1: Write the failing test**

The test uses a stub `runClaude` closure by extracting the prompt-building code into a testable path. Simpler alternative: swap `binary` for a shell script that echoes stdin to stdout so we can inspect what was piped in. Use the shell-script approach — it exercises the real subprocess plumbing.

```swift
// Tests/RecorderCoreTests/ClaudeNoteGeneratorLiveInjectionTests.swift
import XCTest
@testable import RecorderCore

final class ClaudeNoteGeneratorLiveInjectionTests: XCTestCase {
    var tmp: URL!
    var echoBinary: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // Fake "claude" binary: echoes stdin to stdout.
        echoBinary = tmp.appendingPathComponent("fake-claude.sh")
        try? "#!/bin/sh\ncat\n".write(to: echoBinary, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: echoBinary.path)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    private func makePaths() throws -> MeetingPaths {
        let storage = MeetingStorage(root: tmp.appendingPathComponent("Meetings"))
        let p = try storage.createMeeting(startedAt: Date())
        try "MOI: transcript body".write(to: p.transcriptMd, atomically: true, encoding: .utf8)
        return p
    }

    func test_emptyLiveNotes_promptExcludesLiveBlock() async throws {
        let paths = try makePaths()
        // live.md is created empty by MeetingStorage.createMeeting (Task 2).
        let gen = ClaudeNoteGenerator()
        try await gen.generate(paths: paths, level: .synthese, binary: echoBinary)
        let out = try String(contentsOf: paths.notesFile(.synthese))
        XCTAssertFalse(out.contains("Notes prises par l'utilisateur"),
                       "no live block when live.md is empty")
    }

    func test_populatedLiveNotes_promptIncludesThem() async throws {
        let paths = try makePaths()
        try "- decision X\n- action Y".write(to: paths.liveNotes,
                                             atomically: true, encoding: .utf8)
        let gen = ClaudeNoteGenerator()
        try await gen.generate(paths: paths, level: .synthese, binary: echoBinary)
        let out = try String(contentsOf: paths.notesFile(.synthese))
        XCTAssertTrue(out.contains("Notes prises par l'utilisateur"))
        XCTAssertTrue(out.contains("- decision X"))
        XCTAssertTrue(out.contains("- action Y"))
    }

    func test_missingLiveFile_isSilentlyTreatedAsEmpty() async throws {
        let paths = try makePaths()
        try FileManager.default.removeItem(at: paths.liveNotes)
        let gen = ClaudeNoteGenerator()
        try await gen.generate(paths: paths, level: .brief, binary: echoBinary)
        // Should not throw, and prompt should not contain the live block.
        let out = try String(contentsOf: paths.notesFile(.brief))
        XCTAssertFalse(out.contains("Notes prises par l'utilisateur"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ClaudeNoteGeneratorLiveInjectionTests`
Expected: FAIL — the current `generate` doesn't read `live.md`.

- [ ] **Step 3: Wire `live.md` reading into `generate`**

Replace the body of `Sources/RecorderCore/Notes/ClaudeNoteGenerator.swift`, function `generate(paths:level:binary:)`:

```swift
    public func generate(paths: MeetingPaths,
                         level: NoteLevel,
                         binary: URL) async throws {
        guard FileManager.default.fileExists(atPath: paths.transcriptMd.path) else {
            throw GenerationError.transcriptMissing
        }
        let transcript = try String(contentsOf: paths.transcriptMd, encoding: .utf8)

        // Live notes: optional, may be missing (pre-chantier-3 meetings) or empty.
        let live: String? = {
            guard FileManager.default.fileExists(atPath: paths.liveNotes.path),
                  let raw = try? String(contentsOf: paths.liveNotes, encoding: .utf8) else {
                return nil
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()

        let prompt = NotePromptTemplates.prompt(
            for: level, transcript: transcript, liveNotes: live
        )

        try FileManager.default.createDirectory(at: paths.notesDir,
                                                withIntermediateDirectories: true)

        let output = try await runClaude(binary: binary,
                                         cwd: paths.root,
                                         stdin: prompt)
        guard !output.isEmpty else { throw GenerationError.emptyOutput }
        try output.data(using: .utf8)!.write(to: paths.notesFile(level),
                                             options: .atomic)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ClaudeNoteGeneratorLiveInjectionTests`
Expected: PASS.

- [ ] **Step 5: Verify all chantier 2 note tests still pass**

Run: `swift test --filter ClaudeNoteGeneratorTests`
Expected: PASS.

- [ ] **Step 6: Stage for user review**

```bash
git add Sources/RecorderCore/Notes/ClaudeNoteGenerator.swift \
        Tests/RecorderCoreTests/ClaudeNoteGeneratorLiveInjectionTests.swift
git status
```

---

### Task 5: `IndexSchema` v2 migration (add `start_ms` to FTS)

**Files:**
- Modify: `Sources/RecorderCore/Index/IndexSchema.swift`
- Test: `Tests/RecorderCoreTests/IndexSchemaMigrationV2Tests.swift` (new)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/RecorderCoreTests/IndexSchemaMigrationV2Tests.swift
import XCTest
import GRDB
@testable import RecorderCore

final class IndexSchemaMigrationV2Tests: XCTestCase {
    var dbPath: URL!

    override func setUp() {
        super.setUp()
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-idx-\(UUID().uuidString).sqlite")
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: dbPath)
        super.tearDown()
    }

    func test_v2_addsStartMsColumnToFts() throws {
        let writer = try DatabasePool(path: dbPath.path)
        try IndexSchema.migrator().migrate(writer)
        try writer.read { db in
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(transcripts_fts)")
                .compactMap { $0["name"] as String? }
            XCTAssertTrue(cols.contains("start_ms"),
                          "FTS table should have start_ms column after v2 migration")
        }
    }

    func test_v2_resetsIndexedAtToNullOnExistingMeetings() throws {
        // Simulate a pre-v2 DB by running only v1 first.
        let writer = try DatabasePool(path: dbPath.path)
        var v1Only = DatabaseMigrator()
        v1Only.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE meetings (
                    id TEXT PRIMARY KEY, path TEXT NOT NULL, started_at TEXT NOT NULL,
                    duration_seconds INTEGER, title TEXT, transcript_state TEXT,
                    indexed_at TEXT
                )""")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE transcripts_fts USING fts5(meeting_id, speaker, text)
                """)
        }
        try v1Only.migrate(writer)
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO meetings(id, path, started_at, indexed_at)
                VALUES ('m1', '/tmp', '2026-01-01T00:00:00Z', '2026-01-02T00:00:00Z')
                """)
        }
        // Now apply v2 on top.
        try IndexSchema.migrator().migrate(writer)
        let val = try writer.read { db in
            try String.fetchOne(db, sql: "SELECT indexed_at FROM meetings WHERE id='m1'")
        }
        XCTAssertNil(val ?? nil, "indexed_at should be NULL to trigger rescan")
    }

    // NOTE: this assertion is updated to `3` by Task 20 (v3 migration adds
    // the `source` column). At Task-5 time the expected value is 2.
    func test_currentVersion_is2() {
        XCTAssertEqual(IndexSchema.currentVersion, 2)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter IndexSchemaMigrationV2Tests`
Expected: FAIL — current version is 1, no `start_ms` column, no v2 migration.

- [ ] **Step 3: Add v2 migration**

Replace `Sources/RecorderCore/Index/IndexSchema.swift`:

```swift
import Foundation
import GRDB

public enum IndexSchema {
    public static let currentVersion = 2

    public static func migrator() -> DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS meetings (
                    id                TEXT PRIMARY KEY,
                    path              TEXT NOT NULL,
                    started_at        TEXT NOT NULL,
                    duration_seconds  INTEGER,
                    title             TEXT,
                    transcript_state  TEXT,
                    indexed_at        TEXT
                )
            """)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS transcripts_fts USING fts5(
                    meeting_id, speaker, text
                )
            """)
        }
        m.registerMigration("v2_fts_start_ms") { db in
            // FTS5 doesn't support ALTER TABLE ADD COLUMN. Drop + recreate,
            // then null out indexed_at so RescanRunner repopulates on next boot.
            try db.execute(sql: "DROP TABLE IF EXISTS transcripts_fts")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE transcripts_fts USING fts5(
                    meeting_id, speaker, text, start_ms UNINDEXED
                )
            """)
            try db.execute(sql: "UPDATE meetings SET indexed_at = NULL")
        }
        return m
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter IndexSchemaMigrationV2Tests`
Expected: PASS.

- [ ] **Step 5: Stage for user review**

```bash
git add Sources/RecorderCore/Index/IndexSchema.swift \
        Tests/RecorderCoreTests/IndexSchemaMigrationV2Tests.swift
git status
```

---

### Task 6: `MeetingIndexer.upsert` writes `start_ms`

**Files:**
- Modify: `Sources/RecorderCore/Index/MeetingIndexer.swift:32-60`
- Test: extension of `MeetingIndexerRecentTests` or a small new file — use `Tests/RecorderCoreTests/MeetingIndexerStartMsTests.swift` (new)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/RecorderCoreTests/MeetingIndexerStartMsTests.swift
import XCTest
import GRDB
@testable import RecorderCore

final class MeetingIndexerStartMsTests: XCTestCase {
    var dbPath: URL!
    override func setUp() {
        super.setUp()
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-idx-\(UUID().uuidString).sqlite")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dbPath); super.tearDown() }

    func test_upsert_populatesStartMs() throws {
        let indexer = try MeetingIndexer(dbPath: dbPath)
        let meta = MeetingMetadata(
            id: "m1", startedAt: Date(), endedAt: nil, durationSeconds: 60,
            title: "Test", source: .manual, appVersion: "0.1.0",
            models: .init(whisper: "w", diarization: "d")
        )
        let seg = TranscriptSegment(start: 12.345, end: 15.0, speaker: "MOI",
                                    text: "hello world", confidence: 0.9)
        try indexer.upsert(meta: meta, folderPath: URL(fileURLWithPath: "/tmp"),
                           transcriptState: "done", transcript: [seg])

        let rows = try indexer.reader.read { db in
            try Row.fetchAll(db,
                sql: "SELECT start_ms, text FROM transcripts_fts WHERE meeting_id = 'm1'")
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["start_ms"] as Int?, 12345)
        XCTAssertEqual(rows[0]["text"] as String?, "hello world")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MeetingIndexerStartMsTests`
Expected: FAIL — `upsert` doesn't insert `start_ms`.

- [ ] **Step 3: Update `upsert` to write `start_ms`**

In `Sources/RecorderCore/Index/MeetingIndexer.swift`, replace the FTS insert loop inside `upsert`:

```swift
            for seg in transcript {
                try db.execute(sql: """
                    INSERT INTO transcripts_fts (meeting_id, speaker, text, start_ms)
                    VALUES (?, ?, ?, ?)
                    """,
                    arguments: [meta.id, seg.speaker, seg.text,
                                Int((seg.start * 1000.0).rounded())])
            }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MeetingIndexerStartMsTests`
Expected: PASS.

- [ ] **Step 5: Run all indexer tests**

Run: `swift test --filter MeetingIndexer`
Expected: All pass.

- [ ] **Step 6: Stage for user review**

```bash
git add Sources/RecorderCore/Index/MeetingIndexer.swift \
        Tests/RecorderCoreTests/MeetingIndexerStartMsTests.swift
git status
```

---

### Task 7: `SearchHit` model + `MeetingIndexer.search`

**Files:**
- Create: `Sources/RecorderCore/Index/SearchHit.swift`
- Modify: `Sources/RecorderCore/Index/MeetingIndexer.swift`
- Test: `Tests/RecorderCoreTests/MeetingIndexerSearchTests.swift` (new)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/RecorderCoreTests/MeetingIndexerSearchTests.swift
import XCTest
@testable import RecorderCore

final class MeetingIndexerSearchTests: XCTestCase {
    var dbPath: URL!
    var indexer: MeetingIndexer!

    override func setUp() {
        super.setUp()
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-idx-\(UUID().uuidString).sqlite")
        indexer = try! MeetingIndexer(dbPath: dbPath)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dbPath); super.tearDown() }

    private func upsert(id: String, title: String, startedAt: Date,
                        segments: [TranscriptSegment]) throws {
        let meta = MeetingMetadata(
            id: id, startedAt: startedAt, endedAt: nil, durationSeconds: nil,
            title: title, source: .manual, appVersion: "0.1.0",
            models: .init(whisper: "w", diarization: "d"))
        try indexer.upsert(meta: meta, folderPath: URL(fileURLWithPath: "/tmp/\(id)"),
                           transcriptState: "done", transcript: segments)
    }

    func test_search_returnsHitsWithTitleAndStart() throws {
        try upsert(id: "m1", title: "Debug pipeline",
                   startedAt: Date(timeIntervalSince1970: 100),
                   segments: [
                     TranscriptSegment(start: 3.5, end: 5.0, speaker: "MOI",
                                       text: "whisper hangs on first run",
                                       confidence: 0.9)
                   ])
        let hits = try indexer.search("whisper", limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].meetingId, "m1")
        XCTAssertEqual(hits[0].title, "Debug pipeline")
        XCTAssertEqual(hits[0].speaker, "MOI")
        let ts = try XCTUnwrap(hits[0].approximateTimestamp)
        XCTAssertEqual(ts, 3.5, accuracy: 0.01)
    }

    func test_search_snippetContainsHighlightMarker() throws {
        try upsert(id: "m1", title: "T",
                   startedAt: Date(),
                   segments: [
                     TranscriptSegment(start: 0, end: 1, speaker: "MOI",
                                       text: "the whisper transcriber hangs",
                                       confidence: 1)
                   ])
        let hits = try indexer.search("whisper", limit: 10)
        let plain = String(hits[0].snippet.characters)
        XCTAssertTrue(plain.lowercased().contains("whisper"),
                      "snippet should contain the matched term")
        // AttributedString: at least one run with background color set.
        var sawHighlight = false
        for run in hits[0].snippet.runs where run.backgroundColor != nil {
            sawHighlight = true
        }
        XCTAssertTrue(sawHighlight, "snippet should have highlighted runs")
    }

    func test_search_emptyQueryReturnsEmpty() throws {
        try upsert(id: "m1", title: "T", startedAt: Date(),
                   segments: [TranscriptSegment(start: 0, end: 1, speaker: "MOI",
                                                text: "hello", confidence: 1)])
        XCTAssertEqual(try indexer.search("", limit: 10).count, 0)
        XCTAssertEqual(try indexer.search("   ", limit: 10).count, 0)
    }

    func test_search_specialCharsAreEscaped() throws {
        try upsert(id: "m1", title: "T", startedAt: Date(),
                   segments: [TranscriptSegment(start: 0, end: 1, speaker: "MOI",
                                                text: "quote'apostrophe",
                                                confidence: 1)])
        // Must not throw; matches on tokenized "quote" or "apostrophe".
        _ = try indexer.search("quote", limit: 10)
        _ = try indexer.search("quote'apostrophe", limit: 10)
    }
}
```

- [ ] **Step 2: Create `SearchHit`**

Create `Sources/RecorderCore/Index/SearchHit.swift`:

```swift
import Foundation

public struct SearchHit: Equatable, Sendable {
    public let meetingId: String
    public let title: String?
    public let startedAt: Date
    public let speaker: String
    public let snippet: AttributedString
    public let approximateTimestamp: TimeInterval?

    public init(meetingId: String, title: String?, startedAt: Date,
                speaker: String, snippet: AttributedString,
                approximateTimestamp: TimeInterval?) {
        self.meetingId = meetingId
        self.title = title
        self.startedAt = startedAt
        self.speaker = speaker
        self.snippet = snippet
        self.approximateTimestamp = approximateTimestamp
    }
}
```

- [ ] **Step 3: Add `search` on `MeetingIndexer`**

Append inside the `MeetingIndexer` class in `Sources/RecorderCore/Index/MeetingIndexer.swift`:

```swift
    public func search(_ rawQuery: String, limit: Int = 100) throws -> [SearchHit] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Escape query for FTS5 MATCH: wrap in quotes and double any inner quotes.
        // Simpler + safer than trying to parse FTS operator syntax for a user field.
        let escaped = "\"" + trimmed.replacingOccurrences(of: "\"", with: "\"\"") + "\""

        return try reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                  f.meeting_id  AS mid,
                  f.speaker     AS speaker,
                  f.start_ms    AS start_ms,
                  snippet(transcripts_fts, 2, '<<<', '>>>', '…', 12) AS snip,
                  m.title       AS title,
                  m.started_at  AS started_at
                FROM transcripts_fts AS f
                JOIN meetings AS m ON m.id = f.meeting_id
                WHERE transcripts_fts MATCH ?
                ORDER BY rank
                LIMIT ?
                """, arguments: [escaped, limit])
            let iso = ISO8601DateFormatter()
            return rows.compactMap { row -> SearchHit? in
                let mid: String   = row["mid"]
                let speaker: String = row["speaker"] ?? ""
                let startMs: Int? = row["start_ms"]
                let snip: String  = row["snip"] ?? ""
                let title: String? = row["title"]
                let startedAtStr: String = row["started_at"] ?? ""
                let startedAt = iso.date(from: startedAtStr) ?? Date(timeIntervalSince1970: 0)
                return SearchHit(
                    meetingId: mid,
                    title: title,
                    startedAt: startedAt,
                    speaker: speaker,
                    snippet: Self.parseHighlightedSnippet(snip),
                    approximateTimestamp: startMs.map { Double($0) / 1000.0 }
                )
            }
        }
    }

    /// Parses `snippet(...)` output where matched terms are wrapped in
    /// `<<<...>>>` (chosen because they won't collide with real transcript
    /// content) into an `AttributedString` with a highlighted background.
    static func parseHighlightedSnippet(_ raw: String) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(raw)
        while let openRange = rest.range(of: "<<<") {
            let before = rest[rest.startIndex..<openRange.lowerBound]
            if !before.isEmpty {
                out.append(AttributedString(String(before)))
            }
            let afterOpen = rest[openRange.upperBound...]
            guard let closeRange = afterOpen.range(of: ">>>") else {
                out.append(AttributedString(String(afterOpen)))
                return out
            }
            let matched = afterOpen[afterOpen.startIndex..<closeRange.lowerBound]
            var attr = AttributedString(String(matched))
            attr.backgroundColor = .yellow
            attr.foregroundColor = .primary
            out.append(attr)
            rest = afterOpen[closeRange.upperBound...]
        }
        if !rest.isEmpty { out.append(AttributedString(String(rest))) }
        return out
    }
```

Import needed at file top (add if missing):

```swift
import SwiftUI  // for AttributedString foregroundColor / backgroundColor
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MeetingIndexerSearchTests`
Expected: PASS.

- [ ] **Step 5: Stage for user review**

```bash
git add Sources/RecorderCore/Index/SearchHit.swift \
        Sources/RecorderCore/Index/MeetingIndexer.swift \
        Tests/RecorderCoreTests/MeetingIndexerSearchTests.swift
git status
```

---

### Task 8: `MeetingIndexer.listAllGrouped()`

**Files:**
- Modify: `Sources/RecorderCore/Index/MeetingIndexer.swift`
- Test: `Tests/RecorderCoreTests/MeetingIndexerListAllGroupedTests.swift` (new)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/RecorderCoreTests/MeetingIndexerListAllGroupedTests.swift
import XCTest
@testable import RecorderCore

final class MeetingIndexerListAllGroupedTests: XCTestCase {
    var dbPath: URL!
    override func setUp() {
        super.setUp()
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-idx-\(UUID().uuidString).sqlite")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dbPath); super.tearDown() }

    func test_listAllGrouped_returnsAllOrderedByStartedAtDesc() throws {
        let indexer = try MeetingIndexer(dbPath: dbPath)
        let d1 = Date(timeIntervalSince1970: 100)
        let d2 = Date(timeIntervalSince1970: 200)
        let d3 = Date(timeIntervalSince1970: 300)
        for (i, d) in [d1, d2, d3].enumerated() {
            let meta = MeetingMetadata(id: "m\(i)", startedAt: d, endedAt: nil,
                                       durationSeconds: 0, title: "T\(i)",
                                       source: .manual, appVersion: "0.1.0",
                                       models: .init(whisper: "w", diarization: "d"))
            try indexer.upsert(meta: meta, folderPath: URL(fileURLWithPath: "/tmp/m\(i)"),
                               transcriptState: "done", transcript: [])
        }
        let all = try indexer.listAllGrouped()
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all[0].id, "m2")
        XCTAssertEqual(all[1].id, "m1")
        XCTAssertEqual(all[2].id, "m0")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MeetingIndexerListAllGroupedTests`
Expected: FAIL — method doesn't exist.

- [ ] **Step 3: Implement `listAllGrouped`**

Append inside `MeetingIndexer`:

```swift
    /// Returns every indexed meeting, most recent first. The "grouped" name
    /// signals intent: consumers (viewer sidebar) bucketize by date on the
    /// client side. This method just sorts and returns raw listings.
    public func listAllGrouped() throws -> [MeetingListing] {
        try reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, path, started_at, title, transcript_state
                FROM meetings
                ORDER BY started_at DESC
                """)
            let iso = ISO8601DateFormatter()
            return rows.map { row in
                MeetingListing(
                    id: row["id"] as String,
                    startedAt: iso.date(from: row["started_at"] as String)
                        ?? Date(timeIntervalSince1970: 0),
                    title: row["title"] as String?,
                    folderPath: URL(fileURLWithPath: row["path"] as String),
                    transcriptState: row["transcript_state"] as String?
                )
            }
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MeetingIndexerListAllGroupedTests`
Expected: PASS.

- [ ] **Step 5: Stage for user review**

```bash
git add Sources/RecorderCore/Index/MeetingIndexer.swift \
        Tests/RecorderCoreTests/MeetingIndexerListAllGroupedTests.swift
git status
```

---

### Task 9: `WaveformGenerator` + `WaveformFile`

**Files:**
- Create: `Sources/RecorderCore/Waveform/WaveformGenerator.swift`
- Create: `Sources/RecorderCore/Waveform/WaveformFile.swift`
- Test: `Tests/RecorderCoreTests/WaveformGeneratorTests.swift` (new)
- Test: `Tests/RecorderCoreTests/WaveformFileTests.swift` (new)

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/RecorderCoreTests/WaveformFileTests.swift
import XCTest
@testable import RecorderCore

final class WaveformFileTests: XCTestCase {
    func test_roundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = WaveformFile(peaks: [0.1, 0.5, 0.9], sampleRate: 16_000, bucketSizeMs: 50)
        try file.write(to: tmp)
        let back = try WaveformFile.read(from: tmp)
        XCTAssertEqual(back.peaks, [0.1, 0.5, 0.9])
        XCTAssertEqual(back.sampleRate, 16_000)
        XCTAssertEqual(back.bucketSizeMs, 50)
    }
}
```

```swift
// Tests/RecorderCoreTests/WaveformGeneratorTests.swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WaveformFileTests`
Run: `swift test --filter WaveformGeneratorTests`
Expected: FAIL — types don't exist.

- [ ] **Step 3: Implement `WaveformFile`**

Create `Sources/RecorderCore/Waveform/WaveformFile.swift`:

```swift
import Foundation

/// Compact on-disk representation of a meeting's waveform, used by the viewer's
/// scrubber. Written once by the pipeline `.render` step, then read many times.
public struct WaveformFile: Codable, Equatable, Sendable {
    /// RMS peak in [0, 1] per bucket, in chronological order.
    public let peaks: [Float]
    public let sampleRate: Int
    public let bucketSizeMs: Int

    public init(peaks: [Float], sampleRate: Int, bucketSizeMs: Int) {
        self.peaks = peaks
        self.sampleRate = sampleRate
        self.bucketSizeMs = bucketSizeMs
    }

    public func write(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> WaveformFile {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(WaveformFile.self, from: data)
    }
}
```

- [ ] **Step 4: Implement `WaveformGenerator`**

Create `Sources/RecorderCore/Waveform/WaveformGenerator.swift`:

```swift
import Foundation
import AVFoundation

public enum WaveformGenerator {
    public enum GenerationError: Error {
        case unsupportedFormat
    }

    /// One-shot scan of a mono float32 WAV, returning RMS peaks bucketed by
    /// `bucketSizeMs` (default 50 ms). Uses AVAudioFile for portability with
    /// whatever WAV writer wrote the file. Runs in ~50-100 ms for a 10-min WAV.
    public static func generate(from wavURL: URL,
                                bucketSizeMs: Int = 50) throws -> WaveformFile {
        let file = try AVAudioFile(forReading: wavURL)
        let sampleRate = Int(file.fileFormat.sampleRate)
        let framesPerBucket = max(1, sampleRate * bucketSizeMs / 1000)

        // Use a working format that guarantees float32 non-interleaved regardless
        // of the on-disk encoding.
        guard let workFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: file.fileFormat.sampleRate,
                                          channels: file.fileFormat.channelCount,
                                          interleaved: false) else {
            throw GenerationError.unsupportedFormat
        }

        let chunkFrames: AVAudioFrameCount = 16_384
        guard let buf = AVAudioPCMBuffer(pcmFormat: workFmt, frameCapacity: chunkFrames) else {
            throw GenerationError.unsupportedFormat
        }

        var peaks: [Float] = []
        peaks.reserveCapacity(Int(file.length) / framesPerBucket + 1)

        var bucketAcc: Float = 0
        var bucketCount: Int = 0

        while file.framePosition < file.length {
            try file.read(into: buf)
            let n = Int(buf.frameLength)
            if n == 0 { break }
            let ch0 = buf.floatChannelData![0]
            for i in 0..<n {
                let v = ch0[i]
                bucketAcc += v * v
                bucketCount += 1
                if bucketCount >= framesPerBucket {
                    peaks.append((bucketAcc / Float(bucketCount)).squareRoot())
                    bucketAcc = 0
                    bucketCount = 0
                }
            }
        }
        if bucketCount > 0 {
            peaks.append((bucketAcc / Float(bucketCount)).squareRoot())
        }

        return WaveformFile(peaks: peaks,
                            sampleRate: sampleRate,
                            bucketSizeMs: bucketSizeMs)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter WaveformFileTests`
Run: `swift test --filter WaveformGeneratorTests`
Expected: PASS.

- [ ] **Step 6: Stage for user review**

```bash
git add Sources/RecorderCore/Waveform/WaveformFile.swift \
        Sources/RecorderCore/Waveform/WaveformGenerator.swift \
        Tests/RecorderCoreTests/WaveformFileTests.swift \
        Tests/RecorderCoreTests/WaveformGeneratorTests.swift
git status
```

---

### Task 10: Pipeline `.render` step writes `waveform.json`

**Files:**
- Modify: `Sources/RecorderCore/Pipeline/Pipeline.swift:59-65`
- Test: `Tests/RecorderCoreTests/PipelineWaveformStepTests.swift` (new)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/RecorderCoreTests/PipelineWaveformStepTests.swift
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

    /// Runs a mocked pipeline (whisper + diarizer stubs) end-to-end and asserts
    /// waveform.json is written after .render.
    func test_render_writesWaveformJson() async throws {
        let storage = MeetingStorage(root: tmp.appendingPathComponent("Meetings"))
        let paths = try storage.createMeeting(startedAt: Date())
        try writeSineWav(to: paths.micWav)
        try writeSineWav(to: paths.systemWav)

        struct StubWhisper: WhisperTranscribing {
            func transcribe(wavPath: URL, to jsonPath: URL) async throws {
                let segs = [WhisperSegment(start: 0, end: 1, text: "hi", confidence: 1)]
                try AtomicJSON.write(segs, to: jsonPath)
            }
        }
        struct StubDiarizer: Diarizing {
            func diarize(wavPath: URL, to jsonPath: URL) throws {
                let segs: [DiarSegment] = []
                try AtomicJSON.write(segs, to: jsonPath)
            }
        }

        let pipeline = Pipeline(storage: storage, whisper: StubWhisper(),
                                diarizer: StubDiarizer(), notes: nil)
        try await pipeline.run(paths: paths)

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.waveformJson.path),
                      "waveform.json should be written after .render")
        let wf = try WaveformFile.read(from: paths.waveformJson)
        XCTAssertFalse(wf.peaks.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PipelineWaveformStepTests`
Expected: FAIL — no waveform.json produced.

- [ ] **Step 3: Add waveform write to `.render`**

Modify `Sources/RecorderCore/Pipeline/Pipeline.swift`, inside the `.render` step closure. Replace the closure body:

```swift
        try await runStep(.render, paths: paths, overall: .rendering) {
            let segs = try AtomicJSON.read([TranscriptSegment].self, from: paths.transcriptJson)
            let meta = try self.storage.loadMetadata(paths)
            let md = MarkdownRenderer.render(segments: segs, meetingStart: meta.startedAt,
                                             slug: paths.slug)
            try md.data(using: .utf8)!.write(to: paths.transcriptMd, options: .atomic)

            // Pre-compute the waveform for the viewer's scrubber. Uses the
            // normalized mic WAV — same file the transcriber runs on, so it
            // exists at this point. Failure is non-fatal: the viewer falls
            // back to on-the-fly generation if this file is missing.
            do {
                let wf = try WaveformGenerator.generate(from: paths.micNormalized,
                                                        bucketSizeMs: 50)
                try wf.write(to: paths.waveformJson)
            } catch {
                Log.pipeline.warning(
                    "Waveform generation failed for \(paths.slug, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PipelineWaveformStepTests`
Expected: PASS.

- [ ] **Step 5: Verify all pipeline tests still pass**

Run: `swift test --filter Pipeline`
Expected: PASS.

- [ ] **Step 6: Stage for user review**

```bash
git add Sources/RecorderCore/Pipeline/Pipeline.swift \
        Tests/RecorderCoreTests/PipelineWaveformStepTests.swift
git status
```

---

**Phase 1 done.** Backend is ready: live notes, prompt injection, FTS search with timestamps, waveform pré-calculée.

---

## Phase 2 — Viewer scaffolding

Setup de la fenêtre, du store d'état, de la vue racine, et de l'intégration menu bar. Aucun rendu final ici, juste la charpente pour que Phase 3+ puisse ajouter les sous-vues.

### Task 11: `ViewerState` — Codable snapshot on disk (+ nouveau test target `OnyxTests`)

**Files:**
- Modify: `Package.swift` (add `OnyxTests` test target)
- Create: `Sources/Onyx/Viewer/Persistence/ViewerState.swift`
- Test: `Tests/OnyxTests/ViewerStateTests.swift` (new)

- [ ] **Step 0: Add the `OnyxTests` test target to Package.swift**

The package currently only has `RecorderCoreTests`. Add to the `targets:` array in `Package.swift`:

```swift
        .testTarget(name: "OnyxTests", dependencies: ["Onyx"]),
```

Note: testing an `executableTarget` is supported since Swift 5.5 (`@testable import Onyx` works when built via `swift test`). Verify with `swift build` that the manifest still loads.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/OnyxTests/ViewerStateTests.swift
import XCTest
@testable import Onyx

final class ViewerStateTests: XCTestCase {
    func test_defaults() {
        let s = ViewerState()
        XCTAssertNil(s.lastMeetingId)
        XCTAssertEqual(s.activeNoteLevel, "synthese")
        XCTAssertEqual(s.notesToTranscriptRatio, 0.6, accuracy: 0.001)
        XCTAssertFalse(s.transcriptPanelHidden)
        XCTAssertEqual(s.lastSearchQuery, "")
    }

    func test_roundTrip_json() throws {
        var s = ViewerState()
        s.lastMeetingId = "2026-07-31_15h10"
        s.activeNoteLevel = "brief"
        s.notesToTranscriptRatio = 0.72
        s.transcriptPanelHidden = true
        s.lastSearchQuery = "whisper"

        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(ViewerState.self, from: data)
        XCTAssertEqual(back, s)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ViewerStateTests`
Expected: FAIL — type not found.

- [ ] **Step 3: Implement `ViewerState`**

Create `Sources/Onyx/Viewer/Persistence/ViewerState.swift`:

```swift
import Foundation

/// Persisted snapshot of the viewer window (position/size handled by
/// NSWindowController's frameAutosaveName). Written to disk with a small
/// debounce on every user-visible change.
public struct ViewerState: Codable, Equatable {
    public var lastMeetingId: String?
    public var activeNoteLevel: String        // "live" | "brief" | "synthese" | "detaillee"
    public var notesToTranscriptRatio: Double // 0.3...0.85 of the main area
    public var transcriptPanelHidden: Bool
    public var lastSearchQuery: String

    public init(lastMeetingId: String? = nil,
                activeNoteLevel: String = "synthese",
                notesToTranscriptRatio: Double = 0.6,
                transcriptPanelHidden: Bool = false,
                lastSearchQuery: String = "") {
        self.lastMeetingId = lastMeetingId
        self.activeNoteLevel = activeNoteLevel
        self.notesToTranscriptRatio = notesToTranscriptRatio
        self.transcriptPanelHidden = transcriptPanelHidden
        self.lastSearchQuery = lastSearchQuery
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ViewerStateTests`
Expected: PASS.

- [ ] **Step 5: Stage for user review**

```bash
git add Sources/Onyx/Viewer/Persistence/ViewerState.swift \
        Tests/OnyxTests/ViewerStateTests.swift
git status
```

---

### Task 12: `ViewerStatePersistence` — debounced load/save

**Files:**
- Create: `Sources/Onyx/Viewer/Persistence/ViewerStatePersistence.swift`
- Test: `Tests/OnyxTests/ViewerStorePersistenceTests.swift` (new)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/OnyxTests/ViewerStorePersistenceTests.swift
import XCTest
@testable import Onyx

final class ViewerStorePersistenceTests: XCTestCase {
    var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-\(UUID().uuidString).json")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp); super.tearDown() }

    func test_load_missingFileReturnsDefaults() {
        let p = ViewerStatePersistence(url: tmp)
        XCTAssertEqual(p.load(), ViewerState())
    }

    func test_saveThenLoad_returnsPersistedState() {
        let p = ViewerStatePersistence(url: tmp)
        var s = ViewerState()
        s.lastMeetingId = "abc"
        s.notesToTranscriptRatio = 0.42
        p.saveImmediately(s)
        XCTAssertEqual(p.load(), s)
    }

    func test_scheduleSave_debouncesMultipleCalls() async throws {
        let p = ViewerStatePersistence(url: tmp, debounceMs: 80)
        var s = ViewerState()
        s.lastMeetingId = "step1"
        p.scheduleSave(s)
        s.lastMeetingId = "step2"
        p.scheduleSave(s)
        s.lastMeetingId = "step3"
        p.scheduleSave(s)
        // Immediately after: nothing on disk yet (or a stale value).
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(p.load().lastMeetingId, "step3")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ViewerStorePersistenceTests`
Expected: FAIL — type not found.

- [ ] **Step 3: Implement persistence**

Create `Sources/Onyx/Viewer/Persistence/ViewerStatePersistence.swift`:

```swift
import Foundation

/// Loads / persists `ViewerState` to disk. Debounces `scheduleSave` calls so
/// rapid state mutations (e.g. dragging the resizer) don't hammer the FS.
public final class ViewerStatePersistence: @unchecked Sendable {
    private let url: URL
    private let debounceMs: Int
    private let queue = DispatchQueue(label: "com.onyx.viewer.persist")
    private var pending: DispatchWorkItem?

    public init(url: URL = ViewerStatePersistence.defaultURL(), debounceMs: Int = 500) {
        self.url = url
        self.debounceMs = debounceMs
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
    }

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Onyx/viewer_state.json")
    }

    public func load() -> ViewerState {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(ViewerState.self, from: data)
        else { return ViewerState() }
        return s
    }

    public func saveImmediately(_ state: ViewerState) {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }

    public func scheduleSave(_ state: ViewerState) {
        queue.async {
            self.pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.saveImmediately(state) }
            self.pending = work
            self.queue.asyncAfter(deadline: .now() + .milliseconds(self.debounceMs), execute: work)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ViewerStorePersistenceTests`
Expected: PASS.

- [ ] **Step 5: Stage for user review**

```bash
git add Sources/Onyx/Viewer/Persistence/ViewerStatePersistence.swift \
        Tests/OnyxTests/ViewerStorePersistenceTests.swift
git status
```

---

### Task 13: `MeetingGroups` — bucketize meetings by date

**Files:**
- Create: `Sources/Onyx/Viewer/Sidebar/MeetingGroups.swift`
- Test: `Tests/OnyxTests/MeetingGroupsTests.swift` (new)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/OnyxTests/MeetingGroupsTests.swift
import XCTest
import RecorderCore
@testable import Onyx

final class MeetingGroupsTests: XCTestCase {
    private func listing(_ id: String, _ date: Date) -> MeetingListing {
        MeetingListing(id: id, startedAt: date, title: id,
                       folderPath: URL(fileURLWithPath: "/tmp/\(id)"),
                       transcriptState: "done")
    }

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        return c
    }

    func test_todayYesterdayThisWeekMonthsSplit() {
        // Reference "now" = 2026-07-31 15:00 Europe/Paris.
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 31,
                                                hour: 15, minute: 0))!
        let today   = cal.date(byAdding: .hour, value: -2, to: now)!
        let yester  = cal.date(byAdding: .day,  value: -1, to: now)!
        let thisWk  = cal.date(byAdding: .day,  value: -4, to: now)!
        let julEarly= cal.date(from: DateComponents(year: 2026, month: 7, day: 5))!
        let june    = cal.date(from: DateComponents(year: 2026, month: 6, day: 12))!

        let all = [
            listing("today", today), listing("yester", yester),
            listing("thisWk", thisWk), listing("julEarly", julEarly),
            listing("june", june),
        ]
        let groups = MeetingGroups.group(all, now: now, calendar: cal)
        // Expect at least these headers in this order.
        let titles = groups.map(\.title)
        XCTAssertTrue(titles.contains("Aujourd'hui"))
        XCTAssertTrue(titles.contains("Hier"))
        XCTAssertTrue(titles.contains("Cette semaine"))
        XCTAssertTrue(titles.contains("Juillet 2026"))
        XCTAssertTrue(titles.contains("Juin 2026"))

        let today0 = groups.first { $0.title == "Aujourd'hui" }!
        XCTAssertEqual(today0.items.map(\.id), ["today"])
        let yest = groups.first { $0.title == "Hier" }!
        XCTAssertEqual(yest.items.map(\.id), ["yester"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MeetingGroupsTests`
Expected: FAIL — type not found.

- [ ] **Step 3: Implement grouping**

Create `Sources/Onyx/Viewer/Sidebar/MeetingGroups.swift`:

```swift
import Foundation
import RecorderCore

public struct MeetingGroup: Equatable {
    public let title: String
    public let items: [MeetingListing]
}

public enum MeetingGroups {
    /// Bucketizes meetings into "Aujourd'hui / Hier / Cette semaine /
    /// [Month] [Year]". Meetings must already be sorted (most-recent first).
    public static func group(_ meetings: [MeetingListing],
                             now: Date = Date(),
                             calendar: Calendar = .current) -> [MeetingGroup] {
        var buckets: [String: [MeetingListing]] = [:]
        var order: [String] = []

        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        // "Cette semaine" = from Monday of current week (inclusive) to yesterday (exclusive).
        let weekStart = calendar.date(
            from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!

        let monthFmt = DateFormatter()
        monthFmt.calendar = calendar
        monthFmt.locale = Locale(identifier: "fr_FR")
        monthFmt.dateFormat = "LLLL yyyy"

        for m in meetings {
            let key: String
            if calendar.isDate(m.startedAt, inSameDayAs: today) {
                key = "Aujourd'hui"
            } else if calendar.isDate(m.startedAt, inSameDayAs: yesterday) {
                key = "Hier"
            } else if m.startedAt >= weekStart {
                key = "Cette semaine"
            } else {
                key = monthFmt.string(from: m.startedAt).capitalized
            }
            if buckets[key] == nil { order.append(key); buckets[key] = [] }
            buckets[key]?.append(m)
        }
        return order.map { MeetingGroup(title: $0, items: buckets[$0] ?? []) }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MeetingGroupsTests`
Expected: PASS.

- [ ] **Step 5: Stage for user review**

```bash
git add Sources/Onyx/Viewer/Sidebar/MeetingGroups.swift \
        Tests/OnyxTests/MeetingGroupsTests.swift
git status
```

---

### Task 14: `ViewerStore` — Observable state root

**Files:**
- Create: `Sources/Onyx/Viewer/ViewerStore.swift`

No unit test for the store itself here — it's mostly plumbing that Phase 3-5 will wire and cover via their own tests. The banner-state behavior (`notesEditedSinceGeneration`) is covered by `RegenerateWarningStateTests` in Task 31.

- [ ] **Step 1: Implement `ViewerStore`**

Create `Sources/Onyx/Viewer/ViewerStore.swift`:

```swift
import Foundation
import Combine
import RecorderCore

/// Single source of truth for the viewer window. Uses `ObservableObject` for
/// broad macOS-13 compatibility (rather than `@Observable`, which is macOS 14+).
@MainActor
public final class ViewerStore: ObservableObject {
    // Selection + navigation
    @Published public var selectedMeetingId: String?
    @Published public var activeNoteLevel: NoteLevel = .synthese
    @Published public var searchQuery: String = ""
    @Published public var searchResults: [SearchHit] = []

    // Layout
    @Published public var notesToTranscriptRatio: Double = 0.6
    @Published public var transcriptPanelHidden: Bool = false

    // Data
    @Published public var meetings: [MeetingListing] = []
    @Published public var currentTranscript: [TranscriptSegment] = []
    @Published public var currentNotes: String = ""
    @Published public var currentLiveNotes: String = ""
    @Published public var notesEditedSinceGeneration: Bool = false

    // Dependencies
    public let storage: MeetingStorage
    public let indexer: MeetingIndexer
    public let claudeBinary: () -> URL?
    private let persistence: ViewerStatePersistence

    // Debounce holders
    private var notesSaveTask: Task<Void, Never>?
    private var liveSaveTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    public init(storage: MeetingStorage,
                indexer: MeetingIndexer,
                claudeBinary: @escaping () -> URL?,
                persistence: ViewerStatePersistence = ViewerStatePersistence()) {
        self.storage = storage
        self.indexer = indexer
        self.claudeBinary = claudeBinary
        self.persistence = persistence

        let s = persistence.load()
        self.selectedMeetingId = s.lastMeetingId
        self.activeNoteLevel = NoteLevel(rawValue: s.activeNoteLevel) ?? .synthese
        self.notesToTranscriptRatio = s.notesToTranscriptRatio
        self.transcriptPanelHidden = s.transcriptPanelHidden
        self.searchQuery = s.lastSearchQuery

        // Persist layout changes with debounce.
        Publishers.CombineLatest4($selectedMeetingId, $activeNoteLevel,
                                  $notesToTranscriptRatio, $transcriptPanelHidden)
            .combineLatest($searchQuery)
            .sink { [weak self] _ in self?.persistNow() }
            .store(in: &cancellables)
    }

    // MARK: - Meetings

    public func refreshMeetings() {
        meetings = (try? indexer.listAllGrouped()) ?? []
    }

    public func selectMeeting(_ id: String) {
        selectedMeetingId = id
        loadCurrentMeetingContent()
    }

    private func loadCurrentMeetingContent() {
        guard let id = selectedMeetingId,
              let listing = meetings.first(where: { $0.id == id })
        else {
            currentTranscript = []; currentNotes = ""; currentLiveNotes = ""
            notesEditedSinceGeneration = false
            return
        }
        let paths = MeetingPaths(root: storage.root, slug: listing.id)
        currentTranscript = (try? AtomicJSON.read([TranscriptSegment].self,
                                                  from: paths.transcriptJson)) ?? []
        currentLiveNotes = (try? String(contentsOf: paths.liveNotes)) ?? ""
        loadActiveNote(paths: paths)
    }

    public func loadActiveNote(paths: MeetingPaths) {
        if activeNoteLevel == .synthese || activeNoteLevel == .brief || activeNoteLevel == .detaillee {
            currentNotes = (try? String(contentsOf: paths.notesFile(activeNoteLevel))) ?? ""
        }
        notesEditedSinceGeneration = notesModifiedAfterJob(paths: paths, level: activeNoteLevel)
    }

    private func notesModifiedAfterJob(paths: MeetingPaths, level: NoteLevel) -> Bool {
        let fm = FileManager.default
        guard let noteAttr = try? fm.attributesOfItem(atPath: paths.notesFile(level).path),
              let jobAttr  = try? fm.attributesOfItem(atPath: paths.job.path),
              let noteMTime = noteAttr[.modificationDate] as? Date,
              let jobMTime  = jobAttr[.modificationDate]  as? Date
        else { return false }
        // Small buffer so the write done by the pipeline itself doesn't trip us.
        return noteMTime.timeIntervalSince(jobMTime) > 5.0
    }

    // MARK: - Notes editing (auto-save debounce)

    public func onNotesEdited(_ new: String) {
        currentNotes = new
        guard let id = selectedMeetingId else { return }
        let paths = MeetingPaths(root: storage.root, slug: id)
        let level = activeNoteLevel
        notesSaveTask?.cancel()
        notesSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            try? new.data(using: .utf8)?.write(to: paths.notesFile(level), options: .atomic)
            await MainActor.run { self?.notesEditedSinceGeneration = true }
        }
    }

    public func onLiveNotesEdited(_ new: String) {
        currentLiveNotes = new
        guard let id = selectedMeetingId else { return }
        let paths = MeetingPaths(root: storage.root, slug: id)
        liveSaveTask?.cancel()
        liveSaveTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            try? new.data(using: .utf8)?.write(to: paths.liveNotes, options: .atomic)
        }
    }

    // MARK: - Search

    public func onSearchQueryChanged(_ q: String) {
        searchQuery = q
        searchTask?.cancel()
        let indexer = self.indexer
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let hits = (try? indexer.search(q, limit: 100)) ?? []
            await MainActor.run { self?.searchResults = hits }
        }
    }

    // MARK: - Regeneration

    public func regenerateActiveNote() async {
        guard let id = selectedMeetingId, let bin = claudeBinary() else { return }
        let paths = MeetingPaths(root: storage.root, slug: id)
        let level = activeNoteLevel
        do {
            try await ClaudeNoteGenerator().generate(paths: paths, level: level, binary: bin)
            loadActiveNote(paths: paths)
        } catch {
            // Surface to the user via a lastError channel — kept simple here.
        }
    }

    // MARK: - Layout

    public func toggleTranscriptPanel() { transcriptPanelHidden.toggle() }
    public func setSplitRatio(_ r: Double) {
        notesToTranscriptRatio = max(0.3, min(0.85, r))
    }

    // MARK: - Persistence

    private func persistNow() {
        let s = ViewerState(
            lastMeetingId: selectedMeetingId,
            activeNoteLevel: activeNoteLevel.rawValue,
            notesToTranscriptRatio: notesToTranscriptRatio,
            transcriptPanelHidden: transcriptPanelHidden,
            lastSearchQuery: searchQuery
        )
        persistence.scheduleSave(s)
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Stage for user review**

```bash
git add Sources/Onyx/Viewer/ViewerStore.swift
git status
```

---

### Task 15: `ViewerRootView` — empty layout skeleton

**Files:**
- Create: `Sources/Onyx/Viewer/ViewerRootView.swift`

Phase 3 fills the sidebar; Phase 4 fills the main panel. This task just wires the three placeholder zones so the skeleton compiles and can be embedded in the window (Task 16).

- [ ] **Step 1: Implement skeleton**

Create `Sources/Onyx/Viewer/ViewerRootView.swift`:

```swift
import SwiftUI

struct ViewerRootView: View {
    @ObservedObject var store: ViewerStore

    var body: some View {
        HSplitView {
            // Sidebar (Phase 3 will replace this).
            Color(.windowBackgroundColor).opacity(0.6)
                .overlay(Text("Sidebar").foregroundStyle(.secondary))
                .frame(minWidth: 240, idealWidth: 260, maxWidth: 340)
            // Main panel (Phase 4 will replace this).
            Color(.textBackgroundColor).opacity(0.4)
                .overlay(Text("Main panel").foregroundStyle(.secondary))
                .frame(minWidth: 640)
        }
        .frame(minWidth: 960, minHeight: 640)
        .background(.thickMaterial)
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 3: Stage for user review**

```bash
git add Sources/Onyx/Viewer/ViewerRootView.swift
git status
```

---

### Task 16: `ViewerWindowController` — single-instance NSWindow

**Files:**
- Create: `Sources/Onyx/Viewer/ViewerWindowController.swift`

- [ ] **Step 1: Implement controller**

Create `Sources/Onyx/Viewer/ViewerWindowController.swift`:

```swift
import AppKit
import SwiftUI

/// Owns the single viewer window. `show()` creates it lazily on first call,
/// then reuses the same NSWindow forever — closing it just hides it
/// (`orderOut`) so the store state stays warm.
@MainActor
public final class ViewerWindowController {
    private var window: NSWindow?
    private let store: ViewerStore

    public init(store: ViewerStore) { self.store = store }

    public func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let content = ViewerRootView(store: store)
        let host = NSHostingController(rootView: content)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "Onyx"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentViewController = host
        w.center()
        w.setFrameAutosaveName("onyx.viewer")
        // Intercept close → just hide.
        w.delegate = HideOnCloseDelegate.shared
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func focusLiveNotes() {
        show()
        store.activeNoteLevel = .live
    }
}

private final class HideOnCloseDelegate: NSObject, NSWindowDelegate {
    static let shared = HideOnCloseDelegate()
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
```

Note: `.live` requires `NoteLevel` to include a `.live` case. That's covered in the next task.

- [ ] **Step 2: Stage for user review**

```bash
git add Sources/Onyx/Viewer/ViewerWindowController.swift
git status
```

---

### Task 17: `NoteLevel.live` added

**Files:**
- Modify: `Sources/RecorderCore/Notes/NoteLevel.swift`

The current `NoteLevel` enum (chantier 2) has `.brief / .synthese / .detaillee`. Add `.live` so the viewer can key its tabs on it. The pipeline `.notes` step never writes `.live` — `live.md` is user-only — but the enum case is needed so `ViewerStore.activeNoteLevel` and the tabs can enumerate uniformly.

- [ ] **Step 1: Read the current enum**

Run: `grep -n "case " Sources/RecorderCore/Notes/NoteLevel.swift`

- [ ] **Step 2: Add `.live` case**

Add `case live = "live"` to the enum, above `.brief`. Ensure `allCases` and any switches still compile. Adjust any exhaustive switches in the codebase (search for `case .brief:` and add explicit handling or a `default:` where appropriate).

Run: `grep -rn "case .brief" Sources/ Tests/`
For each match: either add `case .live: ...` or add `default:` returning a safe value. The primary places likely to need updating:
- `NotePromptTemplates.prompt(for:...)` — add a `case .live:` that returns an empty instruction (live.md is never sent to Claude as a *target*, only injected as *context*). Concretely, protect against accidental use:

```swift
        case .live:
            // .live is never a generation target — live.md is authored by the
            // user directly. This branch exists to satisfy exhaustiveness.
            return ""
```

- Any menu bar switch iterating `NoteLevel.allCases` (chantier 2 has one in `MenuBarView`). Filter out `.live` when the menu is "Regenerate notes as…":

```swift
ForEach(NoteLevel.allCases.filter { $0 != .live }, id: \.self) { level in
    Button(level.rawValue.capitalized) { app.regenerateNotes(for: m.id, level: level) }
}
```

- [ ] **Step 3: Guard `ClaudeNoteGenerator.generate` against `.live`**

At the top of `generate(paths:level:binary:)` in `ClaudeNoteGenerator.swift`, add:

```swift
        precondition(level != .live,
                     ".live is a user-authored artifact and must not be a generation target")
```

- [ ] **Step 4: Build & run tests**

Run: `swift build`
Run: `swift test`
Expected: PASS. Chantier 2 tests still pass because `.live` isn't exercised by any of them.

- [ ] **Step 5: Stage for user review**

```bash
git add Sources/RecorderCore/Notes/NoteLevel.swift \
        Sources/RecorderCore/Notes/NotePromptTemplates.swift \
        Sources/RecorderCore/Notes/ClaudeNoteGenerator.swift \
        Sources/Onyx/Menu/MenuBarView.swift
git status
```

---

### Task 18: Menu bar integration — Open viewer + Open live notes

**Files:**
- Modify: `Sources/Onyx/AppState.swift`
- Modify: `Sources/Onyx/Menu/MenuBarView.swift`

- [ ] **Step 1: Own the controller in AppState**

Add a `viewerController` property to `AppState`, initialized after `indexer` and `storage` are set:

```swift
    public let viewerController: ViewerWindowController
```

In `init()`, after the existing `indexer = try! MeetingIndexer(...)`:

```swift
        // Bind to a local first: capturing `settings` directly in the closure
        // inside init() can trigger "self used before all stored properties
        // are initialized" (same class of error hit earlier when wiring
        // onPipelineFinished before `orchestrator` was set).
        let settingsLocal = settings
        let vStore = ViewerStore(storage: storage, indexer: indexer,
                                 claudeBinary: {
            settingsLocal.claudeBinaryPath.isEmpty
                ? nil : URL(fileURLWithPath: settingsLocal.claudeBinaryPath)
        })
        viewerController = ViewerWindowController(store: vStore)
        vStore.refreshMeetings()
```

- [ ] **Step 2: Add menu entries**

Modify `Sources/Onyx/Menu/MenuBarView.swift`, add above the existing `Divider()` that precedes `Open meetings folder`:

```swift
            Button("Open viewer…  ⌘⇧V") { app.viewerController.show() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            if app.uiState == .recording {
                Button("Open live notes  ⌘⇧L") { app.viewerController.focusLiveNotes() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
            Divider()
```

- [ ] **Step 3: Build & smoke test**

Run: `./scripts/build-app.sh`
Expected: Build succeeds and the app signs.

Launch the app, click the menu bar icon, verify:
- "Open viewer… ⌘⇧V" is visible
- Clicking it opens a window with "Sidebar / Main panel" placeholders
- Closing the window hides it, re-opening reuses the same instance
- Start a recording, verify "Open live notes ⌘⇧L" appears

- [ ] **Step 4: Stage for user review**

```bash
git add Sources/Onyx/AppState.swift Sources/Onyx/Menu/MenuBarView.swift
git status
```

---

**Phase 2 done.** Fenêtre viewer visible avec placeholders, wiring menu bar en place.

---

## Phase 3 — Sidebar (browse + search)

7 tâches. Pure SwiftUI, s'appuie sur `MeetingGroups` (Task 13) et `MeetingIndexer.search` (Task 7). Tests visuels par comparaison au mockup `viewer.html`.

### Task 19: `SourceBadge` view

**Files:**
- Create: `Sources/Onyx/Viewer/Sidebar/SourceBadge.swift`

- [ ] **Step 1: Implement view**

```swift
import SwiftUI
import RecorderCore

struct SourceBadge: View {
    let source: MeetingMetadata.Source?

    var body: some View {
        Text(label)
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .kerning(0.4)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .foregroundStyle(fg)
            .background(bg, in: RoundedRectangle(cornerRadius: 3))
    }

    private var label: String {
        switch source {
        case .manual: "MANUAL"
        case .calendar: "CAL"
        case .detected: "MEET"      // detection Meet (JXA) — rendered as MEET
        case .huddle: "HUDDLE"
        case nil: "—"
        }
    }
    private var bg: Color {
        switch source {
        case .detected: Color(red: 0.09, green: 0.50, blue: 0.22).opacity(0.10)
        case .huddle: Color(red: 0.60, green: 0.24, blue: 0.78).opacity(0.10)
        case .calendar: Color(red: 0.23, green: 0.23, blue: 0.78).opacity(0.10)
        case .manual, nil: Color.black.opacity(0.06)
        }
    }
    private var fg: Color {
        switch source {
        case .detected: Color(red: 0.09, green: 0.38, blue: 0.20)
        case .huddle: Color(red: 0.42, green: 0.16, blue: 0.56)
        case .calendar: Color(red: 0.16, green: 0.23, blue: 0.64)
        case .manual, nil: Color.secondary
        }
    }
}
```

Note: le type source est `MeetingMetadata.Source` (nested enum, `Sources/RecorderCore/Storage/MeetingMetadata.swift:4-6`) avec les cases **`.manual / .calendar / .huddle / .detected`** — il n'y a PAS de case `.meet` ; la détection Google Meet est représentée par `.detected`. `MeetingListing` n'expose pas encore ce champ — voir Task 20 pour le join.

- [ ] **Step 2: Verify build**

Run: `swift build`
Expected: PASS.

- [ ] **Step 3: Stage**

```bash
git add Sources/Onyx/Viewer/Sidebar/SourceBadge.swift
git status
```

---

### Task 20: Expose `source` on `MeetingListing`

**Files:**
- Modify: `Sources/RecorderCore/Index/MeetingIndexer.swift`
- Modify: `Sources/RecorderCore/Index/IndexSchema.swift`
- Test: `Tests/RecorderCoreTests/MeetingIndexerSourceTests.swift` (new)

Adds a `source` column to `meetings` table (v3 migration) and to `MeetingListing`. Needed so the sidebar can render the badge without a second per-row query.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/RecorderCoreTests/MeetingIndexerSourceTests.swift
import XCTest
@testable import RecorderCore

final class MeetingIndexerSourceTests: XCTestCase {
    var dbPath: URL!
    override func setUp() {
        super.setUp()
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-\(UUID().uuidString).sqlite")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dbPath); super.tearDown() }

    func test_upsert_persistsSource_readableInListing() throws {
        let idx = try MeetingIndexer(dbPath: dbPath)
        let meta = MeetingMetadata(id: "m1", startedAt: Date(), endedAt: nil,
                                   durationSeconds: 0, title: "T",
                                   source: .detected, appVersion: "0.1.0",
                                   models: .init(whisper: "w", diarization: "d"))
        try idx.upsert(meta: meta, folderPath: URL(fileURLWithPath: "/tmp/m1"),
                       transcriptState: "done", transcript: [])
        let all = try idx.listAllGrouped()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].source, .detected)
    }

    func test_currentVersion_is3() {
        XCTAssertEqual(IndexSchema.currentVersion, 3)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MeetingIndexerSourceTests`
Expected: FAIL.

- [ ] **Step 3: Add v3 migration**

Append to `IndexSchema.migrator()`:

```swift
        m.registerMigration("v3_meetings_source") { db in
            try db.execute(sql: "ALTER TABLE meetings ADD COLUMN source TEXT")
            try db.execute(sql: "UPDATE meetings SET indexed_at = NULL")
        }
```

Bump `currentVersion` to 3.

- [ ] **Step 4: Update `MeetingListing` + `MeetingIndexer` + fix Task-5 test**

Add `source: MeetingMetadata.Source?` to `MeetingListing`, **default nil** (so the Task-13 `MeetingGroupsTests` init calls still compile). Update `upsert` to write it, `recentMeetings` and `listAllGrouped` to read it.

Also update `Tests/RecorderCoreTests/IndexSchemaMigrationV2Tests.swift`: change `test_currentVersion_is2` to assert `IndexSchema.currentVersion == 3` (rename to `test_currentVersion_is3` or delete it — the same assertion lives in this task's test file).

In `upsert`, replace the meetings INSERT SQL:

```swift
            try db.execute(sql: """
                INSERT INTO meetings (id, path, started_at, duration_seconds, title,
                                       transcript_state, indexed_at, source)
                VALUES (?, ?, ?, ?, ?, ?, datetime('now'), ?)
                ON CONFLICT(id) DO UPDATE SET
                    path=excluded.path,
                    started_at=excluded.started_at,
                    duration_seconds=excluded.duration_seconds,
                    title=excluded.title,
                    transcript_state=excluded.transcript_state,
                    indexed_at=excluded.indexed_at,
                    source=excluded.source
                """,
                arguments: [meta.id, folderPath.path,
                            ISO8601DateFormatter().string(from: meta.startedAt),
                            meta.durationSeconds, meta.title,
                            transcriptState, meta.source.rawValue])
```

In both `recentMeetings` and `listAllGrouped`, add `source` to the SELECT and to the mapping:

```swift
                let sourceRaw: String? = row["source"]
                let source = sourceRaw.flatMap(MeetingMetadata.Source.init(rawValue:))
                return MeetingListing(id: id, startedAt: started, title: title,
                                      folderPath: URL(fileURLWithPath: path),
                                      transcriptState: state, source: source)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter MeetingIndexerSourceTests`
Run: `swift test --filter MeetingIndexerRecentTests`
Run: `swift test --filter MeetingIndexerListAllGroupedTests`
Expected: PASS.

- [ ] **Step 6: Stage**

```bash
git add Sources/RecorderCore/Index/*.swift Tests/RecorderCoreTests/MeetingIndexerSourceTests.swift
git status
```

---

### Task 21: `SearchField` with ⌘K binding

**Files:**
- Create: `Sources/Onyx/Viewer/Sidebar/SearchField.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI

struct SearchField: View {
    @Binding var text: String
    var onChange: (String) -> Void = { _ in }
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Rechercher meetings, transcripts…", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .font(.system(size: 12))
                // Single-param onChange: the two-param variant is macOS 14+,
                // the project targets macOS 13.
                .onChange(of: text) { new in onChange(new) }
            Text("⌘K")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 3))
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.black.opacity(focused ? 0 : 0.045),
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor, lineWidth: focused ? 2 : 0)
                .padding(-2)
        )
        .padding(.horizontal, 4).padding(.top, 4).padding(.bottom, 12)
        // ⌘K focus is wired at window level via NotificationCenter (Task 39) —
        // .onKeyPress is macOS 14+ and must NOT be used (target is macOS 13).
        .onReceive(NotificationCenter.default.publisher(for: .onyxFocusSearch)) { _ in
            focused = true
        }
    }
}

extension Notification.Name {
    /// Posted by the window-level ⌘K shortcut (Task 39) to focus this field.
    static let onyxFocusSearch = Notification.Name("onyx.viewer.focus.search")
}
```

- [ ] **Step 2: Stage**

```bash
git add Sources/Onyx/Viewer/Sidebar/SearchField.swift
git status
```

---

### Task 22: `MeetingRow` + `DateGroupSection`

**Files:**
- Create: `Sources/Onyx/Viewer/Sidebar/MeetingRow.swift`
- Create: `Sources/Onyx/Viewer/Sidebar/DateGroupSection.swift`

- [ ] **Step 1: `MeetingRow`**

```swift
import SwiftUI
import RecorderCore

struct MeetingRow: View {
    let meeting: MeetingListing
    let selected: Bool
    let onSelect: () -> Void

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "d MMM"; return f
    }()

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 0) {
                Text(timeLabel)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 44, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title ?? "Untitled")
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                    SourceBadge(source: meeting.source)
                        .padding(.leading, 2)
                }
                Spacer(minLength: 0)
                if let dur = durationLabel {
                    Text(dur)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 7).padding(.horizontal, 10)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var timeLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(meeting.startedAt) || cal.isDateInYesterday(meeting.startedAt) {
            return Self.timeFmt.string(from: meeting.startedAt)
        }
        return Self.dayFmt.string(from: meeting.startedAt)
    }
    private var durationLabel: String? { nil /* Task 27 populates from meta */ }
    @ViewBuilder private var rowBackground: some View {
        if selected {
            HStack(spacing: 0) {
                Rectangle().fill(Color.accentColor).frame(width: 2)
                Rectangle().fill(Color.accentColor.opacity(0.10))
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Color.clear
        }
    }
}
```

- [ ] **Step 2: `DateGroupSection`**

```swift
import SwiftUI

struct DateGroupSection<Content: View>: View {
    let title: String
    let count: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .kerning(0.7)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
            content()
        }
    }
}
```

- [ ] **Step 3: Verify build**

Run: `swift build`
Expected: PASS.

- [ ] **Step 4: Stage**

```bash
git add Sources/Onyx/Viewer/Sidebar/MeetingRow.swift \
        Sources/Onyx/Viewer/Sidebar/DateGroupSection.swift
git status
```

---

### Task 23: `SearchResultRow` + `SearchResultsList`

**Files:**
- Create: `Sources/Onyx/Viewer/Sidebar/SearchResultRow.swift`
- Create: `Sources/Onyx/Viewer/Sidebar/SearchResultsList.swift`

- [ ] **Step 1: `SearchResultRow`**

```swift
import SwiftUI
import RecorderCore

struct SearchResultRow: View {
    let hit: SearchHit
    let selected: Bool
    let onSelect: () -> Void

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "d MMM · HH:mm"; return f
    }()

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(hit.title ?? "Untitled")
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text(Self.dayFmt.string(from: hit.startedAt))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(hit.snippet)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                HStack(spacing: 8) {
                    Text(hit.speaker)
                        .font(.system(size: 10.5, design: .monospaced))
                    if let t = hit.approximateTimestamp {
                        Text("·").foregroundStyle(.tertiary)
                        Text(Self.mmss(t))
                            .font(.system(size: 10.5, design: .monospaced))
                    }
                }
                .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(selected ? Color.accentColor.opacity(0.10) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private static func mmss(_ t: TimeInterval) -> String {
        let mm = Int(t) / 60, ss = Int(t) % 60
        return String(format: "%02d:%02d", mm, ss)
    }
}
```

- [ ] **Step 2: `SearchResultsList`**

```swift
import SwiftUI
import RecorderCore

struct SearchResultsList: View {
    let hits: [SearchHit]
    @Binding var selectedMeetingId: String?
    let onSelect: (SearchHit) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("\(hits.count) résultats")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                ForEach(hits, id: \.meetingId) { hit in
                    SearchResultRow(hit: hit,
                                    selected: hit.meetingId == selectedMeetingId,
                                    onSelect: { onSelect(hit) })
                }
            }
            .padding(.horizontal, 4)
        }
    }
}
```

- [ ] **Step 3: Stage**

```bash
git add Sources/Onyx/Viewer/Sidebar/SearchResultRow.swift \
        Sources/Onyx/Viewer/Sidebar/SearchResultsList.swift
git status
```

---

### Task 24: `MeetingsSidebar` — assembly

**Files:**
- Create: `Sources/Onyx/Viewer/Sidebar/MeetingsSidebar.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI
import RecorderCore

struct MeetingsSidebar: View {
    @ObservedObject var store: ViewerStore

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: Binding(
                get: { store.searchQuery },
                set: { store.onSearchQueryChanged($0) }
            ))
            if store.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                browseList
            } else {
                SearchResultsList(
                    hits: store.searchResults,
                    selectedMeetingId: $store.selectedMeetingId,
                    onSelect: { store.selectMeeting($0.meetingId) }
                )
            }
            Divider()
            HStack {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("Idle").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("\(store.meetings.count) meetings")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(SidebarBackground())
        .frame(minWidth: 240, idealWidth: 260, maxWidth: 340)
    }

    @ViewBuilder private var browseList: some View {
        let groups = MeetingGroups.group(store.meetings)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups, id: \.title) { g in
                    DateGroupSection(title: g.title, count: g.items.count) {
                        ForEach(g.items, id: \.id) { m in
                            MeetingRow(meeting: m,
                                       selected: m.id == store.selectedMeetingId,
                                       onSelect: { store.selectMeeting(m.id) })
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

/// Translucent material behind the sidebar, matching macOS sidebars.
private struct SidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
```

- [ ] **Step 2: Wire into `ViewerRootView`**

Replace the sidebar placeholder in `ViewerRootView` with `MeetingsSidebar(store: store)`.

- [ ] **Step 3: Build & manual smoke test**

Run: `./scripts/build-app.sh` and open the app.
Click "Open viewer… ⌘⇧V".
Expected: sidebar renders meetings grouped by date, search field visible, typing filters via FTS.

- [ ] **Step 4: Stage**

```bash
git add Sources/Onyx/Viewer/Sidebar/MeetingsSidebar.swift \
        Sources/Onyx/Viewer/ViewerRootView.swift
git status
```

---

### Task 25: `RescanRunner` — refill `start_ms` + `source` on old DBs

**Files:**
- Modify: `Sources/RecorderCore/Index/RescanRunner.swift`

- [ ] **Step 1: Verify existing behavior**

Run: `cat Sources/RecorderCore/Index/RescanRunner.swift`
Confirm it iterates all meetings in storage and calls `indexer.upsert` for each. If it does, no code change needed — the v2/v3 migrations set `indexed_at = NULL`, and the app's boot resume logic (chantier 1) already triggers a rescan when `indexed_at` is stale. Verify the current boot flow reads `indexed_at` — if not, wire it via a helper `needsRescan(paths:) -> Bool`.

- [ ] **Step 2: Add opt-in rescan flag**

If not already present, add to `AppState.init()` after `indexer` creation:

```swift
        if IndexSchema.currentVersion > (persistedIndexVersion ?? 0) {
            Task.detached { [storage, indexer] in
                _ = try? await RescanRunner(storage: storage, indexer: indexer).rescan()
            }
        }
```

Where `persistedIndexVersion` is a small `UserDefaults`-backed integer (`indexer.persistedVersion`).

- [ ] **Step 3: Stage**

```bash
git add Sources/RecorderCore/Index/RescanRunner.swift Sources/Onyx/AppState.swift
git status
```

---

**Phase 3 done.** Sidebar entièrement fonctionnelle : browse groupé par date, search FTS avec highlights, source badges, rescan automatique post-migration.

---

## Phase 4 — Main panel (header + notes + transcript + resizer)

11 tâches. Le cœur du viewer. Tests unitaires ciblés sur les comportements (auto-save, banner régénération, resize state).

### Task 26: `AvatarStack`

**Files:**
- Create: `Sources/Onyx/Viewer/Main/AvatarStack.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI

struct AvatarStack: View {
    let initials: [String] // ["YB", "SM"]

    private static let gradients: [[Color]] = [
        [Color(red: 0.85, green: 0.46, blue: 0.34), Color(red: 0.72, green: 0.35, blue: 0.24)],
        [Color(red: 0.29, green: 0.49, blue: 0.62), Color(red: 0.17, green: 0.35, blue: 0.49)],
        [Color(red: 0.42, green: 0.55, blue: 0.23), Color(red: 0.30, green: 0.42, blue: 0.14)],
        [Color(red: 0.54, green: 0.42, blue: 0.66), Color(red: 0.42, green: 0.29, blue: 0.54)],
    ]

    var body: some View {
        HStack(spacing: -6) {
            ForEach(Array(initials.enumerated()), id: \.offset) { idx, init_ in
                let g = Self.gradients[idx % Self.gradients.count]
                Text(init_)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(LinearGradient(colors: g, startPoint: .topLeading,
                                               endPoint: .bottomTrailing),
                                in: Circle())
                    .overlay(Circle().stroke(Color(.windowBackgroundColor), lineWidth: 1.5))
                    .zIndex(Double(-idx))
            }
        }
    }
}
```

- [ ] **Step 2: Stage**

```bash
git add Sources/Onyx/Viewer/Main/AvatarStack.swift
git status
```

---

### Task 27: `MeetingHeaderView`

**Files:**
- Create: `Sources/Onyx/Viewer/Main/MeetingHeaderView.swift`

Extract participants from the transcript (unique speakers) as initials. Duration comes from `meta.durationSeconds` if present.

- [ ] **Step 1: Implement**

```swift
import SwiftUI
import RecorderCore

struct MeetingHeaderView: View {
    let meeting: MeetingListing
    let duration: Int?
    let participants: [String] // initials
    let onRegenerate: () -> Void

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEEE d MMMM"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(meeting.id)
                    .font(.system(size: 10.5, design: .monospaced)).kerning(0.6)
                    .foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                SourceBadge(source: meeting.source)
            }
            HStack(alignment: .lastTextBaseline) {
                Text(meeting.title ?? "Untitled")
                    .font(.system(size: 28, weight: .semibold, design: .default))
                    .kerning(-0.6)
                Spacer()
                Button(action: onRegenerate) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("Régénérer notes")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                Text(Self.dateFmt.string(from: meeting.startedAt).capitalized)
                if let d = duration {
                    Text("·").foregroundStyle(.tertiary)
                    Text(Self.humanDuration(d))
                }
                if !participants.isEmpty {
                    Spacer().frame(width: 4)
                    AvatarStack(initials: participants)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32).padding(.top, 22).padding(.bottom, 16)
    }

    private static func humanDuration(_ s: Int) -> String {
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s/60) min" }
        return String(format: "%dh%02d", s/3600, (s%3600)/60)
    }
}
```

- [ ] **Step 2: Stage**

```bash
git add Sources/Onyx/Viewer/Main/MeetingHeaderView.swift
git status
```

---

### Task 28: `ResizableSplit`

**Files:**
- Create: `Sources/Onyx/Viewer/Main/ResizableSplit.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI

/// Two-pane horizontal split with a draggable divider. `ratio` is the fraction
/// of width taken by the *leading* pane, clamped to [minLeading, 1 - minTrailing].
struct ResizableSplit<Leading: View, Trailing: View>: View {
    @Binding var ratio: Double
    let minLeading: CGFloat
    let minTrailing: CGFloat
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let split = max(minLeading, min(total - minTrailing, total * ratio))
            HStack(spacing: 0) {
                leading().frame(width: split)
                dividerHandle(total: total)
                trailing()
            }
        }
    }

    private func dividerHandle(total: CGFloat) -> some View {
        ZStack {
            Color.clear.frame(width: 6)
            Rectangle().fill(.separator).frame(width: 0.5)
            if isDragging {
                Capsule().fill(Color.accentColor).frame(width: 3, height: 40)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            // Balanced push/pop — pushing on both enter and exit leaks
            // cursors on the stack and the resize cursor sticks forever.
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    isDragging = true
                    let newSplit = max(minLeading, min(total - minTrailing, v.location.x))
                    ratio = Double(newSplit / total)
                }
                .onEnded { _ in isDragging = false }
        )
    }
}
```

- [ ] **Step 2: Stage**

```bash
git add Sources/Onyx/Viewer/Main/ResizableSplit.swift
git status
```

---

### Task 29: `RegenerateWarningBanner`

**Files:**
- Create: `Sources/Onyx/Viewer/Main/RegenerateWarningBanner.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI

struct RegenerateWarningBanner: View {
    let onDismiss: () -> Void
    let onRegenerate: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(red: 0.78, green: 0.54, blue: 0.18))
            VStack(alignment: .leading, spacing: 2) {
                Text("Cette note a été éditée depuis sa génération.")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("Régénérer va écraser tes modifications.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Ignorer", action: onDismiss)
                .buttonStyle(.borderless)
                .font(.system(size: 12))
            Button("Régénérer quand même", action: onRegenerate)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(
            LinearGradient(colors: [
                Color(red: 0.78, green: 0.54, blue: 0.18).opacity(0.10),
                Color(red: 0.78, green: 0.54, blue: 0.18).opacity(0.05)
            ], startPoint: .top, endPoint: .bottom)
        )
        .overlay(Rectangle().fill(.separator).frame(height: 0.5), alignment: .bottom)
    }
}
```

- [ ] **Step 2: Stage**

```bash
git add Sources/Onyx/Viewer/Main/RegenerateWarningBanner.swift
git status
```

---

### Task 30: `NotesEditor`

**Files:**
- Create: `Sources/Onyx/Viewer/Main/NotesEditor.swift`

Uses `TextEditor` with monospaced-serif styling. v1 = plain Markdown source (see design §13 alternative rejected). Post-v1 upgrade to WYSIWYG can be layered.

- [ ] **Step 1: Implement**

```swift
import SwiftUI

struct NotesEditor: View {
    @Binding var text: String
    var onEdit: (String) -> Void

    var body: some View {
        ScrollView {
            TextEditor(text: Binding(
                get: { text },
                set: { new in text = new; onEdit(new) }
            ))
            .font(.system(size: 14, design: .serif))
            .lineSpacing(4)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 28).padding(.vertical, 24)
            .frame(minHeight: 400)
        }
    }
}
```

- [ ] **Step 2: Stage**

```bash
git add Sources/Onyx/Viewer/Main/NotesEditor.swift
git status
```

---

### Task 31: `NotesPanel` (4 tabs + banner + editor)

**Files:**
- Create: `Sources/Onyx/Viewer/Main/NotesPanel.swift`
- Test: `Tests/OnyxTests/RegenerateWarningStateTests.swift` (new)

- [ ] **Step 1: Write banner-visibility test**

```swift
// Tests/OnyxTests/RegenerateWarningStateTests.swift
import XCTest
import RecorderCore
@testable import Onyx

final class RegenerateWarningStateTests: XCTestCase {
    var tmp: URL!
    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp); super.tearDown() }

    @MainActor
    func test_bannerShows_whenNoteMtimeAfterJobMtimePlusBuffer() async throws {
        let storage = MeetingStorage(root: tmp.appendingPathComponent("Meetings"))
        let paths = try storage.createMeeting(startedAt: Date())
        try "generated".write(to: paths.notesFile(.synthese),
                              atomically: true, encoding: .utf8)
        // Simulate the pipeline finishing.
        try FileManager.default.setAttributes([.modificationDate: Date()],
                                              ofItemAtPath: paths.job.path)
        // Now edit the note "later".
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(30)],
            ofItemAtPath: paths.notesFile(.synthese).path)

        let dbPath = tmp.appendingPathComponent("i.sqlite")
        let idx = try MeetingIndexer(dbPath: dbPath)
        // Inject a temp-path persistence — the default writes to the real
        // ~/Library/Application Support/Onyx/viewer_state.json and would
        // pollute the user's actual viewer state during tests.
        let persistence = ViewerStatePersistence(
            url: tmp.appendingPathComponent("viewer_state.json"))
        let store = ViewerStore(storage: storage, indexer: idx,
                                claudeBinary: { nil }, persistence: persistence)
        store.selectedMeetingId = paths.slug
        store.loadActiveNote(paths: paths)
        XCTAssertTrue(store.notesEditedSinceGeneration)
    }
}
```

- [ ] **Step 2: `NotesPanel`**

```swift
import SwiftUI
import RecorderCore

struct NotesPanel: View {
    @ObservedObject var store: ViewerStore
    @State private var bannerDismissed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                tab(.live, "Direct", icon: "pencil")
                tab(.brief, "Brief", icon: "doc.plaintext")
                tab(.synthese, "Synthèse", icon: "text.alignleft")
                tab(.detaillee, "Détaillée", icon: "book.closed")
                Spacer()
                editStatus
            }
            .padding(.horizontal, 20).padding(.top, 14)
            .overlay(Rectangle().fill(.separator).frame(height: 0.5), alignment: .bottom)

            if store.activeNoteLevel != .live &&
               store.notesEditedSinceGeneration && !bannerDismissed {
                RegenerateWarningBanner(
                    onDismiss: { bannerDismissed = true },
                    onRegenerate: {
                        bannerDismissed = true
                        Task { await store.regenerateActiveNote() }
                    }
                )
            }

            if store.activeNoteLevel == .live {
                NotesEditor(
                    text: Binding(get: { store.currentLiveNotes },
                                  set: { new in store.onLiveNotesEdited(new) }),
                    onEdit: store.onLiveNotesEdited
                )
            } else {
                NotesEditor(
                    text: Binding(get: { store.currentNotes },
                                  set: { new in store.onNotesEdited(new) }),
                    onEdit: store.onNotesEdited
                )
            }
        }
        .background(Color(.textBackgroundColor).opacity(0.5))
        // Single-param onChange (two-param variant is macOS 14+).
        .onChange(of: store.activeNoteLevel) { _ in bannerDismissed = false }
    }

    @ViewBuilder private func tab(_ level: NoteLevel, _ title: String, icon: String) -> some View {
        let active = store.activeNoteLevel == level
        Button(action: {
            store.activeNoteLevel = level
            if let id = store.selectedMeetingId {
                let p = MeetingPaths(root: store.storage.root, slug: id)
                store.loadActiveNote(paths: p)
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(.system(size: 12.5, weight: active ? .semibold : .medium))
                if level == .live && store.selectedMeetingId != nil {
                    Circle().fill(.red).frame(width: 5, height: 5).opacity(0.8)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8).padding(.bottom, 2)
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .overlay(
                Rectangle().fill(active ? Color.accentColor : .clear)
                    .frame(height: 2),
                alignment: .bottom
            )
        }
        .buttonStyle(.plain)
    }

    private var editStatus: some View {
        Text("Enregistré")
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(Color(red: 0.12, green: 0.48, blue: 0.20))
    }
}
```

- [ ] **Step 3: Run test**

Run: `swift test --filter RegenerateWarningStateTests`
Expected: PASS.

- [ ] **Step 4: Stage**

```bash
git add Sources/Onyx/Viewer/Main/NotesPanel.swift \
        Tests/OnyxTests/RegenerateWarningStateTests.swift
git status
```

---

### Task 32: `TurnView` + `TranscriptPanel`

**Files:**
- Create: `Sources/Onyx/Viewer/Main/TurnView.swift`
- Create: `Sources/Onyx/Viewer/Main/TranscriptPanel.swift`

- [ ] **Step 1: `TurnView`**

```swift
import SwiftUI
import RecorderCore

struct TurnView: View {
    let segment: TranscriptSegment
    let isActive: Bool  // highlighted by playhead

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(mmss(segment.start))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Circle().fill(color(for: segment.speaker))
                        .frame(width: 8, height: 8)
                    Text(segment.speaker)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(color(for: segment.speaker))
                }
                Text(segment.text)
                    .font(.system(size: 14.5))
                    .lineSpacing(2)
            }
        }
        .padding(.vertical, 10)
        .background(isActive ? Color.accentColor.opacity(0.06) : .clear)
    }

    private func color(for speaker: String) -> Color {
        // Deterministic hash-based color for speaker consistency across turns.
        let h = abs(speaker.hashValue) % 4
        switch h {
        case 0: return Color(red: 0.72, green: 0.35, blue: 0.24)
        case 1: return Color(red: 0.17, green: 0.35, blue: 0.49)
        case 2: return Color(red: 0.30, green: 0.42, blue: 0.14)
        default: return Color(red: 0.42, green: 0.29, blue: 0.54)
        }
    }
    private func mmss(_ t: TimeInterval) -> String {
        let hh = Int(t) / 3600, mm = (Int(t) % 3600) / 60, ss = Int(t) % 60
        return hh > 0 ? String(format: "%02d:%02d:%02d", hh, mm, ss)
                      : String(format: "%02d:%02d", mm, ss)
    }
}
```

- [ ] **Step 2: `TranscriptPanel`**

```swift
import SwiftUI
import RecorderCore

struct TranscriptPanel: View {
    @ObservedObject var store: ViewerStore
    let currentPlayheadSeconds: TimeInterval
    let onSeek: (TimeInterval) -> Void
    let onHide: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("TRANSCRIPT")
                    .font(.system(size: 12, weight: .semibold)).kerning(0.7)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onHide) {
                    Image(systemName: "chevron.right.2")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("Masquer le panneau transcript")
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 8)
            .overlay(Rectangle().fill(.separator).frame(height: 0.5), alignment: .bottom)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.currentTranscript.enumeratedArray(), id: \.offset) { idx, seg in
                            TurnView(segment: seg, isActive: isActive(seg))
                                .onTapGesture { onSeek(seg.start) }
                                .id(idx)
                        }
                    }
                    .padding(.horizontal, 32).padding(.bottom, 40)
                }
                // Single-param onChange (two-param variant is macOS 14+).
                .onChange(of: currentPlayheadSeconds) { _ in
                    if let idx = activeIndex() {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(idx, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func isActive(_ seg: TranscriptSegment) -> Bool {
        currentPlayheadSeconds >= seg.start && currentPlayheadSeconds < seg.end
    }
    private func activeIndex() -> Int? {
        store.currentTranscript.firstIndex { isActive($0) }
    }
}

private extension Array {
    func enumeratedArray() -> [(offset: Int, element: Element)] {
        enumerated().map { (offset: $0.offset, element: $0.element) }
    }
}
```

- [ ] **Step 3: Build & smoke**

Run: `swift build`
Expected: PASS.

- [ ] **Step 4: Stage**

```bash
git add Sources/Onyx/Viewer/Main/TurnView.swift \
        Sources/Onyx/Viewer/Main/TranscriptPanel.swift
git status
```

---

### Task 33: `ShowPanelFAB`

**Files:**
- Create: `Sources/Onyx/Viewer/Main/ShowPanelFAB.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI

struct ShowPanelFAB: View {
    let onShow: () -> Void
    var body: some View {
        Button(action: onShow) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.2").font(.system(size: 11))
                Text("Transcript").font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: Stage**

```bash
git add Sources/Onyx/Viewer/Main/ShowPanelFAB.swift
git status
```

---

### Task 34: `MainPanel` — assembly

**Files:**
- Create: `Sources/Onyx/Viewer/Main/MainPanel.swift`
- Modify: `Sources/Onyx/Viewer/ViewerRootView.swift`

- [ ] **Step 1: `MainPanel`**

```swift
import SwiftUI
import RecorderCore

struct MainPanel: View {
    @ObservedObject var store: ViewerStore
    // Playhead + audio come from Phase 5 — placeholders for now.
    @State private var playheadSeconds: TimeInterval = 0
    let currentDuration: Int?
    let currentSourceListing: MeetingListing?

    var body: some View {
        VStack(spacing: 0) {
            if let m = currentSourceListing {
                MeetingHeaderView(
                    meeting: m,
                    duration: currentDuration,
                    participants: uniqueSpeakers(),
                    onRegenerate: { Task { await store.regenerateActiveNote() } }
                )
                .overlay(Rectangle().fill(.separator).frame(height: 0.5), alignment: .bottom)
            } else {
                EmptyStateView()
            }
            ZStack(alignment: .topTrailing) {
                Group {
                    if store.transcriptPanelHidden {
                        NotesPanel(store: store)
                    } else {
                        ResizableSplit(
                            ratio: Binding(get: { store.notesToTranscriptRatio },
                                           set: { store.setSplitRatio($0) }),
                            minLeading: 320, minTrailing: 280,
                            leading: { NotesPanel(store: store) },
                            trailing: {
                                TranscriptPanel(
                                    store: store,
                                    currentPlayheadSeconds: playheadSeconds,
                                    onSeek: { playheadSeconds = $0 },
                                    onHide: { store.transcriptPanelHidden = true }
                                )
                                .background(Color(.textBackgroundColor).opacity(0.3))
                            }
                        )
                    }
                }
                if store.transcriptPanelHidden {
                    ShowPanelFAB(onShow: { store.transcriptPanelHidden = false })
                        .padding(.top, 14).padding(.trailing, 14)
                }
            }
            // Audio scrubber goes here (Phase 5).
        }
    }

    private func uniqueSpeakers() -> [String] {
        var seen: [String] = []
        for seg in store.currentTranscript where !seen.contains(seg.speaker) {
            seen.append(seg.speaker)
            if seen.count >= 4 { break }
        }
        return seen.map { String($0.prefix(2)).uppercased() }
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Sélectionne un meeting dans la sidebar")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 2: Wire into `ViewerRootView`**

Replace the main-panel placeholder in `ViewerRootView`:

```swift
        HSplitView {
            MeetingsSidebar(store: store)
            MainPanel(
                store: store,
                currentDuration: currentDuration(),
                currentSourceListing: currentListing()
            )
        }
```

Add helpers:

```swift
    private func currentListing() -> MeetingListing? {
        guard let id = store.selectedMeetingId else { return nil }
        return store.meetings.first { $0.id == id }
    }
    private func currentDuration() -> Int? {
        guard let listing = currentListing() else { return nil }
        let paths = MeetingPaths(root: store.storage.root, slug: listing.id)
        return (try? store.storage.loadMetadata(paths).durationSeconds).flatMap { $0 }
    }
```

- [ ] **Step 3: Build & smoke**

Run: `./scripts/build-app.sh` and launch.
Expected: viewer shows header + resizable split (notes | transcript), drag divider works, hide button collapses transcript, FAB brings it back.

- [ ] **Step 4: Stage**

```bash
git add Sources/Onyx/Viewer/Main/MainPanel.swift \
        Sources/Onyx/Viewer/ViewerRootView.swift
git status
```

---

**Phase 4 done.** Header + split resizable + notes 4-tabs + transcript avec hide/show. Audio scrubber en Phase 5.

---

## Phase 5 — Audio playback + waveform + playhead sync

4 tâches.

### Task 35: `AudioPlayer` wrapper

**Files:**
- Create: `Sources/Onyx/Viewer/Audio/AudioPlayer.swift`

- [ ] **Step 1: Implement**

```swift
import Foundation
import AVFoundation
import Combine

@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var rate: Float = 1.0 { didSet { player?.rate = rate; if isPlaying { player?.play() } } }

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(url: URL) {
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.enableRate = true
        p.rate = rate
        p.prepareToPlay()
        player = p
        duration = p.duration
        currentTime = 0
    }

    func play() {
        guard let p = player else { return }
        p.rate = rate
        p.play()
        isPlaying = true
        startTicker()
    }
    func pause() { player?.pause(); isPlaying = false; stopTicker() }
    func toggle() { isPlaying ? pause() : play() }
    func seek(_ t: TimeInterval) {
        player?.currentTime = max(0, min(duration, t))
        currentTime = player?.currentTime ?? 0
    }
    func stop() { player?.stop(); player = nil; isPlaying = false; duration = 0; currentTime = 0; stopTicker() }

    private func startTicker() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = self.player?.currentTime ?? 0
                if let p = self.player, !p.isPlaying, self.isPlaying { self.pause() }
            }
        }
    }
    private func stopTicker() { timer?.invalidate(); timer = nil }
}
```

- [ ] **Step 2: Stage**

```bash
git add Sources/Onyx/Viewer/Audio/AudioPlayer.swift
git status
```

---

### Task 36: `WaveformView`

**Files:**
- Create: `Sources/Onyx/Viewer/Audio/WaveformView.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI

struct WaveformView: View {
    let peaks: [Float]
    let progress: Double  // 0...1

    var body: some View {
        Canvas { ctx, size in
            let barWidth: CGFloat = 2
            let gap: CGFloat = 1.5
            let step = barWidth + gap
            let count = max(1, Int(size.width / step))
            // Downsample peaks to `count` bars.
            let stride = max(1, peaks.count / count)
            let midY = size.height / 2
            let activeCount = Int(Double(count) * progress)

            for i in 0..<count {
                let peakIdx = min(peaks.count - 1, i * stride)
                let p = peaks[peakIdx]
                let h = max(3, CGFloat(p) * (size.height - 4))
                let x = CGFloat(i) * step
                let rect = CGRect(x: x, y: midY - h/2, width: barWidth, height: h)
                let path = Path(roundedRect: rect, cornerRadius: 1)
                let color: Color = (i < activeCount) ? .accentColor : .secondary.opacity(0.55)
                ctx.fill(path, with: .color(color))
            }
        }
    }
}
```

- [ ] **Step 2: Stage**

```bash
git add Sources/Onyx/Viewer/Audio/WaveformView.swift
git status
```

---

### Task 37: `AudioScrubberBar`

**Files:**
- Create: `Sources/Onyx/Viewer/Audio/AudioScrubberBar.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI
import RecorderCore

struct AudioScrubberBar: View {
    @ObservedObject var player: AudioPlayer
    let peaks: [Float]

    private static let speeds: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        HStack(spacing: 14) {
            Button(action: player.toggle) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.primary, in: Circle())
            }
            .buttonStyle(.plain)

            GeometryReader { geo in
                WaveformView(peaks: peaks,
                             progress: player.duration > 0 ? player.currentTime / player.duration : 0)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0).onChanged { v in
                            let ratio = min(1, max(0, v.location.x / geo.size.width))
                            player.seek(ratio * player.duration)
                        }
                    )
            }
            .frame(height: 24)

            Text("\(mmss(player.currentTime)) / \(mmss(player.duration))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)

            Menu("\(String(format: "%.2gx", player.rate))") {
                ForEach(Self.speeds, id: \.self) { s in
                    Button(String(format: "%.2gx", s)) { player.rate = s }
                }
            }
            .menuStyle(.borderlessButton).frame(width: 60)
            .font(.system(size: 11, design: .monospaced))
        }
        .padding(.horizontal, 20)
        .frame(height: 46)
        .background(.regularMaterial)
        .overlay(Rectangle().fill(.separator).frame(height: 0.5), alignment: .top)
    }

    private func mmss(_ t: TimeInterval) -> String {
        let mm = Int(t) / 60, ss = Int(t) % 60
        return String(format: "%02d:%02d", mm, ss)
    }
}
```

- [ ] **Step 2: Stage**

```bash
git add Sources/Onyx/Viewer/Audio/AudioScrubberBar.swift
git status
```

---

### Task 38: Wire audio into `MainPanel`

**Files:**
- Modify: `Sources/Onyx/Viewer/Main/MainPanel.swift`
- Modify: `Sources/Onyx/Viewer/ViewerStore.swift`

- [ ] **Step 1: Owner the AudioPlayer in the store**

Add to `ViewerStore`:

```swift
    @Published public var currentWaveform: [Float] = []
    public let audioPlayer = AudioPlayer()

    /// Called when a meeting is selected — reloads audio + waveform.
    public func loadAudioForCurrentMeeting() {
        guard let id = selectedMeetingId else {
            audioPlayer.stop(); currentWaveform = []; return
        }
        let paths = MeetingPaths(root: storage.root, slug: id)
        let audioURL = FileManager.default.fileExists(atPath: paths.micNormalized.path)
            ? paths.micNormalized : paths.micWav
        if FileManager.default.fileExists(atPath: audioURL.path) {
            audioPlayer.load(url: audioURL)
        }
        // Waveform: prefer disk file, fall back to on-the-fly generation.
        if let wf = try? WaveformFile.read(from: paths.waveformJson) {
            currentWaveform = wf.peaks
        } else if FileManager.default.fileExists(atPath: audioURL.path),
                  let wf = try? WaveformGenerator.generate(from: audioURL) {
            try? wf.write(to: paths.waveformJson)
            currentWaveform = wf.peaks
        } else {
            currentWaveform = []
        }
    }
```

Call it at the end of `selectMeeting`:

```swift
    public func selectMeeting(_ id: String) {
        selectedMeetingId = id
        loadCurrentMeetingContent()
        loadAudioForCurrentMeeting()
    }
```

- [ ] **Step 2: Add scrubber to `MainPanel`**

Replace the placeholder `playheadSeconds` state in `MainPanel` with a binding to `store.audioPlayer.currentTime`, and append the scrubber at the bottom:

```swift
    var body: some View {
        VStack(spacing: 0) {
            // ... header + split (unchanged) ...
            AudioScrubberBar(player: store.audioPlayer, peaks: store.currentWaveform)
        }
    }
```

Update `TranscriptPanel` usage — pass `store.audioPlayer.currentTime` for `currentPlayheadSeconds`, and `store.audioPlayer.seek` for `onSeek`.

- [ ] **Step 3: Build & smoke**

Run: `./scripts/build-app.sh` and launch. Select a meeting.
Expected: waveform visible, play/pause works, clicking a transcript turn seeks audio.

- [ ] **Step 4: Stage**

```bash
git add Sources/Onyx/Viewer/Main/MainPanel.swift Sources/Onyx/Viewer/ViewerStore.swift
git status
```

---

**Phase 5 done.** Audio playback + waveform + sync playhead↔transcript.

---

## Phase 6 — Polish, keyboard shortcuts, QA

### Task 39: Keyboard shortcuts

**Files:**
- Modify: `Sources/Onyx/Viewer/ViewerRootView.swift`

- [ ] **Step 1: Add `.keyboardShortcut` on the window's content**

Wrap the root view with a hidden button strip that binds shortcuts:

```swift
        HSplitView { ... }
        .background(
            KeyboardShortcuts(store: store)
        )
```

Create the helper:

```swift
private struct KeyboardShortcuts: View {
    @ObservedObject var store: ViewerStore

    var body: some View {
        // Invisible buttons carry the shortcuts. Not focusable, no visual.
        Group {
            Button("Focus search") { NotificationCenter.default.post(name: .onyxFocusSearch, object: nil) }
                .keyboardShortcut("k", modifiers: [.command])
            Button("Tab Live") { store.activeNoteLevel = .live }
                .keyboardShortcut("1", modifiers: [.command])
            Button("Tab Brief") { store.activeNoteLevel = .brief }
                .keyboardShortcut("2", modifiers: [.command])
            Button("Tab Synthèse") { store.activeNoteLevel = .synthese }
                .keyboardShortcut("3", modifiers: [.command])
            Button("Tab Détaillée") { store.activeNoteLevel = .detaillee }
                .keyboardShortcut("4", modifiers: [.command])
            Button("Toggle transcript") { store.transcriptPanelHidden.toggle() }
                .keyboardShortcut("\\", modifiers: [.command])
            Button("Regenerate") { Task { await store.regenerateActiveNote() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
    }
}
```

Note: `Notification.Name.onyxFocusSearch` is already defined in `SearchField.swift` (Task 21) — do NOT redefine it here. `SearchField` already observes it and sets `focused = true`.

- [ ] **Step 2: Stage**

```bash
git add Sources/Onyx/Viewer/ViewerRootView.swift Sources/Onyx/Viewer/Sidebar/SearchField.swift
git status
```

---

### Task 40: Empty states (no notes yet, transcribing)

**Files:**
- Modify: `Sources/Onyx/Viewer/Main/NotesPanel.swift`

- [ ] **Step 1: Show placeholder when `currentNotes` empty and level != .live**

In `NotesPanel.body`, before showing `NotesEditor` for non-live tabs:

```swift
            if store.activeNoteLevel != .live && store.currentNotes.isEmpty {
                emptyNotesPlaceholder
            } else if store.activeNoteLevel == .live { ... }
              else { NotesEditor(...) }
```

Add:

```swift
    private var emptyNotesPlaceholder: some View {
        VStack(spacing: 10) {
            Text("Aucune note \(store.activeNoteLevel.rawValue.capitalized) pour ce meeting.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Button("Générer maintenant") {
                Task { await store.regenerateActiveNote() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
```

- [ ] **Step 2: Stage**

```bash
git add Sources/Onyx/Viewer/Main/NotesPanel.swift
git status
```

---

### Task 41: Manual QA checklist

- [ ] **Step 1: Run the QA script**

Launch the app. For each item below, verify then check:

- [ ] Open the viewer via `⌘⇧V` from the menu bar.
- [ ] Sidebar shows meetings grouped by date, most recent first.
- [ ] Click a meeting → header, notes (Synthèse tab), transcript, waveform load within 500 ms.
- [ ] Type `whisper` in the search field → results appear with highlighted snippets within 300 ms.
- [ ] Click a search result → main panel switches to that meeting.
- [ ] Drag the divider between notes and transcript → widths adjust, no jitter.
- [ ] Click the hide (`»`) button in the transcript header → transcript disappears, FAB appears top-right.
- [ ] Click the FAB → transcript returns.
- [ ] Switch to Brief tab (`⌘2`) → content loads.
- [ ] Switch to Detail tab (`⌘4`) → content loads.
- [ ] Type in the Synthèse editor → after ~700 ms, disk file is updated (verify at `~/Meetings/<slug>/notes/synthese.md`).
- [ ] After editing, yellow banner appears at top of notes panel.
- [ ] Click "Ignorer" → banner disappears.
- [ ] Click "Régénérer quand même" → note reverts to the AI-generated version, banner disappears.
- [ ] Play audio (Space or click ▶) → waveform fills as it progresses.
- [ ] Click a turn in the transcript → audio seeks to that turn.
- [ ] Start a new recording from the menu bar → `~/Meetings/<slug>/notes/live.md` is created empty.
- [ ] Menu bar shows "Open live notes ⌘⇧L".
- [ ] Click `⌘⇧L` → viewer opens on the current meeting, Direct tab focused.
- [ ] Type notes in the Direct tab during the recording → they save to `live.md`.
- [ ] Stop the recording, wait for pipeline to finish → Brief/Synthèse/Détaillée notes appear, generated content mentions/integrates the live notes.
- [ ] Close the viewer window → the app stays running.
- [ ] Reopen the viewer → last selected meeting is preserved, split ratio preserved, transcript-hidden state preserved.

- [ ] **Step 2: Log any issues found**

Any failing item = a follow-up task. File a lightweight bug entry in `docs/superpowers/plans/2026-07-31-onyx-chantier-3-viewer.md` at the end (new section `## Follow-ups`).

- [ ] **Step 3: Stage nothing (QA only)**

---

**Phase 6 done. Chantier 3 complete.**

---

## Self-Review Checklist

- [x] **Spec coverage** : every requirement in §2 of the design doc is covered — sidebar (T22-24), search (T7-8, T21-24), notes 4-tabs éditables (T31), transcript éditable (T32), audio playback + sync (T35-38), waveform (T9-10, T36), live notes (T1-4), régénération avec banner (T29-31), resizer (T28), hide/show (T33-34), keyboard shortcuts (T39), empty states (T40), menu bar integration (T18), persistence (T11-12), rescan post-migration (T25), source badge (T19-20).
- [x] **Placeholders scan** : no "TBD" / "similar to Task N" / bare "add error handling". Each step contains actual code.
- [x] **Type consistency** : `NoteLevel.live` added in T17 before it's used in T31; `MeetingListing.source` added in T20 before used in T22; `SearchHit` defined in T7 before used in T23; `WaveformFile` defined in T9 before used in T10, T36-38.
- [x] **Test coverage** : backend tasks (T1-10, T13, T20) all have unit tests. UI tasks (T11-12, T31) have targeted state tests; pure layout tasks rely on manual QA (T41).
- [x] **File paths absolute** where they refer to sources; step commands include exact `swift test --filter` names.

---

## Execution guidance

The plan is 41 tasks over 6 phases. Recommended split :

- **Batch 1** (Phase 1, T1-10) — pure backend, safe to run as a single subagent-driven sprint.
- **Batch 2** (Phase 2, T11-18) — scaffolding + menu bar. Manual smoke at T18.
- **Batch 3** (Phase 3, T19-25) — sidebar with search. Manual smoke at T24.
- **Batch 4** (Phase 4, T26-34) — main panel. Manual smoke at T34.
- **Batch 5** (Phase 5, T35-38) — audio. Manual smoke at T38.
- **Batch 6** (Phase 6, T39-41) — polish + QA final.

Each batch produces a working, testable app increment. Stop at batch boundaries for user review.

