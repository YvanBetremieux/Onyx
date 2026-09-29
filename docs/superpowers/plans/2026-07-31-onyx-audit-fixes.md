# Onyx Audit Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Corriger l'intégralité des findings de l'audit pré-production (4 CRITICAL, 14 HIGH, ~18 MEDIUM, ~11 LOW) : crashs de cycle de vie, machine à états de l'orchestrateur, calendrier, pipes de process, packaging, intégrité des téléchargements.

**Architecture:** Le cœur des fixes : (1) `Recorder` devient un actor avec rollback ; (2) `AutoTriggerOrchestrator` gagne des états transitionnels `.starting`/`.stopping`, un auto-stop calendrier et un callback de transitions qui devient la source de vérité de l'UI ; (3) `AppState` gère des boucles annulables + réglages à chaud ; (4) tous les `Process` externes drainent leurs pipes en continu ; (5) `build-app.sh` embarque dylibs + Sparkle dans `Contents/Frameworks`.

**Tech Stack:** Swift 5.9 / SwiftPM, SwiftUI + AppKit, ScreenCaptureKit, EventKit, GRDB, WhisperKit, sherpa-onnx (C API), Sparkle 2, CryptoKit.

**RÈGLES GLOBALES (non négociables) :**
- **AUCUN commit git, aucun `git add`, aucun push.** Jamais. Vérification = `swift build` / `swift test`, pas de commit.
- Après chaque tâche : `swift build 2>&1 | tail -5` et `swift test 2>&1 | tail -20` doivent passer.
- À la toute fin (Task 22) : `bash scripts/build-app.sh`, re-signature, relance de l'app.
- Ne pas toucher aux fichiers non listés. Pas de refactoring opportuniste.

---

## File Structure (vue d'ensemble)

**Modifiés — RecorderCore:** `Recorder.swift` (→ actor), `MicRecorder.swift`, `SystemAudioRecorder.swift`, `WavWriter.swift`, `Normalizer.swift`, `Merger.swift`, `Pipeline.swift`, `Mp4Converter.swift`, `ClaudeNoteGenerator.swift`, `AutoTriggerOrchestrator.swift`, `RecorderSession.swift`, `CalendarWatcher.swift`, `CalendarMatcher.swift`, `MatchedEvent.swift`, `DetectionCoordinator.swift`, `MeetDetector.swift`, `SlackHuddleDetector.swift`, `MeetingStorage.swift`, `MeetingMetadata.swift`, `JobState.swift`, `RescanRunner.swift`, `MeetingIndexer.swift`, `AtomicJSON.swift`, `ModelDownloader.swift`, `ModelManifest.swift`, `Diarization/SherpaOnnxWrapper.swift`
**Créés — RecorderCore:** `Support/DataCollector.swift`
**Modifiés — Onyx (app):** `App.swift`, `AppState.swift`, `Hotkey/GlobalHotkey.swift`, `Menu/MenuBarView.swift`, `Notifications/OptOutNotificationCenter.swift`, `Onboarding/OnboardingWindow.swift`, `Onboarding/ModelDownloadView.swift`, `Onboarding/ClaudeBinaryView.swift`, `Onboarding/BrowserAutomationView.swift`, `Settings/SettingsStore.swift`, `Settings/SettingsWindow.swift`, `Update/UpdaterController.swift`
**Modifiés — autres:** `Sources/E2ETrigger/main.swift`, `Resources/Info.plist`, `scripts/build-app.sh`, `scripts/fetch-sherpa.sh`, `scripts/setup-cert.sh`, `scripts/generate-appcast.sh`, `scripts/e2e-chantier-2.sh`
**Créés — docs:** `docs/known-decisions.md`
**Tests modifiés/créés:** voir chaque tâche.

---

### Task 1: WavWriter — garde `closed` + scellage sur erreurs d'écriture répétées (disque plein)

**Findings:** MEDIUM disque-plein silencieux, LOW write-after-close.

**Files:**
- Modify: `Sources/RecorderCore/Recorder/WavWriter.swift`
- Test: `Tests/RecorderCoreTests/WavWriterTests.swift`

- [ ] **Step 1: Test échouant — write après finish() est un no-op silencieux**

Ajouter à `Tests/RecorderCoreTests/WavWriterTests.swift` :

```swift
func testWriteAfterFinishIsSilentNoOp() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("t.wav")
    let w = try WavWriter(url: url, sampleRate: 16_000, channels: 1)
    let samples = [Float](repeating: 0.5, count: 256)
    try samples.withUnsafeBufferPointer { try w.write($0) }
    try w.finish()
    let sizeAfterFinish = try FileManager.default
        .attributesOfItem(atPath: url.path)[.size] as! UInt64
    // Ne doit ni throw ni écrire.
    try samples.withUnsafeBufferPointer { try w.write($0) }
    let sizeAfterLateWrite = try FileManager.default
        .attributesOfItem(atPath: url.path)[.size] as! UInt64
    XCTAssertEqual(sizeAfterFinish, sizeAfterLateWrite)
}
```

- [ ] **Step 2: Lancer le test — il doit échouer**

Run: `swift test --filter WavWriterTests/testWriteAfterFinishIsSilentNoOp 2>&1 | tail -5`
Attendu : FAIL (le write post-close tente d'écrire sur un handle fermé et throw).

- [ ] **Step 3: Implémenter dans `WavWriter.write`**

Remplacer le corps de `write(_:)` (lignes 46-59) par :

```swift
public func write(_ samples: UnsafeBufferPointer<Float>) throws {
    lock.lock(); defer { lock.unlock() }
    if sealed || closed { return }
    let addBytes = UInt64(samples.count) * UInt64(MemoryLayout<Float>.stride)
    if byteCount + addBytes > cap {
        sealed = true
        Log.recorder.error(
            "WavWriter: size cap reached at \(self.byteCount) bytes; sealing writer")
        throw WavWriterError.sizeCapReached
    }
    let data = Data(buffer: samples)
    do {
        try handle.write(contentsOf: data)
        byteCount += UInt64(data.count)
        consecutiveWriteFailures = 0
    } catch {
        // Disque plein / handle en erreur : après N échecs consécutifs on
        // scelle le writer — le flush task du Recorder voit `sealed` et
        // déclenche un stop gracieux au lieu de perdre l'audio en silence.
        consecutiveWriteFailures += 1
        if consecutiveWriteFailures >= writeFailureSealThreshold {
            sealed = true
            Log.recorder.error(
                "WavWriter: \(self.consecutiveWriteFailures) consecutive write failures (disk full?); sealing writer")
        }
        throw error
    }
}
```

Ajouter les deux propriétés à côté de `cap` (après la ligne 19) :

```swift
/// Nombre d'échecs d'écriture consécutifs avant de sceller le writer
/// (déclenche le même chemin de stop gracieux que le size cap).
internal var writeFailureSealThreshold = 50
private var consecutiveWriteFailures = 0
```

- [ ] **Step 4: Vérifier**

Run: `swift test --filter WavWriterTests 2>&1 | tail -5` → PASS (tous, y compris le test de régression du cap existant).

---

### Task 2: Normalizer — `throw` au lieu de `precondition` (H7, crash-loop au boot)

**Files:**
- Modify: `Sources/RecorderCore/Pipeline/Normalizer.swift`
- Test: créer `Tests/RecorderCoreTests/NormalizerTests.swift`

- [ ] **Step 1: Test échouant**

Créer `Tests/RecorderCoreTests/NormalizerTests.swift` :

```swift
import XCTest
import AVFoundation
@testable import RecorderCore

final class NormalizerTests: XCTestCase {
    func testUnexpectedFormatThrowsInsteadOfCrashing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // WAV 44.1 kHz stéréo — format que le recorder n'écrit jamais.
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
```

- [ ] **Step 2: Lancer — attendu : CRASH ou FAIL (precondition)**

Run: `swift test --filter NormalizerTests 2>&1 | tail -5`

- [ ] **Step 3: Implémenter**

Remplacer tout `Sources/RecorderCore/Pipeline/Normalizer.swift` par :

```swift
import AVFoundation

public enum NormalizerError: Error, Equatable {
    /// Le WAV d'entrée n'est pas au format écrit par le recorder (16 kHz mono).
    /// Erreur d'étape récupérable — surtout PAS une precondition : un fichier
    /// corrompu ne doit pas crasher l'app (crash-loop via resumePendingJobs).
    case unexpectedFormat(sampleRate: Double, channels: UInt32)
}

public enum Normalizer {
    public static func normalize(input: URL, output: URL) throws {
        let file = try AVAudioFile(forReading: input)
        let f = file.processingFormat
        guard f.sampleRate == 16_000, f.channelCount == 1 else {
            throw NormalizerError.unexpectedFormat(sampleRate: f.sampleRate,
                                                   channels: f.channelCount)
        }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.copyItem(at: input, to: output)
    }
}
```

- [ ] **Step 4: Vérifier**

Run: `swift test --filter NormalizerTests 2>&1 | tail -5` → PASS.

---

### Task 3: Merger — fallback `SPEAKER_UNKNOWN` quand la diarization est vide (M1)

**Files:**
- Modify: `Sources/RecorderCore/Pipeline/Merger.swift:33-51`
- Test: `Tests/RecorderCoreTests/MergerTests.swift`

- [ ] **Step 1: Test échouant**

Ajouter à `MergerTests.swift` :

```swift
func testEmptyDiarizationFallsBackToUnknownSpeakerInsteadOfDroppingEverything() {
    let system = [WhisperSegment(start: 0, end: 5, text: "Bonjour à tous"),
                  WhisperSegment(start: 6, end: 9, text: "On commence ?")]
    let merged = Merger.merge(mic: [], system: system, diarization: [])
    XCTAssertEqual(merged.count, 2)
    XCTAssertTrue(merged.allSatisfy { $0.speaker == "SPEAKER_UNKNOWN" })
}
```

**Attention :** un test existant dans `MergerTests.swift` vérifie l'ancien comportement (drop des segments système sans diarization). Le lire : s'il utilise `diarization: []` (vide), le mettre à jour pour attendre `SPEAKER_UNKNOWN`. S'il utilise une diarization **non vide** sans overlap, il reste valide tel quel (le drop anti-hallucination par segment est conservé).

- [ ] **Step 2: Lancer — FAIL attendu**

Run: `swift test --filter MergerTests 2>&1 | tail -5`

- [ ] **Step 3: Implémenter**

Remplacer `merge(mic:system:diarization:)` par :

```swift
public static func merge(mic: [WhisperSegment],
                         system: [WhisperSegment],
                         diarization: [DiarSegment]) -> [TranscriptSegment] {
    var out: [TranscriptSegment] = []
    for m in mic {
        out.append(.init(start: m.start, end: m.end, speaker: "MOI", text: m.text))
    }
    // Garde-fou global : si la diarization n'a RIEN détecté alors que Whisper
    // a transcrit du contenu côté système, ne pas supprimer 100 % de la parole
    // distante en silence — étiqueter SPEAKER_UNKNOWN à la place.
    let fallbackToUnknown = diarization.isEmpty && !system.isEmpty
    for s in system {
        if fallbackToUnknown {
            out.append(.init(start: s.start, end: s.end,
                             speaker: "SPEAKER_UNKNOWN", text: s.text))
            continue
        }
        // Drop segment par segment sans overlap : hallucinations Whisper sur
        // silence (comportement conservé quand la diarization a des segments).
        guard let speaker = assignSpeaker(to: s, diar: diarization) else { continue }
        out.append(.init(start: s.start, end: s.end, speaker: speaker, text: s.text))
    }
    out.sort { $0.start < $1.start }
    return out
}
```

- [ ] **Step 4: Vérifier**

Run: `swift test --filter MergerTests 2>&1 | tail -5` → PASS.

---

### Task 4: MeetingStorage — collision de slug (H6) + `Source.huddle` mort (LOW)

**Files:**
- Modify: `Sources/RecorderCore/Storage/MeetingStorage.swift:14-30`
- Modify: `Sources/RecorderCore/Storage/MeetingMetadata.swift:4-6`
- Test: `Tests/RecorderCoreTests/MeetingStorageTests.swift`

- [ ] **Step 1: Test échouant — deux meetings dans la même minute ne s'écrasent pas**

Ajouter à `MeetingStorageTests.swift` :

```swift
func testCreateMeetingSameMinuteDoesNotOverwritePrevious() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = MeetingStorage(root: root)
    let date = Date()
    let first = try storage.createMeeting(startedAt: date)
    // Marqueur dans le premier meeting pour prouver qu'il n'est pas écrasé.
    var meta1 = try storage.loadMetadata(first)
    meta1.title = "premier"
    try storage.saveMetadata(meta1, at: first)

    let second = try storage.createMeeting(startedAt: date)
    XCTAssertNotEqual(first.slug, second.slug)
    XCTAssertEqual(second.slug, "\(first.slug)_2")
    XCTAssertEqual(try storage.loadMetadata(first).title, "premier")
    XCTAssertEqual(try storage.loadMetadata(second).id, second.slug)

    let third = try storage.createMeeting(startedAt: date)
    XCTAssertEqual(third.slug, "\(first.slug)_3")
}
```

- [ ] **Step 2: Lancer — FAIL attendu** (`second.slug == first.slug`, meta écrasée)

Run: `swift test --filter MeetingStorageTests 2>&1 | tail -5`

- [ ] **Step 3: Implémenter `createMeeting` avec dédup**

Remplacer `createMeeting` (lignes 14-30) par :

```swift
public func createMeeting(startedAt: Date, timeZone: TimeZone = .current) throws -> MeetingPaths {
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    // Slug à la minute → collision possible (stop + restart dans la même
    // minute). Suffixer _2, _3… plutôt qu'écraser meta/job/WAV d'un meeting
    // dont le pipeline tourne peut-être encore.
    let base = MeetingPaths.slug(for: startedAt, timeZone: timeZone)
    var slug = base
    var n = 2
    while fileManager.fileExists(atPath: root.appendingPathComponent(slug).path) {
        slug = "\(base)_\(n)"
        n += 1
    }
    let paths = MeetingPaths(root: root, slug: slug)
    try fileManager.createDirectory(at: paths.root, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: paths.audio, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: paths.transcripts, withIntermediateDirectories: true)

    let meta = MeetingMetadata(
        id: slug, startedAt: startedAt, endedAt: nil, durationSeconds: nil,
        title: nil, source: .manual, appVersion: appVersion,
        models: .init(whisper: "large-v3", diarization: "sherpa-pyannote-3.0")
    )
    try AtomicJSON.write(meta, to: paths.meta)
    try AtomicJSON.write(JobState.fresh(), to: paths.job)
    return paths
}
```

- [ ] **Step 4: Supprimer le cas mort `Source.huddle`**

Dans `MeetingMetadata.swift:5`, remplacer :

```swift
public enum Source: String, Codable, Equatable, Sendable {
    case manual, calendar, huddle, detected
}
```

par :

```swift
public enum Source: String, Codable, Equatable, Sendable {
    case manual, calendar, detected
}
```

Puis `grep -rn "\.huddle" Sources Tests --include='*.swift'` : le seul usage légitime restant est `MeetingApp.slackHuddle` (détection) — ne pas y toucher. Si un test référence `Source.huddle`, le remplacer par `.detected`.

- [ ] **Step 5: Vérifier**

Run: `swift test --filter MeetingStorageTests 2>&1 | tail -5` puis `swift build 2>&1 | tail -3` → PASS.

---

### Task 5: JobState tolérant aux steps inconnus + RescanRunner loggue les skips (M3)

**Files:**
- Modify: `Sources/RecorderCore/Storage/JobState.swift:68-83`
- Modify: `Sources/RecorderCore/Index/RescanRunner.swift:12-27`
- Test: `Tests/RecorderCoreTests/JobStateTests.swift`

- [ ] **Step 1: Test échouant — step inconnu ignoré au décodage**

Ajouter à `JobStateTests.swift` :

```swift
func testUnknownStepInJobJsonIsIgnoredNotFatal() throws {
    // job.json écrit par une version future de l'app avec un step inconnu.
    let json = """
    {"state":"done","steps":{"normalize":{"status":"done"},
    "step_from_the_future":{"status":"done"}}}
    """.data(using: .utf8)!
    let job = try AtomicJSON.decoder.decode(JobState.self, from: json)
    XCTAssertEqual(job.state, .done)
    XCTAssertEqual(job.stepStatus(.normalize), .done)
    // Les steps connus absents sont backfillés en .pending.
    XCTAssertEqual(job.stepStatus(.notes), .pending)
}
```

**Attention :** si un test existant asserte que le décodage d'un step inconnu **throw**, inverser son attente (il documente l'ancien comportement corrigé ici).

- [ ] **Step 2: Lancer — FAIL attendu**

Run: `swift test --filter JobStateTests 2>&1 | tail -5`

- [ ] **Step 3: Implémenter — décodage tolérant**

Dans `JobState.init(from:)`, remplacer la boucle (lignes 74-80) par :

```swift
for (k, v) in raw {
    // Step inconnu (job.json écrit par une version plus récente) : on
    // l'ignore au lieu de throw — sinon le meeting disparaît du rescan.
    guard let step = JobStep(rawValue: k) else { continue }
    out[step] = v
}
```

- [ ] **Step 4: RescanRunner — logguer chaque skip**

Remplacer le corps de `rescan()` par :

```swift
public func rescan() async throws {
    for listing in try storage.listMeetings() {
        let paths = MeetingPaths(root: storage.root, slug: listing.slug)
        let meta: MeetingMetadata
        let job: JobState
        do { meta = try storage.loadMetadata(paths) } catch {
            Log.pipeline.error(
                "Rescan: skip \(listing.slug, privacy: .public) — meta.json unreadable: \(String(describing: error), privacy: .public)")
            continue
        }
        do { job = try storage.loadJob(paths) } catch {
            Log.pipeline.error(
                "Rescan: skip \(listing.slug, privacy: .public) — job.json unreadable: \(String(describing: error), privacy: .public)")
            continue
        }
        let state = job.state == .done ? "done"
                   : job.state == .failed ? "failed" : "in_progress"
        let segments: [TranscriptSegment]
        if FileManager.default.fileExists(atPath: paths.transcriptJson.path) {
            do {
                segments = try AtomicJSON.read([TranscriptSegment].self,
                                               from: paths.transcriptJson)
            } catch {
                Log.pipeline.error(
                    "Rescan: \(listing.slug, privacy: .public) — transcript.json unreadable, indexing without FTS: \(String(describing: error), privacy: .public)")
                segments = []
            }
        } else { segments = [] }
        try indexer.upsert(meta: meta, folderPath: paths.root,
                           transcriptState: state, transcript: segments)
    }
}
```

- [ ] **Step 5: Vérifier**

Run: `swift test --filter 'JobStateTests|RescanRunnerTests' 2>&1 | tail -5` → PASS.

---

### Task 6: Support partagé — `DataCollector` + petits fixes (AtomicJSON, MeetingIndexer, SherpaOnnxWrapper, Mp4Converter)

**Findings:** LOWs — tmp orphelin, formatter par ligne, NULL baseAddress, export sans timeout.

**Files:**
- Create: `Sources/RecorderCore/Support/DataCollector.swift`
- Modify: `Sources/RecorderCore/Support/AtomicJSON.swift:17-22`
- Modify: `Sources/RecorderCore/Index/MeetingIndexer.swift:49,76`
- Modify: `Sources/RecorderCore/Diarization/SherpaOnnxWrapper.swift:84-89`
- Modify: `Sources/RecorderCore/Recorder/Mp4Converter.swift`

- [ ] **Step 1: Créer `Sources/RecorderCore/Support/DataCollector.swift`**

Accumulateur thread-safe utilisé par les readabilityHandlers de pipes (ClaudeNoteGenerator, MeetDetector, ModelDownloader) :

```swift
import Foundation

/// Accumulateur de données thread-safe pour drainer les pipes de `Process`
/// en continu (readabilityHandler) et éviter le deadlock du buffer 64 KB.
final class DataCollector: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(d)
    }

    var snapshot: Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}
```

- [ ] **Step 2: AtomicJSON — nettoyer le tmp si `replaceItemAt` échoue**

Remplacer `write(_:to:)` par :

```swift
public static func write<T: Encodable>(_ value: T, to url: URL) throws {
    let data = try encoder.encode(value)
    let tmp = url.appendingPathExtension("tmp.\(UUID().uuidString)")
    do {
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    } catch {
        try? FileManager.default.removeItem(at: tmp)
        throw error
    }
}
```

- [ ] **Step 3: MeetingIndexer — formatter statique**

Ajouter dans `MeetingIndexer` (après la ligne 23) :

```swift
/// ISO8601DateFormatter est thread-safe ; une instance partagée évite une
/// allocation par ligne indexée.
private static let iso = ISO8601DateFormatter()
```

Remplacer ligne 49 `ISO8601DateFormatter().string(from: meta.startedAt)` par `Self.iso.string(from: meta.startedAt)`, et ligne 76 `ISO8601DateFormatter().date(from: startedAtStr)` par `Self.iso.date(from: startedAtStr)`.

- [ ] **Step 4: SherpaOnnxWrapper — guard sur samples vide**

Dans `process(samples:)` (ligne 84), ajouter en tête :

```swift
func process(samples: [Float]) -> [SherpaDiarSegment] {
    guard let impl else { return [] }
    // NULL + count 0 passé à l'API C = comportement indéfini côté sherpa.
    guard !samples.isEmpty else { return [] }
    ...
```

- [ ] **Step 5: Mp4Converter — timeout**

Remplacer tout le fichier par :

```swift
import AVFoundation

public enum Mp4Converter {
    public static func convert(wav: URL, to m4a: URL,
                               timeoutSeconds: TimeInterval = 600) async throws {
        let asset = AVURLAsset(url: wav)
        guard let export = AVAssetExportSession(asset: asset,
                                                presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "Onyx", code: 300,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create exporter"])
        }
        try? FileManager.default.removeItem(at: m4a)
        export.outputURL = m4a
        export.outputFileType = .m4a

        // Un export AVFoundation qui stall bloquerait l'étape cleanup pour
        // toujours (job in_progress permanent). Course export vs timeout.
        let finished = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await export.export(); return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !finished {
            export.cancelExport()
            throw NSError(domain: "Onyx", code: 302,
                          userInfo: [NSLocalizedDescriptionKey:
                            "m4a export timed out after \(Int(timeoutSeconds))s"])
        }
        if export.status != .completed {
            throw export.error ?? NSError(domain: "Onyx", code: 301)
        }
    }
}
```

- [ ] **Step 6: Vérifier**

Run: `swift build 2>&1 | tail -3` puis `swift test 2>&1 | tail -5` → PASS.

---

### Task 7: Recorder → actor avec rollback, stop best-effort, ordre système-puis-mic (H2, M2, M4, M5)

**Files:**
- Modify: `Sources/RecorderCore/Recorder/Recorder.swift` (réécriture complète)
- Modify: `Sources/RecorderCore/Recorder/MicRecorder.swift` (retirer `startHostTimeNs`, lock writer)
- Modify: `Sources/RecorderCore/Recorder/SystemAudioRecorder.swift` (idem + status CMSampleBuffer + format change)
- Modify: `Tests/RecorderCoreTests/RecorderCancelTests.swift` (adaptation actor : `await`)

Le chemin audio réel n'est pas unit-testable (permissions). Vérification = compilation + tests existants adaptés + test E2E final (Task 22).

- [ ] **Step 1: Réécrire `Recorder.swift`**

Contenu complet :

```swift
import Foundation

@available(macOS 13.0, *)
public actor Recorder {
    public enum State: String { case idle, recording, stopping }

    public enum RecorderError: Error, Equatable {
        /// start() appelé alors qu'un enregistrement est déjà en cours.
        /// Erreur récupérable — surtout pas une precondition (crash prod).
        case notIdle
        case notRecording
    }

    public private(set) var state: State = .idle
    public private(set) var paths: MeetingPaths?
    public private(set) var startedAt: Date?

    /// Called (once) when either the mic or system WAV writer has been sealed
    /// (size cap OU erreurs d'écriture répétées type disque plein). Wiré par
    /// AppState vers un stop gracieux via l'orchestrateur.
    private var onSizeCapReached: (@Sendable () -> Void)?
    public func setSizeCapHandler(_ h: @escaping @Sendable () -> Void) {
        onSizeCapReached = h
    }

    private let storage: MeetingStorage
    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()
    private var flushTask: Task<Void, Never>?

    public init(storage: MeetingStorage) { self.storage = storage }

    public func start() async throws -> MeetingPaths {
        guard state == .idle else { throw RecorderError.notIdle }
        let now = Date()
        let paths = try storage.createMeeting(startedAt: now)
        self.paths = paths; self.startedAt = now
        state = .recording

        do {
            // Système d'abord : SCShareableContent + startCapture est la
            // partie lente (0,5–2 s). Démarrer le mic après garde les deux
            // timelines WAV alignées à quelques ms près (le Merger trie par
            // timestamps relatifs au début de chaque fichier).
            try await system.start(writingTo: paths.systemWav)
            try mic.start(writingTo: paths.micWav)
        } catch {
            // Rollback : ne jamais laisser un recorder à moitié démarré
            // (mic orphelin + state .recording = crash au start suivant).
            try? mic.stop()
            try? await system.stop()
            try? FileManager.default.removeItem(at: paths.root)
            self.paths = nil; self.startedAt = nil
            state = .idle
            throw error
        }

        // Flush périodique du header WAV : un crash mid-recording laisse
        // quand même un fichier lisible.
        flushTask = Task { [weak self] in
            var capReported = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { return }
                guard let self else { return }
                await self.flushHeaders()
                if !capReported, await self.anyWriterSealed() {
                    capReported = true
                    Log.recorder.error(
                        "Recorder: a writer sealed (size cap or write failures); forwarding stop request")
                    await self.fireSizeCap()
                    // Ne PAS return : continuer à flusher les headers des
                    // deux fichiers jusqu'au stop effectif.
                }
            }
        }

        Log.recorder.info("Recorder started for \(paths.slug, privacy: .public)")
        return paths
    }

    public func stop() async throws -> MeetingPaths {
        guard state == .recording, let paths, let startedAt else {
            throw RecorderError.notRecording
        }
        state = .stopping
        flushTask?.cancel()
        await flushTask?.value
        flushTask = nil

        // Best-effort : même si un côté échoue à finaliser, l'autre doit être
        // finalisé et le job persisté. L'audio déjà écrit reste exploitable
        // (headers flushés périodiquement). Surtout : TOUJOURS revenir à .idle.
        do { try mic.stop() } catch {
            Log.recorder.error("mic.stop failed: \(String(describing: error), privacy: .public)")
        }
        do { try await system.stop() } catch {
            Log.recorder.error("system.stop failed: \(String(describing: error), privacy: .public)")
        }

        var persistError: Error?
        do {
            var meta = try storage.loadMetadata(paths)
            let end = Date()
            meta.endedAt = end
            meta.durationSeconds = Int(end.timeIntervalSince(startedAt))
            try storage.saveMetadata(meta, at: paths)
            var job = try storage.loadJob(paths)
            job.state = .normalizing
            try storage.saveJob(job, at: paths)
        } catch {
            persistError = error
            Log.recorder.error("stop persistence failed: \(String(describing: error), privacy: .public)")
        }

        self.paths = nil; self.startedAt = nil
        state = .idle
        if let persistError { throw persistError }
        Log.recorder.info("Recorder stopped for \(paths.slug, privacy: .public)")
        return paths
    }

    /// Cancels an ongoing recording — stops capture without running the
    /// pipeline and deletes the meeting folder. Used by the opt-out flow.
    public func cancel(paths: MeetingPaths) async throws {
        flushTask?.cancel()
        await flushTask?.value
        flushTask = nil
        do { try mic.stop() } catch {
            Log.recorder.warning("mic.stop on cancel: \(String(describing: error), privacy: .public)")
        }
        do { try await system.stop() } catch {
            Log.recorder.warning("system.stop on cancel: \(String(describing: error), privacy: .public)")
        }
        try FileManager.default.removeItem(at: paths.root)
        self.paths = nil
        self.startedAt = nil
        state = .idle
        Log.recorder.info("Recorder cancelled for \(paths.slug, privacy: .public)")
    }

    // MARK: - Flush task helpers (isolés sur l'actor)

    private func flushHeaders() {
        try? mic.flushHeader()
        try? system.flushHeader()
    }
    private func anyWriterSealed() -> Bool {
        mic.sizeCapReached || system.sizeCapReached
    }
    private func fireSizeCap() { onSizeCapReached?() }
}
```

- [ ] **Step 2: MicRecorder — retirer le host time mort + lock writer**

Dans `MicRecorder.swift` :
1. Supprimer les lignes 14 (`private var startHostTime: UInt64 = 0`) et 18 (`public var startHostTimeNs...`).
2. Dans le tap (ligne 38-42), retirer `if self.startHostTime == 0 { self.startHostTime = when.hostTime }` ; la closure devient `{ [weak self] buf, _ in guard let self else { return }; self.process(inputBuffer: buf) }`.
3. Dans le log de start (ligne 44-45), retirer `hostTime=...` : `Log.recorder.info("MicRecorder started (url=\(url.lastPathComponent, privacy: .public))")`.
4. Protéger `writer` (lu sur le thread du tap, écrit au stop) :

```swift
private let writerLock = NSLock()
private var writer: WavWriter?   // toujours accéder via writerLock

private func currentWriter() -> WavWriter? {
    writerLock.lock(); defer { writerLock.unlock() }
    return writer
}
```

Dans `start` : `writerLock.lock(); writer = try WavWriter(...); writerLock.unlock()` — attention, `try` dans la section verrouillée : écrire

```swift
let w = try WavWriter(url: url, sampleRate: Int(config.sampleRate), channels: 1)
writerLock.lock(); writer = w; writerLock.unlock()
```

Dans `stop()` :

```swift
public func stop() throws {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    writerLock.lock(); let w = writer; writer = nil; writerLock.unlock()
    try w?.finish()
    Log.recorder.info("MicRecorder stopped")
}
```

Dans `flushHeader()` : `try currentWriter()?.flushHeader()`.
Dans `process(inputBuffer:)` : remplacer `guard let converter, let writer else { return }` par `guard let converter, let writer = currentWriter() else { return }`.
Dans `sizeCapReached` : `currentWriter()?.sealed ?? false`.

- [ ] **Step 3: SystemAudioRecorder — mêmes changements + status CMSampleBuffer + format change**

1. Supprimer lignes 11 (`startHostTime`), 13 (`startHostTimeNs`) et le bloc lignes 57-60 (`if startHostTime == 0 { ... }`).
2. Même pattern `writerLock`/`currentWriter()` que MicRecorder : `stream(_:didOutputSampleBuffer:)` utilise `currentWriter()`, `stop()` fait le swap sous lock avant `finish()`, `flushHeader`/`sizeCapReached` passent par `currentWriter()`.
3. Dans `pcmBuffer(from:)`, gérer le changement de format en cours de stream et vérifier le status de copie — remplacer le corps par :

```swift
private func pcmBuffer(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
    guard let fmtDesc = CMSampleBufferGetFormatDescription(sb),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc)?.pointee
    else { return nil }
    // Si le format change en cours de stream (rare mais possible), rebâtir
    // le converter au lieu d'interpréter les buffers avec l'ancien format.
    if let sf = sourceFormat,
       sf.sampleRate != asbd.mSampleRate
        || sf.channelCount != asbd.mChannelsPerFrame {
        sourceFormat = nil
    }
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
    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
        sb, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList)
    guard status == noErr else { return nil }
    return buf
}
```

- [ ] **Step 4: Adapter `RecorderCancelTests.swift`**

Lire le fichier ; tout appel `recorder.xxx` devient `await recorder.xxx` (ou `try await`), et les lectures de `recorder.state` deviennent `await recorder.state`. Ne pas changer la sémantique des assertions.

- [ ] **Step 5: Corriger les call-sites qui ne compilent plus**

`RecorderSession.swift` compile déjà (`try await recorder.start()/stop()/cancel(paths:)`). `AppState.swift:76` (`recorder.onSizeCapReached = {...}`) sera réécrit en Task 13 — pour compiler maintenant, remplacer temporairement le bloc lignes 75-80 par :

```swift
let capOrch = orchestrator
Task { [recorder] in
    await recorder.setSizeCapHandler {
        Task { @MainActor in
            try? await capOrch.manualStop()
        }
    }
}
```

- [ ] **Step 6: Vérifier**

Run: `swift build 2>&1 | tail -3` puis `swift test 2>&1 | tail -10` → PASS.

---

### Task 8: ClaudeNoteGenerator — drainage continu des pipes + stdin non bloquant (H3)

**Files:**
- Modify: `Sources/RecorderCore/Notes/ClaudeNoteGenerator.swift:37-77`
- Test: `Tests/RecorderCoreTests/ClaudeNoteGeneratorTests.swift`

- [ ] **Step 1: Test échouant — sortie > 64 KB**

Ajouter à `ClaudeNoteGeneratorTests.swift` (suivre le pattern des tests existants qui créent un faux binaire bash ; adapter les noms d'helpers à ceux du fichier) :

```swift
func testLargeOutputDoesNotDeadlockOnPipeBuffer() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("transcripts"),
                                            withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let paths = MeetingPaths(root: dir.deletingLastPathComponent(),
                             slug: dir.lastPathComponent)
    try "# transcript".data(using: .utf8)!.write(to: paths.transcriptMd)

    // Faux claude : avale stdin puis écrit ~200 KB sur stdout (>> buffer 64 KB).
    let fake = dir.appendingPathComponent("fake-claude.sh")
    let script = """
    #!/bin/bash
    cat > /dev/null
    for i in $(seq 1 3200); do printf '%064d\\n' "$i"; done
    """
    try script.data(using: .utf8)!.write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                          ofItemAtPath: fake.path)

    // Timeout court : si les pipes ne sont pas drainées, l'ancien code
    // bloquait le child → timedOut. Le nouveau code doit finir vite.
    let gen = ClaudeNoteGenerator(timeoutSeconds: 30)
    try await gen.generate(paths: paths, level: .synthese, binary: fake)
    let notes = try String(contentsOf: paths.notesFile(.synthese), encoding: .utf8)
    XCTAssertGreaterThan(notes.count, 100_000)
}
```

- [ ] **Step 2: Lancer — FAIL attendu** (GenerationError.timedOut après 30 s)

Run: `swift test --filter ClaudeNoteGeneratorTests/testLargeOutputDoesNotDeadlockOnPipeBuffer 2>&1 | tail -5`

- [ ] **Step 3: Réécrire `runClaude`**

Remplacer `runClaude(binary:cwd:stdin:)` (lignes 37-77) par :

```swift
private func runClaude(binary: URL, cwd: URL, stdin: String) async throws -> String {
    // SIGPIPE process-wide : si le child meurt pendant qu'on écrit son stdin,
    // write(2) doit retourner EPIPE (erreur catchable) au lieu de tuer l'app.
    Self.ignoreSigpipeOnce
    let proc = Process()
    proc.executableURL = binary
    proc.arguments = ["-p", "--output-format", "text"]
    proc.currentDirectoryURL = cwd

    let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
    proc.standardInput = stdinPipe
    proc.standardOutput = stdoutPipe
    proc.standardError = stderrPipe

    // Drainage CONTINU des deux pipes pendant que le process tourne. Sans ça,
    // au-delà de 64 KB de sortie le child bloque en écriture, ne termine
    // jamais, et le timeout SIGKILL fait perdre les notes des longs meetings.
    let outCollector = DataCollector()
    let errCollector = DataCollector()
    stdoutPipe.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        if d.isEmpty { h.readabilityHandler = nil } else { outCollector.append(d) }
    }
    stderrPipe.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        if d.isEmpty { h.readabilityHandler = nil } else { errCollector.append(d) }
    }

    try proc.run()

    // stdin (transcript complet, souvent > 64 KB) écrit hors du pool
    // coopératif ; EPIPE = child mort prématurément, l'exit code parlera.
    let stdinData = stdin.data(using: .utf8) ?? Data()
    DispatchQueue.global(qos: .utility).async {
        let fh = stdinPipe.fileHandleForWriting
        do { try fh.write(contentsOf: stdinData) } catch {
            Log.pipeline.warning(
                "claude stdin write interrupted: \(String(describing: error), privacy: .public)")
        }
        try? fh.close()
    }

    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while proc.isRunning {
        if Date() >= deadline {
            proc.terminate()
            try? await Task.sleep(nanoseconds: 200_000_000)
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw GenerationError.timedOut
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    // Drainer le reliquat éventuel après l'exit puis détacher les handlers.
    stdoutPipe.fileHandleForReading.readabilityHandler = nil
    stderrPipe.fileHandleForReading.readabilityHandler = nil
    if let rest = try? stdoutPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
        outCollector.append(rest)
    }
    if let rest = try? stderrPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
        errCollector.append(rest)
    }

    guard proc.terminationStatus == 0 else {
        let err = String(data: errCollector.snapshot, encoding: .utf8) ?? ""
        throw GenerationError.nonZeroExit(code: proc.terminationStatus, stderr: err)
    }
    return String(data: outCollector.snapshot, encoding: .utf8) ?? ""
}

/// Exécuté une seule fois : ignore SIGPIPE pour tout le process.
private static let ignoreSigpipeOnce: Void = {
    signal(SIGPIPE, SIG_IGN)
}()
```

- [ ] **Step 4: Vérifier**

Run: `swift test --filter ClaudeNoteGeneratorTests 2>&1 | tail -5` → PASS (nouveaux + existants : stdin passthrough, timeout, exit non nul).

---

### Task 9: MeetDetector (H10) + SlackHuddleDetector (M4) + tar stderr ModelDownloader (LOW)

**Files:**
- Modify: `Sources/RecorderCore/Detection/MeetDetector.swift:57-81`
- Modify: `Sources/RecorderCore/Detection/SlackHuddleDetector.swift`
- Modify: `Sources/RecorderCore/Models/ModelDownloader.swift:80-95` (extractTarBz2)

- [ ] **Step 1: MeetDetector — réécrire `jxaURLs` (drainage + timeout + logs)**

Remplacer `jxaURLs(forBundle:)` par :

```swift
static func jxaURLs(forBundle bundle: String, timeoutSeconds: TimeInterval = 10) -> [String] {
    let script = """
    function run() {
      try {
        var app = Application("\(bundle)");
        if (!app.running()) return "";
        var urls = [];
        app.windows().forEach(function(w) {
          try { w.tabs().forEach(function(t) { urls.push(t.url()); }); } catch(e) {}
        });
        return urls.join("\\n");
      } catch(e) { return ""; }
    }
    """
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-l", "JavaScript", "-e", script]
    let out = Pipe(); let err = Pipe()
    proc.standardOutput = out; proc.standardError = err

    // Drainage continu : > 64 KB d'URLs d'onglets deadlockait waitUntilExit
    // et gelait la boucle de détection pour toujours.
    let collector = DataCollector()
    out.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        if d.isEmpty { h.readabilityHandler = nil } else { collector.append(d) }
    }
    err.fileHandleForReading.readabilityHandler = { h in _ = h.availableData }

    do { try proc.run() } catch {
        Log.recorder.error(
            "MeetDetector: osascript launch failed: \(String(describing: error), privacy: .public)")
        return []
    }

    // Timeout : la 1re exécution peut être suspendue sur le prompt Apple
    // Events — sans timeout, la détection restait gelée indéfiniment.
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while proc.isRunning && Date() < deadline { usleep(50_000) }
    if proc.isRunning {
        kill(proc.processIdentifier, SIGKILL)
        Log.recorder.error(
            "MeetDetector: osascript timed out for \(bundle, privacy: .public) (Automation permission prompt pending?)")
        return []
    }
    out.fileHandleForReading.readabilityHandler = nil
    err.fileHandleForReading.readabilityHandler = nil
    if let rest = try? out.fileHandleForReading.readToEnd(), !rest.isEmpty {
        collector.append(rest)
    }
    guard proc.terminationStatus == 0 else {
        Log.recorder.warning(
            "MeetDetector: osascript exit \(proc.terminationStatus) for \(bundle, privacy: .public) — Automation permission denied?")
        return []
    }
    guard let s = String(data: collector.snapshot, encoding: .utf8), !s.isEmpty else { return [] }
    return s.split(separator: "\n").map(String.init)
}
```

- [ ] **Step 2: SlackHuddleDetector — code stable + log permission**

Remplacer `currentHuddleWindowIDs` et la boucle par un code constant (une seule huddle possible à la fois ; le windowID changeait à chaque recréation de fenêtre et coupait l'enregistrement en plein huddle). Remplacer tout le corps de la classe (garder `app`, `pollSeconds`, `slackBundle`, `init`) :

```swift
public func events() -> AsyncStream<CallLifecycle> {
    AsyncStream { continuation in
        let task = Task.detached { [pollSeconds, slackBundle] in
            var active = false
            var warnedNoPermission = false
            while !Task.isCancelled {
                if !CGPreflightScreenCaptureAccess() {
                    // Sans Screen Recording, kCGWindowName est toujours vide :
                    // le détecteur serait silencieusement inopérant.
                    if !warnedNoPermission {
                        warnedNoPermission = true
                        Log.recorder.warning(
                            "SlackHuddleDetector: Screen Recording permission missing — huddle detection disabled")
                    }
                } else {
                    let current = Self.hasActiveHuddle(slackBundle: slackBundle)
                    if current && !active { continuation.yield(.started(code: "huddle")) }
                    if !current && active { continuation.yield(.ended(code: "huddle")) }
                    active = current
                }
                try? await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

static func hasActiveHuddle(slackBundle: String) -> Bool {
    let slackRunning = NSWorkspace.shared.runningApplications
        .contains { $0.bundleIdentifier == slackBundle }
    guard slackRunning else { return false }
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windows = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
    else { return false }
    for w in windows {
        guard let owner = w[kCGWindowOwnerName as String] as? String,
              owner == "Slack",
              let title = w[kCGWindowName as String] as? String else { continue }
        if title.range(of: "Huddle", options: .caseInsensitive) != nil { return true }
    }
    return false
}
```

**Attention tests :** `DetectionCoordinatorTests` ou d'autres peuvent référencer `currentHuddleWindowIDs` — `grep -rn "currentHuddleWindowIDs" Tests/` et adapter vers `hasActiveHuddle` si besoin.

- [ ] **Step 3: ModelDownloader.extractTarBz2 — drainer stderr avant waitUntilExit**

Remplacer la lecture de stderr (lignes 85-93) :

```swift
let err = Pipe()
process.standardError = err
let errCollector = DataCollector()
err.fileHandleForReading.readabilityHandler = { h in
    let d = h.availableData
    if d.isEmpty { h.readabilityHandler = nil } else { errCollector.append(d) }
}
try process.run()
process.waitUntilExit()
err.fileHandleForReading.readabilityHandler = nil
if process.terminationStatus != 0 {
    let msg = String(data: errCollector.snapshot, encoding: .utf8) ?? "unknown tar error"
    throw NSError(domain: "ModelDownloader", code: Int(process.terminationStatus),
                  userInfo: [NSLocalizedDescriptionKey: "tar failed: \(msg)"])
}
```

- [ ] **Step 4: Vérifier**

Run: `swift build 2>&1 | tail -3` puis `swift test 2>&1 | tail -5` → PASS.

---

### Task 10: DetectionCoordinator — fix de la race du debounce + horloge injectable (H11, M-tests)

**Files:**
- Modify: `Sources/RecorderCore/Detection/DetectionCoordinator.swift`
- Test: `Tests/RecorderCoreTests/DetectionCoordinatorTests.swift`

- [ ] **Step 1: Test échouant — un `.started` pendant la fenêtre debounce annule bien le `.ended` même si le sleep est déjà écoulé**

La race : le task de debounce a passé son `Task.isCancelled` mais n'a pas encore exécuté `emitEnded` ; un `.started` arrive, est avalé (flicker suppression), puis `emitEnded` part quand même → `.ended` fantôme qui coupe l'appel. Fix : `emitEnded` vérifie un token. Test avec sleeper injecté contrôlable :

```swift
func testStartedArrivingAfterDebounceElapsedButBeforeEmitDoesNotEmitGhostEnded() async throws {
    // Sleeper contrôlé : le debounce "dort" jusqu'à ce qu'on le libère.
    let gate = AsyncStream<Void>.makeStream()
    let coordinator = DetectionCoordinator(
        detectors: [],
        debounceEndedSeconds: 3,
        sleeper: { _ in
            var it = gate.stream.makeAsyncIterator()
            _ = await it.next()
        })
    var events: [CallEvent] = []
    let stream = coordinator.events()
    let consume = Task {
        for await ev in stream { events.append(ev) }
    }
    // .started initial → émis.
    await coordinator.ingest(.started(code: "abc"), from: .meet)
    // .ended → debounce armé (dort sur le gate).
    await coordinator.ingest(.ended(code: "abc"), from: .meet)
    // Flicker : .started re-arrive AVANT que le debounce n'émette.
    await coordinator.ingest(.started(code: "abc"), from: .meet)
    // Libérer le sleeper : l'ancien task de debounce se réveille…
    gate.continuation.yield()
    gate.continuation.finish()
    try await Task.sleep(nanoseconds: 300_000_000)
    consume.cancel()
    // …mais ne doit PAS émettre de .ended fantôme.
    XCTAssertEqual(events.map(\.kind), [.started])
}
```

Note : ce test nécessite d'exposer `handle` sous un nom testable — ajouter une méthode `ingest` (voir Step 3). Adapter si les tests existants ont déjà un pattern d'injection d'événements (lire le fichier de tests d'abord et réutiliser leur approche).

- [ ] **Step 2: Lancer — FAIL attendu** (`[.started]` vs `[.started, .ended]`)

- [ ] **Step 3: Implémenter — token par debounce + sleeper injectable**

Remplacer le contenu de la classe :

```swift
public actor DetectionCoordinator {
    public typealias Sleeper = @Sendable (TimeInterval) async -> Void

    private let detectors: [any MeetingAppDetector]
    private let debounceEndedSeconds: TimeInterval
    private let sleeper: Sleeper

    /// token identifie LE task de debounce actif pour une clé. `emitEnded`
    /// ne tire que si son token est toujours le courant — sinon un `.started`
    /// arrivé entre l'expiration du sleep et l'émission produisait un
    /// `.ended` fantôme qui coupait l'enregistrement en plein appel.
    private var pendingEnded: [String: (task: Task<Void, Never>, token: UUID)] = [:]

    public init(detectors: [any MeetingAppDetector],
                debounceEndedSeconds: TimeInterval = 3,
                sleeper: @escaping Sleeper = { seconds in
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }) {
        self.detectors = detectors
        self.debounceEndedSeconds = debounceEndedSeconds
        self.sleeper = sleeper
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
        }
        continuation.finish()
    }

    /// Point d'entrée testable (les tests injectent des événements sans
    /// passer par un vrai détecteur).
    public func ingest(_ ev: CallLifecycle, from app: MeetingApp) {
        // NB: les tests fournissent leur propre sink via events(); si le
        // fichier de tests existant utilise déjà un autre mécanisme
        // d'injection, conserver ce mécanisme et brancher handle dessus.
        fatalError("ingest requires a sink — see handleForTesting below")
    }

    private func handle(_ ev: CallLifecycle,
                        from app: MeetingApp,
                        sink: AsyncStream<CallEvent>.Continuation) {
        switch ev {
        case .started(let code):
            let key = "\(app.rawValue):\(code)"
            if let pending = pendingEnded.removeValue(forKey: key) {
                // Flicker suppression: cancel the pending .ended and do NOT
                // re-emit .started.
                pending.task.cancel()
                return
            }
            sink.yield(CallEvent(app: app, kind: .started, code: code))

        case .ended(let code):
            let key = "\(app.rawValue):\(code)"
            pendingEnded[key]?.task.cancel()
            let token = UUID()
            let delaySeconds = debounceEndedSeconds
            let sleep = sleeper
            let task = Task { [weak self] in
                await sleep(delaySeconds)
                if Task.isCancelled { return }
                await self?.emitEnded(app: app, code: code, token: token, sink: sink)
            }
            pendingEnded[key] = (task, token)
        }
    }

    private func emitEnded(app: MeetingApp,
                           code: String,
                           token: UUID,
                           sink: AsyncStream<CallEvent>.Continuation) {
        let key = "\(app.rawValue):\(code)"
        // La vérification qui ferme la race : si un .started est passé entre
        // temps, pendingEnded[key] a été retiré (ou remplacé) — ne rien émettre.
        guard pendingEnded[key]?.token == token else { return }
        pendingEnded[key] = nil
        sink.yield(CallEvent(app: app, kind: .ended, code: code))
    }
}
```

**Important :** lire `Tests/RecorderCoreTests/DetectionCoordinatorTests.swift` AVANT d'implémenter : les tests existants injectent probablement des événements via un `FakeDetector`. Dans ce cas, supprimer la méthode `ingest` placeholder ci-dessus et écrire le nouveau test avec un `FakeDetector` + le `sleeper` injecté (le gate remplace le vrai temps). L'essentiel du fix est : tuple `(task, token)` + le guard dans `emitEnded` + le paramètre `sleeper`.

- [ ] **Step 4: Vérifier**

Run: `swift test --filter DetectionCoordinatorTests 2>&1 | tail -8` → PASS (nouveaux + anciens ; les anciens utilisent le sleeper par défaut, comportement inchangé).

---

### Task 11: CalendarWatcher / CalendarMatcher — lead time, purge à endDate, all-day, log accès (H5, LOWs)

**Files:**
- Modify: `Sources/RecorderCore/Calendar/MatchedEvent.swift` (champ `isAllDay`)
- Modify: `Sources/RecorderCore/Calendar/CalendarMatcher.swift`
- Modify: `Sources/RecorderCore/Calendar/CalendarWatcher.swift`
- Test: `Tests/RecorderCoreTests/CalendarMatchRulesTests.swift`

- [ ] **Step 1: Test échouant — all-day rejeté**

Ajouter à `CalendarMatchRulesTests.swift` (réutiliser les helpers existants de construction de `CalendarEventInput` s'il y en a — sinon) :

```swift
func testAllDayEventNeverMatches() {
    let matcher = CalendarMatcher(whitelistedCalendarIds: ["cal1"])
    let input = CalendarEventInput(
        id: "e1", title: "Offsite", calendarId: "cal1", attendeeCount: 5,
        notes: "https://meet.google.com/abc-defg-hij", location: nil,
        startDate: Date(), endDate: Date().addingTimeInterval(86_400),
        isAllDay: true)
    XCTAssertNil(matcher.match(input))
}
```

- [ ] **Step 2: `CalendarEventInput` — ajouter `isAllDay`**

Dans `MatchedEvent.swift`, remplacer `CalendarEventInput` par :

```swift
public struct CalendarEventInput: Sendable, Equatable {
    public let id: String
    public let title: String
    public let calendarId: String
    public let attendeeCount: Int
    public let notes: String?
    public let location: String?
    public let startDate: Date
    public let endDate: Date
    public let isAllDay: Bool

    public init(id: String, title: String, calendarId: String,
                attendeeCount: Int, notes: String?, location: String?,
                startDate: Date, endDate: Date, isAllDay: Bool = false) {
        self.id = id; self.title = title; self.calendarId = calendarId
        self.attendeeCount = attendeeCount; self.notes = notes
        self.location = location; self.startDate = startDate; self.endDate = endDate
        self.isAllDay = isAllDay
    }
}
```

(Valeur par défaut `false` → les tests existants compilent sans modification.)

- [ ] **Step 3: `CalendarMatcher.match` — rejeter all-day**

Ajouter après le guard whitelist (ligne 17) :

```swift
// Un all-day avec lien Meet déclencherait un enregistrement à n'importe
// quel poll de la journée.
guard !ev.isAllDay else { return nil }
```

- [ ] **Step 4: `CalendarWatcher` — lead time + purge à endDate + log accès**

Remplacer le fichier complet :

```swift
import Foundation
import EventKit

public final class CalendarWatcher {
    private let store: EKEventStore
    private let horizonMinutes: TimeInterval
    private let pollSeconds: TimeInterval
    private let leadSeconds: TimeInterval

    public init(store: EKEventStore = EKEventStore(),
                horizonMinutes: TimeInterval = 15,
                pollSeconds: TimeInterval = 60,
                leadSeconds: TimeInterval = 120) {
        self.store = store
        self.horizonMinutes = horizonMinutes
        self.pollSeconds = pollSeconds
        self.leadSeconds = leadSeconds
    }

    /// Requests full access to events. Returns true if granted.
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
            Log.recorder.error(
                "CalendarWatcher.requestAccess failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    public func matches(matcher: CalendarMatcher) -> AsyncStream<MatchedEvent> {
        AsyncStream { continuation in
            let task = Task.detached { [horizonMinutes, pollSeconds, leadSeconds, store] in
                // armed[key] = endDate de l'événement. La clé reste armée
                // jusqu'à la FIN de l'événement : l'ancienne purge à
                // startDate+300s re-yieldait le même événement toutes les
                // 60 s pour toute réunion > 5 min (redémarrage fantôme après
                // un stop manuel).
                var armed: [String: Date] = [:]
                while !Task.isCancelled {
                    let now = Date()
                    let horizon = now.addingTimeInterval(horizonMinutes * 60)
                    let predicate = store.predicateForEvents(withStart: now,
                                                             end: horizon,
                                                             calendars: nil)
                    for ekEvent in store.events(matching: predicate) {
                        guard let id = ekEvent.eventIdentifier else { continue }
                        let key = "\(id)|\(Int(ekEvent.startDate.timeIntervalSince1970))"
                        if armed[key] != nil { continue }
                        // Ne déclencher qu'à l'approche réelle du début —
                        // pas 15 minutes avant (l'horizon sert seulement à
                        // découvrir les événements).
                        guard now >= ekEvent.startDate.addingTimeInterval(-leadSeconds)
                        else { continue }
                        let input = CalendarEventInput(
                            id: id,
                            title: ekEvent.title ?? "",
                            calendarId: ekEvent.calendar.calendarIdentifier,
                            attendeeCount: (ekEvent.attendees?.count ?? 0) + 1,
                            notes: ekEvent.notes,
                            location: ekEvent.location,
                            startDate: ekEvent.startDate,
                            endDate: ekEvent.endDate,
                            isAllDay: ekEvent.isAllDay
                        )
                        if let matched = matcher.match(input) {
                            continuation.yield(matched)
                            armed[key] = ekEvent.endDate
                                ?? ekEvent.startDate.addingTimeInterval(3600)
                        }
                    }
                    // Purge : 5 min après la fin de l'événement.
                    let purgeNow = Date()
                    armed = armed.filter { $0.value.addingTimeInterval(300) > purgeNow }
                    try? await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func availableCalendars() -> [EKCalendar] {
        store.calendars(for: .event)
    }
}
```

- [ ] **Step 5: Vérifier**

Run: `swift test --filter CalendarMatchRulesTests 2>&1 | tail -5` puis `swift build 2>&1 | tail -3` → PASS.

---

### Task 12: AutoTriggerOrchestrator — états transitionnels, auto-stop calendrier, transitions UI, slug unifié (C1, C3, H1-partie, H4, M5, LOW-casse)

**Files:**
- Modify: `Sources/RecorderCore/Autotrigger/AutoTriggerOrchestrator.swift` (réécriture complète)
- Modify: `Sources/RecorderCore/Autotrigger/RecorderSession.swift` (protocol : `start` retourne le slug réel)
- Test: `Tests/RecorderCoreTests/AutoTriggerOrchestratorTests.swift`

- [ ] **Step 1: Lire `AutoTriggerOrchestratorTests.swift` en entier** (comprendre le `FakeSession` existant avant de le modifier).

- [ ] **Step 2: Tests échouants — réentrance, wedge sur stop, auto-stop, casse des codes**

Adapter le `FakeSession` existant au nouveau protocole (`start` retourne `String` = `meta.id` ; ajouter des hooks configurables). Ajouter :

```swift
func testConcurrentStartsOnlyStartOneRecording() async throws {
    // session.start lente : la suspension d'acteur rendait possible un
    // double start → precondition crash dans Recorder.
    let session = FakeSession()
    session.startDelayNanos = 200_000_000
    let orch = AutoTriggerOrchestrator(session: session)
    let match = MatchedEvent(id: "ev1", title: "Standup",
                             startDate: Date(), endDate: Date().addingTimeInterval(1800),
                             meetURL: URL(string: "https://meet.google.com/abc-defg-hij")!,
                             calendarId: "cal1")
    let ev = CallEvent(app: .meet, kind: .started, code: "abc-defg-hij")
    async let a: Void = { try? await orch.onCalendarEvent(match) }()
    async let b: Void = { try? await orch.onCallEvent(ev) }()
    _ = await (a, b)
    XCTAssertEqual(session.startCallCount, 1)
}

func testStopFailureStillReturnsToIdle() async throws {
    let session = FakeSession()
    session.stopError = NSError(domain: "test", code: 1)
    let orch = AutoTriggerOrchestrator(session: session)
    try await orch.manualStart()
    do { try await orch.manualStop(); XCTFail("expected throw") } catch {}
    // L'orchestrateur ne doit PAS rester wedgé en .recording.
    let state = await orch.state
    XCTAssertEqual(state, .idle)
    // Un nouveau start doit fonctionner.
    try await orch.manualStart()
    XCTAssertEqual(session.startCallCount, 2)
}

func testCalendarOnlyRecordingAutoStopsAtEndDatePlusMargin() async throws {
    let session = FakeSession()
    // endDate déjà passée + marge nulle → l'auto-stop tire immédiatement.
    let orch = AutoTriggerOrchestrator(session: session, autoStopMarginSeconds: 0)
    let match = MatchedEvent(id: "ev1", title: "Standup",
                             startDate: Date().addingTimeInterval(-1800),
                             endDate: Date().addingTimeInterval(0.1),
                             meetURL: URL(string: "https://meet.google.com/abc-defg-hij")!,
                             calendarId: "cal1")
    try await orch.onCalendarEvent(match)
    try await Task.sleep(nanoseconds: 500_000_000)
    XCTAssertEqual(session.stopCallCount, 1)
    let state = await orch.state
    XCTAssertEqual(state, .idle)
}

func testMeetCodeLinkingIsCaseInsensitive() async throws {
    let session = FakeSession()
    let orch = AutoTriggerOrchestrator(session: session)
    let match = MatchedEvent(id: "ev1", title: "Standup",
                             startDate: Date(), endDate: Date().addingTimeInterval(1800),
                             meetURL: URL(string: "https://meet.google.com/ABC-DEFG-HIJ")!,
                             calendarId: "cal1")
    await orch.registerRecentMatchedEvent(match)
    try await orch.onCallEvent(CallEvent(app: .meet, kind: .started, code: "abc-defg-hij"))
    XCTAssertEqual(session.lastStartedMeta?.title, "Standup")
    XCTAssertEqual(session.lastStartedMeta?.calendarEventId, "ev1")
}
```

`FakeSession` doit ressembler à (fusionner avec l'existant, ne pas dupliquer) :

```swift
final class FakeSession: RecordingSession, @unchecked Sendable {
    private let lock = NSLock()
    var startDelayNanos: UInt64 = 0
    var stopError: Error?
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var cancelCallCount = 0
    private(set) var lastStartedMeta: MeetingMetadata?

    func start(meta: MeetingMetadata) async throws -> String {
        lock.lock(); startCallCount += 1; lastStartedMeta = meta; lock.unlock()
        if startDelayNanos > 0 { try? await Task.sleep(nanoseconds: startDelayNanos) }
        return meta.id
    }
    func stop() async throws {
        lock.lock(); stopCallCount += 1; let err = stopError; lock.unlock()
        if let err { throw err }
    }
    func cancel() async throws { lock.lock(); cancelCallCount += 1; lock.unlock() }
    func patchMeta(_ mut: @Sendable (inout MeetingMetadata) -> Void) async throws {}
}
```

- [ ] **Step 3: Lancer — FAIL/erreurs de compilation attendues**

- [ ] **Step 4: Réécrire `AutoTriggerOrchestrator.swift`**

Contenu complet :

```swift
import Foundation

public protocol RecordingSession: Sendable {
    /// Retourne le slug RÉEL du meeting créé (source de vérité unique —
    /// l'orchestrateur ne calcule plus son propre slug avec une autre Date).
    func start(meta: MeetingMetadata) async throws -> String
    func stop() async throws
    func cancel() async throws
    func patchMeta(_ mut: @Sendable (inout MeetingMetadata) -> Void) async throws
}

/// Événements de transition émis par l'orchestrateur — source de vérité pour
/// l'UI (icône menu bar, notifications). Sans ça, un enregistrement auto
/// était invisible : icône idle pendant que le micro tourne.
public enum RecordingTransition: Sendable {
    case started(slug: String, title: String?, source: MeetingMetadata.Source)
    /// Stop effectué, pipeline lancé en arrière-plan.
    case stopped(slug: String)
    /// Opt-out dans la fenêtre d'annulation : dossier supprimé.
    case cancelled(slug: String)
    /// Échec de start/stop — l'UI doit revenir à idle et afficher l'erreur.
    case failed(slug: String?, message: String)
}

public actor AutoTriggerOrchestrator {
    public enum State: Equatable {
        case idle
        /// Transition en cours : l'acteur est réentrant pendant les `await`
        /// de session.start/stop — ces états ferment la fenêtre de double
        /// démarrage (deux événements quasi simultanés voyaient .idle).
        case starting
        case recording(startedAt: Date, meta: MeetingMetadata)
        case stopping
    }

    private let session: any RecordingSession
    private let cancelWindowSeconds: TimeInterval
    private let matchLinkWindowSeconds: TimeInterval
    private let autoStopMarginSeconds: TimeInterval
    private let appVersion: String

    private var recentMatchedByMeetCode: [String: (event: MatchedEvent, at: Date)] = [:]
    private var autoStopTask: Task<Void, Never>?
    private var onTransition: (@Sendable (RecordingTransition) -> Void)?

    public private(set) var state: State = .idle

    public init(session: any RecordingSession,
                cancelWindowSeconds: TimeInterval = 30,
                matchLinkWindowSeconds: TimeInterval = 300,
                autoStopMarginSeconds: TimeInterval = 300,
                appVersion: String = "dev") {
        self.session = session
        self.cancelWindowSeconds = cancelWindowSeconds
        self.matchLinkWindowSeconds = matchLinkWindowSeconds
        self.autoStopMarginSeconds = autoStopMarginSeconds
        self.appVersion = appVersion
    }

    public func setTransitionHandler(_ h: @escaping @Sendable (RecordingTransition) -> Void) {
        onTransition = h
    }

    // MARK: - Entry points

    public func onCalendarEvent(_ match: MatchedEvent) async throws {
        Log.recorder.info(
            "orchestrator.onCalendarEvent: title=\(match.title, privacy: .public), state=\(Self.describe(self.state), privacy: .public)")
        registerRecentMatchedEvent(match)
        guard case .idle = state else {
            Log.recorder.info("orchestrator.onCalendarEvent: ignored (state != idle)")
            return
        }
        let now = Date()
        let meta = MeetingMetadata(
            id: "pending",
            startedAt: now,
            title: match.title,
            source: .calendar,
            appVersion: appVersion,
            models: Self.defaultModels,
            calendarEventId: match.id
        )
        try await startRecording(meta: meta, autoStopAt: match.endDate)
    }

    public func onCallEvent(_ ev: CallEvent) async throws {
        Log.recorder.info(
            "orchestrator.onCallEvent: app=\(ev.app.rawValue, privacy: .public), kind=\(String(describing: ev.kind), privacy: .public), state=\(Self.describe(self.state), privacy: .public)")
        let code = ev.code.lowercased()
        switch (state, ev.kind) {
        case (.idle, .started):
            let now = Date()
            let meta: MeetingMetadata
            if let linked = recentMatchedByMeetCode[code],
               abs(now.timeIntervalSince(linked.at)) <= matchLinkWindowSeconds {
                meta = MeetingMetadata(
                    id: "pending", startedAt: now,
                    title: linked.event.title, source: .calendar,
                    appVersion: appVersion, models: Self.defaultModels,
                    calendarEventId: linked.event.id,
                    detectedApp: ev.app.rawValue, detectedCode: code
                )
            } else {
                meta = MeetingMetadata(
                    id: "pending", startedAt: now,
                    source: .detected,
                    appVersion: appVersion, models: Self.defaultModels,
                    detectedApp: ev.app.rawValue, detectedCode: code
                )
            }
            // Détection présente : le .ended fera le stop, pas de timer.
            try await startRecording(meta: meta, autoStopAt: nil)

        case (.recording(let startedAt, var meta), .started):
            if meta.detectedApp == nil {
                let app = ev.app.rawValue
                meta.detectedApp = app
                meta.detectedCode = code
                try await session.patchMeta { m in
                    m.detectedApp = app
                    m.detectedCode = code
                }
                state = .recording(startedAt: startedAt, meta: meta)
                // La détection prend le relais du timer calendrier.
                autoStopTask?.cancel(); autoStopTask = nil
                Log.recorder.info(
                    "orchestrator: patched detection into ongoing recording slug=\(meta.id, privacy: .public)")
            }

        case (.recording(_, let meta), .ended):
            if meta.detectedApp == ev.app.rawValue,
               meta.detectedCode?.lowercased() == code {
                try await stopRecording(reason: "call ended")
            } else {
                Log.recorder.info(
                    "orchestrator.onCallEvent .ended: mismatch with current meta.detectedCode; ignored")
            }

        case (.idle, .ended), (.starting, _), (.stopping, _):
            return
        }
    }

    public func manualStart() async throws {
        Log.recorder.info(
            "orchestrator.manualStart: state=\(Self.describe(self.state), privacy: .public)")
        guard case .idle = state else {
            Log.recorder.info("orchestrator.manualStart: ignored (not idle)")
            return
        }
        let meta = MeetingMetadata(
            id: "pending", startedAt: Date(),
            source: .manual, appVersion: appVersion, models: Self.defaultModels
        )
        try await startRecording(meta: meta, autoStopAt: nil)
    }

    public func manualStop() async throws {
        Log.recorder.info(
            "orchestrator.manualStop: state=\(Self.describe(self.state), privacy: .public)")
        guard case .recording = state else {
            Log.recorder.info("orchestrator.manualStop: ignored (not recording)")
            return
        }
        try await stopRecording(reason: "manual stop")
    }

    public func optOut() async throws {
        Log.recorder.info(
            "orchestrator.optOut: state=\(Self.describe(self.state), privacy: .public)")
        guard case .recording(let startedAt, let meta) = state else { return }
        autoStopTask?.cancel(); autoStopTask = nil
        state = .stopping
        let elapsed = Date().timeIntervalSince(startedAt)
        do {
            if elapsed <= cancelWindowSeconds {
                try await session.cancel()
                state = .idle
                onTransition?(.cancelled(slug: meta.id))
                Log.recorder.info("orchestrator: → .idle (opt-out cancel, elapsed=\(elapsed)s)")
            } else {
                try await session.stop()
                state = .idle
                onTransition?(.stopped(slug: meta.id))
                Log.recorder.info("orchestrator: → .idle (opt-out stop, elapsed=\(elapsed)s)")
            }
        } catch {
            // JAMAIS rester wedgé : revenir à idle et signaler.
            state = .idle
            onTransition?(.failed(slug: meta.id, message: String(describing: error)))
            throw error
        }
    }

    public func registerRecentMatchedEvent(_ match: MatchedEvent) {
        let code = match.meetURL.lastPathComponent.lowercased()
        recentMatchedByMeetCode[code] = (match, Date())
        let cutoff = Date().addingTimeInterval(-matchLinkWindowSeconds)
        recentMatchedByMeetCode = recentMatchedByMeetCode.filter { $0.value.at >= cutoff }
    }

    // MARK: - Core transitions

    private func startRecording(meta base: MeetingMetadata, autoStopAt: Date?) async throws {
        state = .starting
        do {
            var meta = base
            let slug = try await session.start(meta: meta)
            meta.id = slug
            state = .recording(startedAt: base.startedAt, meta: meta)
            onTransition?(.started(slug: slug, title: meta.title, source: meta.source))
            if let autoStopAt { scheduleAutoStop(endDate: autoStopAt, slug: slug) }
            Log.recorder.info(
                "orchestrator: → .recording (\(String(describing: meta.source), privacy: .public)) slug=\(slug, privacy: .public)")
        } catch {
            state = .idle
            onTransition?(.failed(slug: nil, message: String(describing: error)))
            throw error
        }
    }

    private func stopRecording(reason: String) async throws {
        guard case .recording(_, let meta) = state else { return }
        autoStopTask?.cancel(); autoStopTask = nil
        state = .stopping
        do {
            try await session.stop()
            state = .idle
            onTransition?(.stopped(slug: meta.id))
            Log.recorder.info(
                "orchestrator: → .idle (\(reason, privacy: .public)) slug=\(meta.id, privacy: .public)")
        } catch {
            // C3 : un throw de session.stop laissait l'orchestrateur en
            // .recording pour toujours (tous les événements ignorés ensuite).
            state = .idle
            onTransition?(.failed(slug: meta.id, message: String(describing: error)))
            throw error
        }
    }

    /// H4 : un enregistrement déclenché par calendrier seul (pas de détection
    /// d'app) n'avait AUCUN mécanisme d'arrêt — il tournait jusqu'au cap 4 GB.
    private func scheduleAutoStop(endDate: Date, slug: String) {
        autoStopTask?.cancel()
        let margin = autoStopMarginSeconds
        autoStopTask = Task { [weak self] in
            let deadline = endDate.addingTimeInterval(margin)
            let interval = deadline.timeIntervalSinceNow
            if interval > 0 {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            if Task.isCancelled { return }
            await self?.autoStopFired(slug: slug)
        }
    }

    private func autoStopFired(slug: String) async {
        guard case .recording(_, let meta) = state, meta.id == slug else { return }
        Log.recorder.info(
            "orchestrator: auto-stop at event endDate for slug=\(slug, privacy: .public)")
        try? await stopRecording(reason: "calendar endDate + margin")
    }

    // MARK: - Helpers

    private static let defaultModels = MeetingMetadata.Models(
        whisper: "large-v3", diarization: "sherpa-pyannote-3.1")

    private static func describe(_ s: State) -> String {
        switch s {
        case .idle: return "idle"
        case .starting: return "starting"
        case .recording(_, let meta): return "recording(\(meta.id))"
        case .stopping: return "stopping"
        }
    }
}
```

- [ ] **Step 5: `RecorderSession.start` retourne le slug**

Dans `RecorderSession.swift`, changer la signature et la fin de `start` :

```swift
public func start(meta: MeetingMetadata) async throws -> String {
    Log.recorder.info(
        "RecorderSession.start: source=\(String(describing: meta.source), privacy: .public), title=\(meta.title ?? "<nil>", privacy: .public)")
    let paths = try await recorder.start()
    try storage.patchMetadata({ m in
        m.title = meta.title
        m.source = meta.source
        m.calendarEventId = meta.calendarEventId
        m.detectedApp = meta.detectedApp
        m.detectedCode = meta.detectedCode
    }, at: paths)
    lock.lock(); currentPaths = paths; lock.unlock()
    Log.recorder.info("RecorderSession.start done for slug=\(paths.slug, privacy: .public)")
    return paths.slug
}
```

- [ ] **Step 6: Adapter les tests existants** (FakeSession retourne `meta.id`, assertions d'état inchangées ; le test existant à `cancelWindowSeconds: 0` reste valide).

- [ ] **Step 7: Vérifier**

Run: `swift test --filter AutoTriggerOrchestratorTests 2>&1 | tail -10` puis `swift build 2>&1 | tail -3` → PASS.

---

### Task 13: Pipeline — diarization hors du pool coopératif + notes config à chaud (M6, M7-partie)

**Files:**
- Modify: `Sources/RecorderCore/Pipeline/Pipeline.swift`

- [ ] **Step 1: Diarization sur une queue dédiée**

Dans `Pipeline.run`, remplacer l'étape diarize (lignes 49-51) par :

```swift
try await runStep(.diarize, paths: paths, overall: .diarizing) {
    // La diarization est un calcul ONNX synchrone de plusieurs minutes :
    // l'exécuter dans l'acteur monopolisait un thread du pool coopératif
    // (starvation possible). Queue GCD dédiée + continuation.
    let diarizer = self.diarizer
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try diarizer.diarize(wavPath: paths.systemNormalized,
                                     to: paths.diarization)
                cont.resume()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
```

- [ ] **Step 2: Notes config mutable (pour l'application à chaud des Settings)**

Changer `private let notes: NoteGenerationConfig?` en `private var notes: NoteGenerationConfig?` et ajouter :

```swift
/// Application à chaud des réglages de notes (binaire claude, niveau,
/// activation) sans redémarrer l'app.
public func setNotesConfig(_ cfg: NoteGenerationConfig?) {
    notes = cfg
}
```

- [ ] **Step 3: Vérifier**

Run: `swift test --filter PipelineTests 2>&1 | tail -5` → PASS.

---

### Task 14: App / AppState / GlobalHotkey / MenuBarView / Notifications — cycle de vie et synchronisation UI (C2, C3-UI, H1, H9, H13, H14, M2, M6, M7, LOWs)

**Files:**
- Modify: `Sources/Onyx/App.swift` (réécriture)
- Modify: `Sources/Onyx/AppState.swift` (réécriture)
- Modify: `Sources/Onyx/Hotkey/GlobalHotkey.swift`
- Modify: `Sources/Onyx/Menu/MenuBarView.swift`
- Modify: `Sources/Onyx/Notifications/OptOutNotificationCenter.swift:72-80`
- Modify: `Sources/Onyx/Settings/SettingsStore.swift` (méthode `reload()`)

Pas de tests unitaires possibles (UI/permissions) — vérification : compilation + E2E final.

- [ ] **Step 1: `GlobalHotkey` — enregistrement idempotent**

Remplacer le fichier :

```swift
import Carbon.HIToolbox
import AppKit

public final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var handler: () -> Void = {}
    private static var instance: GlobalHotkey?
    private static var handlerInstalled = false

    public init() { GlobalHotkey.instance = self }

    /// Idempotent : ré-appeler ne ré-installe NI le handler Carbon NI la
    /// hotkey (l'ancien code empilait un handler par appel → un seul ⌘⇧R
    /// déclenchait toggleRecording N fois).
    public func register(keyCode: UInt32 = UInt32(kVK_ANSI_R),
                         modifiers: UInt32 = UInt32(cmdKey | shiftKey),
                         onTrigger: @escaping () -> Void) {
        handler = onTrigger
        if !Self.handlerInstalled {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                          eventKind: OSType(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
                GlobalHotkey.instance?.handler()
                return noErr
            }, 1, &eventType, nil, nil)
            Self.handlerInstalled = true
        }
        guard hotKeyRef == nil else { return }
        let id = EventHotKeyID(signature: OSType(0x4F4E5958), id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(),
                            0, &hotKeyRef)
    }

    deinit { if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) } }
}
```

- [ ] **Step 2: `SettingsStore.reload()`**

Ajouter à la fin de la classe :

```swift
/// Re-lit tous les réglages depuis UserDefaults. Utilisé quand l'onboarding
/// (qui écrit via sa propre instance) se termine : sans ça, AppState gardait
/// les valeurs capturées au boot (whitelist vide → aucun auto-trigger).
public func reload() {
    language = defaults.string(forKey: "language") ?? "fr"
    if let s = defaults.string(forKey: "meetingsFolder") {
        meetingsFolder = URL(fileURLWithPath: s)
    }
    autoUpdateEnabled = defaults.object(forKey: "autoUpdate") as? Bool ?? true
    autoTriggerEnabled = defaults.object(forKey: "autoTriggerEnabled") as? Bool ?? true
    autoNotesEnabled = defaults.object(forKey: "autoNotesEnabled") as? Bool ?? true
    detectionMeetEnabled = defaults.object(forKey: "detectionMeetEnabled") as? Bool ?? true
    detectionHuddleEnabled = defaults.object(forKey: "detectionHuddleEnabled") as? Bool ?? true
    claudeBinaryPath = defaults.string(forKey: "claudeBinaryPath") ?? ""
    if let raw = defaults.string(forKey: "defaultNoteLevel"),
       let lvl = NoteLevel(rawValue: raw) {
        defaultNoteLevel = lvl
    }
    enabledCalendarIds = defaults.array(forKey: "enabledCalendarIds") as? [String] ?? []
}
```

- [ ] **Step 3: `OptOutNotificationCenter` — completionHandler immédiat**

Remplacer `userNotificationCenter(_:didReceive:withCompletionHandler:)` :

```swift
public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                   didReceive response: UNNotificationResponse,
                                   withCompletionHandler completionHandler: @escaping () -> Void) {
    // Répondre immédiatement au système ; le handler (potentiellement lent)
    // continue dans sa propre Task.
    if response.actionIdentifier == stopActionId, let handler = optOutHandler {
        Task { await handler() }
    }
    completionHandler()
}
```

- [ ] **Step 4: Réécrire `App.swift`**

```swift
import SwiftUI
import AppKit
import RecorderCore

@main
struct OnyxApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var updater = UpdaterController(startAutomatically: true)

    init() {
        let v1 = UserDefaults.standard.bool(forKey: "onboardingDone")
        let v2 = UserDefaults.standard.bool(forKey: "onboardingV2Done")
        if !(v1 && v2) {
            DispatchQueue.main.async { Self.showOnboarding() }
        }
    }

    var body: some Scene {
        // PAS de .onAppear ici : le contenu d'un MenuBarExtra(.menu)
        // ré-apparaît à CHAQUE ouverture du menu — les boucles/hotkey y
        // étaient dupliquées N fois (C1/C2 de l'audit). Tout le boot vit
        // dans AppState.init.
        MenuBarExtra {
            MenuBarView(app: appState)
        } label: {
            MenuBarIcon(state: appState.uiState)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsWindow(settings: appState.settings, storage: appState.storage,
                           indexer: appState.indexer, updater: updater)
        }
    }

    // Référence forte : NSWindow programmatique a isReleasedWhenClosed=true
    // par défaut → close() + second close = over-release/crash (H14).
    private static var onboardingWindow: NSWindow?

    private static func showOnboarding() {
        let win = NSWindow(contentRect: .init(x: 0, y: 0, width: 480, height: 320),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.center(); win.title = "Onyx — Setup"
        win.contentView = NSHostingView(rootView: OnboardingWindow {
            win.close()
            onboardingWindow = nil
            NotificationCenter.default.post(name: .onyxOnboardingCompleted, object: nil)
        })
        win.makeKeyAndOrderFront(nil)
        onboardingWindow = win
    }
}

extension Notification.Name {
    static let onyxOnboardingCompleted = Notification.Name("onyx.onboardingCompleted")
}
```

- [ ] **Step 5: Retirer le double-close dans `OnboardingWindow.swift`**

Dans le step `.done` (lignes 62-67), supprimer la ligne `NSApplication.shared.keyWindow?.close()` (le `onCompleted()` ferme déjà la bonne fenêtre) :

```swift
Button("Start using Onyx") {
    UserDefaults.standard.set(true, forKey: "onboardingDone")
    UserDefaults.standard.set(true, forKey: "onboardingV2Done")
    onCompleted()
}
```

- [ ] **Step 6: Réécrire `AppState.swift`**

```swift
import Foundation
import Combine
import RecorderCore

@MainActor
public final class AppState: ObservableObject {
    public enum UIState { case idle, recording, transcribing }
    @Published public var uiState: UIState = .idle
    @Published public var currentSlug: String?
    @Published public var lastError: String?

    public let settings = SettingsStore()
    public let storage: MeetingStorage
    public let indexer: MeetingIndexer
    public let calendarWatcher: CalendarWatcher
    private let recorder: Recorder
    private let pipeline: Pipeline
    private let orchestrator: AutoTriggerOrchestrator
    private let hotkey = GlobalHotkey()

    // Boucles annulables : autoTrigger désactivable à chaud (M7) et
    // reconstruction sur changement de réglages.
    private var calendarLoopTask: Task<Void, Never>?
    private var detectionLoopTask: Task<Void, Never>?
    private var resumedPendingJobs = false
    private var cancellables = Set<AnyCancellable>()

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    public init() {
        storage = MeetingStorage(root: settings.meetingsFolder,
                                 appVersion: Self.appVersion)
        let dbURL = FileManager.default.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask)[0]
            .appendingPathComponent("Onyx/index.sqlite")
        try? FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        indexer = Self.makeIndexer(dbURL: dbURL)
        recorder = Recorder(storage: storage)

        let binaryURL: URL? = settings.claudeBinaryPath.isEmpty
            ? nil : URL(fileURLWithPath: settings.claudeBinaryPath)
        let notesCfg: NoteGenerationConfig? = (settings.autoNotesEnabled && binaryURL != nil)
            ? NoteGenerationConfig(binary: binaryURL, level: settings.defaultNoteLevel)
            : nil
        pipeline = Pipeline(storage: storage, notes: notesCfg)

        calendarWatcher = CalendarWatcher()

        let session = RecorderSession(recorder: recorder, storage: storage, pipeline: pipeline)
        orchestrator = AutoTriggerOrchestrator(session: session,
                                               appVersion: Self.appVersion)

        session.onPipelineFinished = { [weak self] slug, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.uiState == .transcribing { self.uiState = .idle }
                if let error {
                    self.lastError = "Pipeline failed (\(slug)): \(String(describing: error))"
                    OptOutNotificationCenter.shared.showNotesFailed(slug: slug)
                }
            }
        }

        let localOrch = orchestrator
        OptOutNotificationCenter.shared.optOutHandler = {
            try? await localOrch.optOut()
        }
        OptOutNotificationCenter.shared.configureIfNeeded()

        // Un writer scellé (size cap / disque plein) route un stop gracieux
        // par l'orchestrateur pour garder les états cohérents.
        let capOrch = orchestrator
        Task { [recorder] in
            await recorder.setSizeCapHandler {
                Task { try? await capOrch.manualStop() }
            }
        }

        // H1 : les transitions de l'orchestrateur sont LA source de vérité
        // de l'UI — un enregistrement auto affiche enfin le point rouge, le
        // bouton Stop, et les notifications ne partent que si le start a
        // réellement eu lieu (M2).
        Task { [orchestrator] in
            await orchestrator.setTransitionHandler { [weak self] transition in
                Task { @MainActor [weak self] in
                    self?.apply(transition)
                }
            }
        }

        // Boot unique (le .onAppear du MenuBarExtra a été retiré — il se
        // déclenchait à chaque ouverture du menu et dupliquait tout).
        hotkey.register { [weak self] in
            Task { @MainActor in self?.toggleRecording() }
        }
        bootAutotrigger()
        resumePendingJobs()
        observeSettings()
        dumpDiagnosticInfoIfE2E()

        NotificationCenter.default.addObserver(
            forName: .onyxOnboardingCompleted, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // L'onboarding écrit via sa propre instance de SettingsStore ;
                // recharger puis relancer les boucles avec la vraie config.
                self?.settings.reload()
            }
        }
    }

    /// H13 : un index.sqlite corrompu crashait l'app au boot (try!). L'index
    /// est reconstructible (RescanRunner) — le recréer plutôt que crasher.
    private static func makeIndexer(dbURL: URL) -> MeetingIndexer {
        do { return try MeetingIndexer(dbPath: dbURL) } catch {
            Log.pipeline.error(
                "MeetingIndexer init failed (\(String(describing: error), privacy: .public)); recreating index")
            try? FileManager.default.removeItem(at: dbURL)
            do { return try MeetingIndexer(dbPath: dbURL) } catch {
                fatalError("Cannot create meeting index even after reset: \(error)")
            }
        }
    }

    private func apply(_ transition: RecordingTransition) {
        switch transition {
        case .started(let slug, let title, let source):
            uiState = .recording
            currentSlug = slug
            if source != .manual {
                OptOutNotificationCenter.shared.showRecordingStarted(
                    title: title ?? "Meet/Huddle detected")
            }
        case .stopped:
            uiState = .transcribing
            currentSlug = nil
        case .cancelled:
            uiState = .idle
            currentSlug = nil
        case .failed(_, let message):
            uiState = .idle
            currentSlug = nil
            lastError = message
        }
    }

    // MARK: - Settings à chaud (M7 / H9)

    private func observeSettings() {
        // Boucles auto-trigger : reboot sur tout changement pertinent.
        settings.$autoTriggerEnabled.dropFirst()
            .merge(with: settings.$detectionMeetEnabled.dropFirst(),
                   settings.$detectionHuddleEnabled.dropFirst())
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.bootAutotrigger() }
            .store(in: &cancellables)
        settings.$enabledCalendarIds.dropFirst()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.bootAutotrigger() }
            .store(in: &cancellables)
        // Config notes : appliquée à chaud dans le pipeline.
        settings.$claudeBinaryPath.dropFirst().map { _ in () }
            .merge(with: settings.$autoNotesEnabled.dropFirst().map { _ in () },
                   settings.$defaultNoteLevel.dropFirst().map { _ in () })
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.applyNotesConfig() }
            .store(in: &cancellables)
        // meetingsFolder : appliqué au prochain lancement (storage/recorder
        // seraient à reconstruire en profondeur) — hint affiché dans Settings.
    }

    private func applyNotesConfig() {
        let binaryURL: URL? = settings.claudeBinaryPath.isEmpty
            ? nil : URL(fileURLWithPath: settings.claudeBinaryPath)
        let cfg: NoteGenerationConfig? = (settings.autoNotesEnabled && binaryURL != nil)
            ? NoteGenerationConfig(binary: binaryURL, level: settings.defaultNoteLevel)
            : nil
        let pipeline = self.pipeline
        Task { await pipeline.setNotesConfig(cfg) }
    }

    public func toggleRecording() {
        Task {
            do {
                switch uiState {
                case .idle, .transcribing:
                    try await orchestrator.manualStart()
                case .recording:
                    try await orchestrator.manualStop()
                }
                // uiState est mis à jour par apply(_:) via les transitions —
                // plus de mutation optimiste désynchronisée.
            } catch {
                lastError = String(describing: error)
            }
        }
    }

    public func bootAutotrigger() {
        calendarLoopTask?.cancel(); calendarLoopTask = nil
        detectionLoopTask?.cancel(); detectionLoopTask = nil
        guard settings.autoTriggerEnabled else { return }

        let orch = orchestrator
        let watcher = calendarWatcher
        let enabledIds = settings.enabledCalendarIds

        calendarLoopTask = Task.detached {
            let matcher = CalendarMatcher(whitelistedCalendarIds: enabledIds)
            for await match in watcher.matches(matcher: matcher) {
                if Task.isCancelled { return }
                // Notification déclenchée par la transition .started —
                // plus de fausse notification quand l'événement est ignoré.
                try? await orch.onCalendarEvent(match)
            }
        }

        var detectors: [any MeetingAppDetector] = []
        if settings.detectionMeetEnabled { detectors.append(MeetDetector()) }
        if settings.detectionHuddleEnabled { detectors.append(SlackHuddleDetector()) }
        guard !detectors.isEmpty else { return }
        let coordinator = DetectionCoordinator(detectors: detectors)
        detectionLoopTask = Task.detached {
            for await ev in coordinator.events() {
                if Task.isCancelled { return }
                try? await orch.onCallEvent(ev)
            }
        }
    }

    public func regenerateNotes(for slug: String, level: NoteLevel) {
        Task {
            let path = settings.claudeBinaryPath
            guard !path.isEmpty else {
                self.lastError = "Claude binary path not configured"
                return
            }
            let binary = URL(fileURLWithPath: path)
            let paths = MeetingPaths(root: storage.root, slug: slug)
            let gen = ClaudeNoteGenerator()
            do {
                try await gen.generate(paths: paths, level: level, binary: binary)
            } catch {
                self.lastError = "Regenerate failed: \(String(describing: error))"
                OptOutNotificationCenter.shared.showNotesFailed(slug: slug)
            }
        }
    }

    public func resumePendingJobs() {
        guard !resumedPendingJobs else { return }
        resumedPendingJobs = true
        let storage = self.storage
        let pipeline = self.pipeline
        Task {
            let listings = (try? storage.listMeetings()) ?? []
            for listing in listings {
                let paths = MeetingPaths(root: storage.root, slug: listing.slug)
                guard let job = try? storage.loadJob(paths), job.isResumable else { continue }
                try? await pipeline.run(paths: paths)
            }
        }
    }

    /// Diag E2E uniquement (M6) : n'écrit plus la liste des calendriers +
    /// chemin claude dans ~/Meetings à chaque boot en usage normal.
    private func dumpDiagnosticInfoIfE2E() {
        guard ProcessInfo.processInfo.environment["ONYX_E2E"] == "1" else { return }
        Task.detached { [weak self] in
            guard let self else { return }
            let watcher = await self.calendarWatcher
            let root = await self.storage.root
            let enabled = await self.settings.enabledCalendarIds
            let cals = watcher.availableCalendars()
            let entries: [[String: String]] = cals.map { c in
                [
                    "identifier": c.calendarIdentifier,
                    "title": c.title,
                    "type": String(c.type.rawValue),
                    "whitelisted": enabled.contains(c.calendarIdentifier) ? "true" : "false",
                    "allowsContentModifications": c.allowsContentModifications ? "true" : "false",
                ]
            }
            let payload: [String: Any] = [
                "calendars": entries,
                "whitelistedIds": enabled,
                "autoTriggerEnabled": await self.settings.autoTriggerEnabled,
                "autoNotesEnabled": await self.settings.autoNotesEnabled,
                "claudeBinaryPath": await self.settings.claudeBinaryPath,
            ]
            try? FileManager.default.createDirectory(at: root,
                                                     withIntermediateDirectories: true)
            let out = root.appendingPathComponent(".onyx-diag.json")
            if let data = try? JSONSerialization.data(withJSONObject: payload,
                                                      options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out, options: .atomic)
            }
        }
    }
}
```

**Notes de compilation :** `Log` est dans RecorderCore — vérifier qu'il est `public` (sinon utiliser `os.Logger` local). `settings.$defaultNoteLevel` publie un `NoteLevel` : le `.map { _ in () }` uniformise les types pour le merge.

- [ ] **Step 7: `MenuBarView` — recents en @State + fallback sélecteur Settings**

1. Remplacer le `Menu("Recent Meetings")` : sortir la requête du `body` :

```swift
@State private var recents: [MeetingListing] = []
```

Dans le `Menu` : `if recents.isEmpty { ... } else { ForEach(recents, id: \.id) { ... } }` (contenu inchangé), et sur le `Group` racine ajouter :

```swift
.onAppear { recents = (try? app.indexer.recentMeetings(limit: 5)) ?? [] }
```

(Le contenu du menu ré-apparaît à chaque ouverture → rafraîchi à chaque fois, sans requête à chaque render.)

2. Remplacer `openSettingsWindow()` :

```swift
@MainActor func openSettingsWindow() {
    // showSettingsWindow: est un sélecteur privé (macOS 13+) ; fallback sur
    // l'ancien sélecteur si AppKit le renomme.
    if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
    NSApp.activate(ignoringOtherApps: true)
}
```

- [ ] **Step 8: Vérifier**

Run: `swift build 2>&1 | tail -5` → OK. (`SettingsWindow` prend le paramètre `updater` en Task 16 — si l'ordre d'exécution fait échouer la compilation ici, ajouter le paramètre dès maintenant comme décrit en Task 16 Step 1.)

---

### Task 15: Onboarding — refus de permissions gérés, Retry/Skip modèles, Process hors main thread, validation binaire (M1, M3, M4, M5)

**Files:**
- Modify: `Sources/Onyx/Onboarding/OnboardingWindow.swift`
- Modify: `Sources/Onyx/Onboarding/ModelDownloadView.swift`
- Modify: `Sources/Onyx/Onboarding/ClaudeBinaryView.swift`
- Modify: `Sources/Onyx/Onboarding/BrowserAutomationView.swift`

- [ ] **Step 1: `OnboardingWindow` — étapes mic/screen avec gestion du refus**

Ajouter les états et un helper :

```swift
@State private var micDenied = false
@State private var screenRequested = false

private func openPrivacyPane(_ anchor: String) {
    if let url = URL(string:
        "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
        NSWorkspace.shared.open(url)
    }
}
```

Remplacer les cases `.mic` et `.screen` :

```swift
case .mic:
    Text("Microphone access").font(.title)
    if micDenied {
        Text("Microphone access is denied. Onyx cannot record meetings without it.")
            .foregroundColor(.red).multilineTextAlignment(.center)
        Button("Open System Settings") { openPrivacyPane("Privacy_Microphone") }
        Button("Check again") {
            Task {
                if await PermissionsChecker.micGranted() { step = .screen }
            }
        }
        Button("Continue anyway") { step = .screen }
    } else {
        Button("Grant microphone") {
            Task {
                if await PermissionsChecker.micGranted() { step = .screen }
                else { micDenied = true }
            }
        }
    }
case .screen:
    Text("Screen recording").font(.title)
    Text("Required to capture system audio (Zoom, Meet, Huddle…)")
        .foregroundColor(.secondary).multilineTextAlignment(.center)
    if screenRequested && !PermissionsChecker.screenRecordingGranted() {
        Text("Not granted yet. Enable Onyx in System Settings, then check again.")
            .foregroundColor(.red).multilineTextAlignment(.center)
        Button("Open System Settings") { openPrivacyPane("Privacy_ScreenCapture") }
        Button("Check again") {
            if PermissionsChecker.screenRecordingGranted() { step = .models }
        }
        Button("Continue anyway") { step = .models }
    } else {
        Button("Grant screen recording") {
            PermissionsChecker.requestScreenRecording()
            if PermissionsChecker.screenRecordingGranted() { step = .models }
            else { screenRequested = true }
        }
    }
```

- [ ] **Step 2: `ModelDownloadView` — Retry / Skip sur échec**

Ajouter `@State private var failed = false`, et remplacer le body + les returns d'erreur :

```swift
var body: some View {
    VStack(spacing: 16) {
        Text(status).font(.headline)
        ProgressView(value: progress).frame(width: 320)
        if failed {
            HStack {
                Button("Retry") {
                    failed = false
                    Task { await run() }
                }
                Button("Skip for now") { onDone() }
            }
            Text("You can re-run the download later by resetting onboarding in Settings > Advanced.")
                .font(.caption).foregroundColor(.secondary)
        }
    }
    .padding(40)
    .task { await run() }
}
```

Dans `run()`, chaque `return` d'erreur devient `failed = true; return` :

```swift
} catch {
    status = "Failed openai_whisper-large-v3: \(error.localizedDescription)"
    failed = true
    return
}
...
} catch {
    status = "Failed \(a.id): \(error.localizedDescription)"
    failed = true
    return
}
```

- [ ] **Step 3: `ClaudeBinaryView` — détection hors main thread + validation du chemin saisi (M4)**

1. Bouton "Use" — valider avant d'accepter :

```swift
Button("Use") {
    if FileManager.default.isExecutableFile(atPath: custom) {
        settings.claudeBinaryPath = custom
        detected = "Using: \(custom)"
    } else {
        detected = "Not an executable file: \(custom)"
    }
}
```

2. `detectBinary()` — la partie `which claude` (login shell potentiellement lent) part en détaché :

```swift
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
    detected = "Searching (login shell)…"
    Task.detached {
        let result = Self.whichClaude()
        await MainActor.run {
            if let path = result {
                detected = "Found via shell: \(path)"
                settings.claudeBinaryPath = path
            } else {
                detected = "Claude not found — auto notes disabled. Set manually later in Settings."
            }
        }
    }
}

private static func whichClaude() -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
    proc.arguments = ["-lc", "which claude"]
    let out = Pipe(); proc.standardOutput = out; proc.standardError = Pipe()
    do { try proc.run(); proc.waitUntilExit() } catch { return nil }
    let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
    let s = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (proc.terminationStatus == 0 && !s.isEmpty) ? s : nil
}
```

(Nota : `detected`/`settings` capturés depuis une vue SwiftUI — si le compilateur exige `@MainActor`, marquer `detectBinary` et passer par des copies locales.)

- [ ] **Step 4: `BrowserAutomationView.probe()` — hors main thread**

Les prompts Automation macOS bloquent osascript jusqu'à la réponse de l'utilisateur → beachball de la fenêtre. Remplacer `probe()` :

```swift
private func probe() {
    results = ["Probing… answer the macOS permission popups."]
    Task.detached {
        let bundles = [
            "com.google.Chrome",
            "com.apple.Safari",
            "company.thebrowser.Browser",
            "com.brave.Browser",
        ]
        var collected: [String] = []
        for b in bundles {
            let script = "tell application id \"\(b)\" to return name"
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            let out = Pipe(); proc.standardOutput = out; proc.standardError = out
            do { try proc.run(); proc.waitUntilExit() } catch {
                collected.append("\(b): \(error.localizedDescription)")
                continue
            }
            let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
            let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            collected.append("\(b): \(proc.terminationStatus == 0 ? "OK — \(s)" : "denied/not installed")")
        }
        let final = collected
    await MainActor.run { results = final }
    }
}
```

- [ ] **Step 5: Vérifier**

Run: `swift build 2>&1 | tail -3` → OK.

---

### Task 16: SettingsWindow + UpdaterController — toggle Sparkle branché, test binaire asynchrone, hint dossier (H8-partie, M3)

**Files:**
- Modify: `Sources/Onyx/Update/UpdaterController.swift`
- Modify: `Sources/Onyx/Settings/SettingsWindow.swift`

- [ ] **Step 1: `UpdaterController` — respecter la préférence utilisateur**

```swift
import Foundation
import Sparkle

public final class UpdaterController: ObservableObject {
    public let controller: SPUStandardUpdaterController
    public init(startAutomatically: Bool) {
        controller = SPUStandardUpdaterController(startingUpdater: startAutomatically,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        // Le toggle Settings écrivait une clé UserDefaults que Sparkle ne lit
        // pas — brancher la préférence sur la vraie API.
        let pref = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true
        controller.updater.automaticallyChecksForUpdates = pref
    }
    public func checkNow() { controller.checkForUpdates(nil) }
    public func setAutomaticChecks(_ on: Bool) {
        controller.updater.automaticallyChecksForUpdates = on
    }
}
```

- [ ] **Step 2: `SettingsWindow` — paramètre updater + onChange + hint dossier + test claude asynchrone**

1. Ajouter la propriété et adapter l'init call-site (déjà fait en Task 14) :

```swift
let updater: UpdaterController
```

2. Dans `generalTab`, section Updates :

```swift
Section("Updates") {
    Toggle("Check for updates automatically", isOn: $settings.autoUpdateEnabled)
        .onChange(of: settings.autoUpdateEnabled) { on in
            updater.setAutomaticChecks(on)
        }
}
```

3. Dans la section Storage, sous le bouton "Choose folder…" :

```swift
Text("Changing the meetings folder takes effect at next launch.")
    .font(.caption).foregroundStyle(.secondary)
```

4. `testClaudeBinary()` asynchrone (le `--version` peut prendre plusieurs secondes sur le main thread) :

```swift
private func testClaudeBinary() {
    let path = settings.claudeBinaryPath
    guard !path.isEmpty else { claudeTestResult = "Path is empty."; return }
    guard FileManager.default.isExecutableFile(atPath: path) else {
        claudeTestResult = "Not an executable file."; return
    }
    claudeTestResult = "Testing…"
    Task.detached {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["--version"]
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        let result: String
        do {
            try p.run(); p.waitUntilExit()
            let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
            let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            result = p.terminationStatus == 0 ? "OK: \(s)" : "Exit \(p.terminationStatus): \(s)"
        } catch {
            result = "Failed to launch: \(error.localizedDescription)"
        }
        let final = result
        await MainActor.run { claudeTestResult = final }
    }
}
```

- [ ] **Step 3: Vérifier**

Run: `swift build 2>&1 | tail -3` → OK.

---

### Task 17: ModelDownloader — thread-safety, checksums SHA-256, remoteURL optionnelle (M2, H12-partie, LOW)

**Files:**
- Modify: `Sources/RecorderCore/Models/ModelDownloader.swift`
- Modify: `Sources/RecorderCore/Models/ModelManifest.swift`
- Test: créer `Tests/RecorderCoreTests/ModelDownloaderTests.swift`

- [ ] **Step 1: Calculer les vrais SHA-256 des assets (une fois, à l'exécution du plan)**

```bash
curl -sL "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2" | shasum -a 256
curl -sL "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_CAM++.onnx" | shasum -a 256
```

Noter les deux empreintes — elles seront collées dans `ModelManifest` (Step 4).

- [ ] **Step 2: Test échouant — mismatch de checksum rejeté**

Créer `Tests/RecorderCoreTests/ModelDownloaderTests.swift` :

```swift
import XCTest
@testable import RecorderCore

final class ModelDownloaderTests: XCTestCase {
    func testChecksumMismatchThrows() async throws {
        // Asset servi depuis un fichier local (URLSession downloadTask
        // fonctionne avec file://), checksum volontairement faux.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("model.onnx")
        try Data("fake model".utf8).write(to: src)

        let asset = ModelAsset(
            id: "test-model-\(UUID().uuidString)",
            remoteURL: src,
            relativeInstallPath: "test/\(UUID().uuidString).onnx",
            sha256: String(repeating: "0", count: 64))
        let downloader = ModelDownloader()
        do {
            _ = try await downloader.download(asset) { _ in }
            XCTFail("expected checksum error")
        } catch {
            XCTAssertTrue(String(describing: error).lowercased().contains("checksum"))
        }
        // Rien ne doit être installé.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ModelManifest.installedPath(for: asset).path))
    }

    func testChecksumMatchInstalls() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data("real model".utf8)
        let src = dir.appendingPathComponent("model.onnx")
        try payload.write(to: src)
        let expected = ModelDownloader.sha256Hex(of: payload)

        let rel = "test/\(UUID().uuidString).onnx"
        let asset = ModelAsset(id: "test-model-ok-\(UUID().uuidString)",
                               remoteURL: src,
                               relativeInstallPath: rel,
                               sha256: expected)
        defer { try? FileManager.default.removeItem(
            at: ModelManifest.installedPath(for: asset)) }
        let downloader = ModelDownloader()
        let installed = try await downloader.download(asset) { _ in }
        XCTAssertEqual(try Data(contentsOf: installed), payload)
    }
}
```

- [ ] **Step 3: Réécrire `ModelDownloader`** (lock + vérification + remoteURL optionnelle)

```swift
import Foundation
import CryptoKit

public final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    public struct Progress {
        public let asset: ModelAsset
        public let bytesReceived: Int64
        public let bytesExpected: Int64
    }

    public typealias ProgressHandler = (Progress) -> Void

    public enum DownloadError: Error, LocalizedError {
        case notDownloadable(String)
        case checksumMismatch(asset: String, expected: String, actual: String)
        public var errorDescription: String? {
            switch self {
            case .notDownloadable(let id):
                return "Asset \(id) has no direct remote URL"
            case .checksumMismatch(let asset, let expected, let actual):
                return "Checksum mismatch for \(asset): expected \(expected), got \(actual)"
            }
        }
    }

    // `pending`/`handler` sont touchés depuis le contexte appelant ET la
    // queue déléguée URLSession → lock obligatoire. Le handler vit dans le
    // tuple (plus de singleton écrasé par le download suivant).
    private let lock = NSLock()
    private var pending: [(asset: ModelAsset,
                           cont: CheckedContinuation<URL, Error>,
                           progress: ProgressHandler)] = []
    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    public override init() { super.init() }

    public func download(_ asset: ModelAsset,
                         progress: @escaping ProgressHandler) async throws -> URL {
        let dest = ModelManifest.installedPath(for: asset)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        guard let remote = asset.remoteURL else {
            throw DownloadError.notDownloadable(asset.id)
        }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            pending.append((asset, cont, progress))
            lock.unlock()
            let task = session.downloadTask(with: remote)
            task.taskDescription = asset.id
            task.resume()
        }
    }

    public func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                           totalBytesExpectedToWrite total: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        lock.lock()
        let entry = pending.first(where: { $0.asset.id == id })
        lock.unlock()
        guard let entry else { return }
        entry.progress(.init(asset: entry.asset,
                             bytesReceived: totalBytesWritten, bytesExpected: total))
    }

    public func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        lock.lock()
        let idx = pending.firstIndex(where: { $0.asset.id == id })
        let entry = idx.map { pending.remove(at: $0) }
        lock.unlock()
        guard let entry else { return }
        let (asset, cont, _) = entry
        let finalPath = ModelManifest.installedPath(for: asset)
        do {
            // Intégrité : un download tronqué ou une release compromise ne
            // doit jamais s'installer (l'échec tardif au chargement du modèle
            // était indéchiffrable ; pire, c'est du code/data natif).
            if let expected = asset.sha256 {
                let actual = Self.sha256Hex(of: try Data(contentsOf: location))
                guard actual == expected.lowercased() else {
                    throw DownloadError.checksumMismatch(asset: asset.id,
                                                         expected: expected, actual: actual)
                }
            }
            switch asset.kind {
            case .file:
                try? FileManager.default.removeItem(at: finalPath)
                try FileManager.default.moveItem(at: location, to: finalPath)
            case .archiveTarBz2:
                try Self.extractTarBz2(from: location,
                    into: finalPath.deletingLastPathComponent().deletingLastPathComponent())
                guard FileManager.default.fileExists(atPath: finalPath.path) else {
                    throw NSError(domain: "ModelDownloader", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "Archive \(asset.id) extracted but expected file missing at \(finalPath.path)"])
                }
                try? FileManager.default.removeItem(at: location)
            }
            cont.resume(returning: finalPath)
        } catch { cont.resume(throwing: error) }
    }

    public func urlSession(_ s: URLSession, task: URLSessionTask,
                           didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        lock.lock()
        let idx = pending.firstIndex(where: { $0.asset.id == id })
        let entry = idx.map { pending.remove(at: $0) }
        lock.unlock()
        entry?.cont.resume(throwing: error)
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func extractTarBz2(from archive: URL, into dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archive.path, "-C", dir.path]
        let err = Pipe()
        process.standardError = err
        let errCollector = DataCollector()
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { errCollector.append(d) }
        }
        try process.run()
        process.waitUntilExit()
        err.fileHandleForReading.readabilityHandler = nil
        if process.terminationStatus != 0 {
            let msg = String(data: errCollector.snapshot, encoding: .utf8) ?? "unknown tar error"
            throw NSError(domain: "ModelDownloader", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "tar failed: \(msg)"])
        }
    }
}
```

(Le test appelle `ModelDownloader.sha256Hex(of: Data)` — la variante fichier n'est plus nécessaire.)

- [ ] **Step 4: `ModelManifest` — remoteURL optionnelle + checksums réels**

Changer `ModelAsset.remoteURL` en `URL?` (init : `remoteURL: URL?`). Puis :
- `whisperLargeV3` : `remoteURL: nil` (footgun supprimé — WhisperKit télécharge lui-même ; la page HTML HF n'était pas un artefact téléchargeable).
- `sherpaSegmentation` / `sherpaEmbedding` : renseigner `sha256:` avec les empreintes du Step 1 (en minuscules).

- [ ] **Step 5: Vérifier**

Run: `swift test --filter ModelDownloaderTests 2>&1 | tail -5` puis `swift build 2>&1 | tail -3` → PASS.

---

### Task 18: E2ETrigger — email en variable d'env + échappement AppleScript (LOWs)

**Files:**
- Modify: `Sources/E2ETrigger/main.swift`

- [ ] **Step 1: Helper d'échappement + email configurable**

Ajouter près du haut du fichier (après les imports) :

```swift
/// Échappe une chaîne interpolée dans un littéral AppleScript "…".
func asQuoted(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
     .replacingOccurrences(of: "\"", with: "\\\"")
}

let attendeeEmail = ProcessInfo.processInfo.environment["ONYX_E2E_ATTENDEE"]
    ?? "onyx-e2e-attendee@example.invalid"
```

- [ ] **Step 2: Utiliser dans le script AppleScript (lignes ~264-274)**

```swift
let appleScriptContent = """
tell application "Calendar"
    tell calendar "\(asQuoted(calName))"
        set newEvent to make new event at end with properties {summary:"\(asQuoted(eventTitle))", start date:date "\(startStr)", end date:date "\(endStr)", description:"\(asQuoted(eventNotes))"}
        tell newEvent
            make new attendee at end with properties {email:"\(asQuoted(attendeeEmail))"}
        end tell
        return uid of newEvent
    end tell
end tell
"""
```

- [ ] **Step 3: Vérifier**

Run: `swift build 2>&1 | tail -3` → OK. Vérifier `grep -c "yvan.betremieux@gmail.com" Sources/E2ETrigger/main.swift` → 0.

---

### Task 19: Scripts — checksum sherpa, cert hygiène, appcast guard, env E2E (H12-partie, M1-scripts, L1)

**Files:**
- Modify: `scripts/fetch-sherpa.sh`
- Modify: `scripts/setup-cert.sh`
- Modify: `scripts/generate-appcast.sh`
- Modify: `scripts/e2e-chantier-2.sh`

- [ ] **Step 1: Calculer le SHA-256 de l'archive sherpa (une fois)**

```bash
curl -sL "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.4/sherpa-onnx-v1.13.4-osx-universal2-shared.tar.bz2" | shasum -a 256
```

- [ ] **Step 2: `fetch-sherpa.sh` — épingler et vérifier**

Après la ligne `URL=…` ajouter :

```bash
# SHA-256 de l'archive de release épinglée — les dylibs sont dé-quarantainées
# et re-signées ad hoc plus bas : sans checksum, la chaîne n'a aucune défense
# supply-chain (code natif chargé dans un process qui écoute le micro).
SHA256_EXPECTED="<empreinte calculée au Step 1>"
```

Après le `curl` (ligne 25) ajouter :

```bash
echo "Verifying checksum..."
SHA256_ACTUAL="$(shasum -a 256 "${TMP}/${ASSET}" | awk '{print $1}')"
if [[ "${SHA256_ACTUAL}" != "${SHA256_EXPECTED}" ]]; then
  echo "FATAL: checksum mismatch for ${ASSET}" >&2
  echo "  expected: ${SHA256_EXPECTED}" >&2
  echo "  actual:   ${SHA256_ACTUAL}" >&2
  exit 1
fi
```

- [ ] **Step 3: `setup-cert.sh` — clé privée dans un répertoire temporaire privé**

Remplacer les usages de `/tmp/onyx*` par un mktemp privé :

```bash
#!/usr/bin/env bash
set -euo pipefail
NAME="Onyx Local"
if security find-identity -v -p codesigning login.keychain-db | grep -q "$NAME"; then
  echo "Cert '$NAME' already exists in login keychain."
  exit 0
fi
# Clé privée générée dans un répertoire temporaire privé (0700, chemin
# imprévisible) — pas dans /tmp partagé à noms fixes.
WORK="$(mktemp -d)"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/onyx-cert.conf" <<EOF
[req]
distinguished_name = req_dn
prompt = no
[req_dn]
CN = $NAME
EOF
openssl req -new -x509 -days 3650 -nodes \
    -config "$WORK/onyx-cert.conf" \
    -keyout "$WORK/onyx.key" -out "$WORK/onyx.crt"
openssl pkcs12 -export -out "$WORK/onyx.p12" \
    -inkey "$WORK/onyx.key" -in "$WORK/onyx.crt" -passout pass:onyx
security import "$WORK/onyx.p12" -k login.keychain-db -P onyx -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" login.keychain-db
echo "Cert '$NAME' installed. BACK IT UP: export to .p12 via Keychain Access."
```

- [ ] **Step 4: `generate-appcast.sh` — guard outil**

Après `set -euo pipefail` :

```bash
if ! command -v generate_appcast >/dev/null 2>&1; then
  echo "FATAL: generate_appcast (Sparkle tools) not found in PATH." >&2
  echo "Install: https://github.com/sparkle-project/Sparkle/releases (bin/generate_appcast)" >&2
  echo "It also requires the Sparkle EdDSA private key in the login keychain." >&2
  exit 1
fi
```

- [ ] **Step 5: `e2e-chantier-2.sh` — exporter ONYX_E2E=1**

Lire le script. Le diag `~/Meetings/.onyx-diag.json` n'est plus écrit qu'avec `ONYX_E2E=1` (Task 14). Repérer l'endroit où l'app Onyx est lancée (probablement `open dist/Onyx.app` ou exécution directe du binaire) et injecter l'env :
- si `open` : `open dist/Onyx.app --env ONYX_E2E=1` n'existe pas — utiliser `launchctl setenv ONYX_E2E 1` avant le `open` (et `launchctl unsetenv ONYX_E2E` en cleanup), ou lancer le binaire directement : `ONYX_E2E=1 "dist/Onyx.app/Contents/MacOS/Onyx" &`.
- si le script lance déjà le binaire directement, préfixer simplement `ONYX_E2E=1`.
Adapter à ce que fait réellement le script — le critère de done : le harnais retrouve son fichier de diag.

- [ ] **Step 6: Vérifier**

Run: `bash -n scripts/fetch-sherpa.sh scripts/setup-cert.sh scripts/generate-appcast.sh scripts/e2e-chantier-2.sh` → aucune erreur de syntaxe.

---

### Task 20: build-app.sh — bundle autonome : dylibs + Sparkle dans Frameworks, rpath propre, signature inside-out (C4)

**Files:**
- Modify: `scripts/build-app.sh`

- [ ] **Step 1: Inspecter l'état actuel des load commands (informatif)**

```bash
swift build -c release --arch arm64 2>&1 | tail -3
otool -L .build/arm64-apple-macosx/release/Onyx | head -20
otool -l .build/arm64-apple-macosx/release/Onyx | grep -A2 LC_RPATH
ls .build/arm64-apple-macosx/release/ | grep -i sparkle
otool -D Vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib
otool -L Vendor/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib | head -5
```

Noter : (a) comment le binaire référence les dylibs sherpa (`@rpath/...` attendu) ; (b) où est `Sparkle.framework` dans `.build` ; (c) l'install name des dylibs. Adapter le Step 2 si les références ne sont pas `@rpath/`.

- [ ] **Step 2: Réécrire `scripts/build-app.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
CONF="release"
APP_NAME="Onyx"
BUNDLE_ID="com.yvanbetremieux.onyx"
CERT_NAME="Onyx Local"
DIST_DIR="dist"
BUILD_DIR=".build/arm64-apple-macosx/release"
APP="$DIST_DIR/$APP_NAME.app"
VENDOR_LIB="Vendor/sherpa-onnx/lib"

echo "→ swift build -c $CONF"
swift build -c "$CONF" --arch arm64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Frameworks"

cp "$BUILD_DIR/Onyx"             "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist          "$APP/Contents/Info.plist"
cp Resources/Onyx.entitlements   "$APP/Contents/Resources/"

# --- Dépendances embarquées -------------------------------------------------
# Sans ça, le binaire dépendait d'un LC_RPATH ABSOLU vers Vendor/ : l'app ne
# se lançait sur aucune autre machine (dyld "Library not loaded") et cassait
# si le dossier projet bougeait.
echo "→ embed sherpa dylibs"
cp "$VENDOR_LIB/libsherpa-onnx-c-api.dylib" "$APP/Contents/Frameworks/"
cp "$VENDOR_LIB"/libonnxruntime*.dylib      "$APP/Contents/Frameworks/"

echo "→ embed Sparkle.framework"
if [[ -d "$BUILD_DIR/Sparkle.framework" ]]; then
  cp -R "$BUILD_DIR/Sparkle.framework" "$APP/Contents/Frameworks/"
else
  # SwiftPM peut matérialiser le xcframework ailleurs — le localiser.
  SPARKLE_SRC="$(find .build -name "Sparkle.framework" -type d \
                 -path "*macos*" -not -path "*ios*" | head -1)"
  if [[ -z "$SPARKLE_SRC" ]]; then
    SPARKLE_SRC="$(find .build -name "Sparkle.framework" -type d | head -1)"
  fi
  [[ -n "$SPARKLE_SRC" ]] || { echo "FATAL: Sparkle.framework not found in .build" >&2; exit 1; }
  cp -R "$SPARKLE_SRC" "$APP/Contents/Frameworks/"
fi

echo "→ fix rpaths"
BIN="$APP/Contents/MacOS/$APP_NAME"
ABS_RPATH="$(pwd)/$VENDOR_LIB"
install_name_tool -delete_rpath "$ABS_RPATH" "$BIN" 2>/dev/null || true
# Idempotent : -add_rpath échoue si déjà présent.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$BIN" 2>/dev/null || true
# libsherpa-onnx-c-api référence libonnxruntime via @rpath : lui donner
# @loader_path (les deux dylibs vivent dans Frameworks/).
install_name_tool -add_rpath "@loader_path" \
  "$APP/Contents/Frameworks/libsherpa-onnx-c-api.dylib" 2>/dev/null || true

# --- Signature inside-out (plus de --deep, déprécié et fragile) --------------
echo "→ codesign (inside-out) with '$CERT_NAME'"
for f in "$APP/Contents/Frameworks/"*.dylib; do
  codesign --force --options runtime --sign "$CERT_NAME" "$f"
done
if [[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]]; then
  codesign --force --options runtime --sign "$CERT_NAME" \
    "$APP/Contents/Frameworks/Sparkle.framework"
fi
codesign --force --options runtime \
  --entitlements Resources/Onyx.entitlements \
  --sign "$CERT_NAME" \
  "$APP"

echo "→ verify"
codesign --verify --verbose=2 "$APP"
spctl --assess --type execute --verbose=4 "$APP" || true
echo "→ sanity: no absolute rpath left"
if otool -l "$BIN" | grep -A2 LC_RPATH | grep -q "$(pwd)"; then
  echo "FATAL: absolute rpath still present in $BIN" >&2
  exit 1
fi
echo "Built $APP"
```

- [ ] **Step 3: Construire et vérifier le bundle**

```bash
bash scripts/build-app.sh
otool -l "dist/Onyx.app/Contents/MacOS/Onyx" | grep -A2 LC_RPATH
ls dist/Onyx.app/Contents/Frameworks/
```

Attendu : rpath `@executable_path/../Frameworks`, aucun rpath absolu, dylibs + Sparkle.framework présents. Puis lancement : `open dist/Onyx.app` → l'app démarre (icône menu bar).

Si dyld se plaint encore (référence non-`@rpath` notée au Step 1), corriger avec `install_name_tool -change "<ancienne référence>" "@rpath/<nom>.dylib" "$BIN"` dans le script, puis re-signer et re-tester.

---

### Task 21: Info.plist, docs/known-decisions.md (H8-doc, versions, décisions assumées)

**Files:**
- Modify: `Resources/Info.plist:11`
- Create: `docs/known-decisions.md`

- [ ] **Step 1: Version 0.2.0**

Dans `Resources/Info.plist`, remplacer `<string>0.1.0</string>` par `<string>0.2.0</string>` (clé `CFBundleShortVersionString`). L'orchestrateur et le storage lisent désormais cette valeur via `Bundle.main` (Task 14) — plus de "0.2.0" en dur incohérent.

- [ ] **Step 2: Créer `docs/known-decisions.md`**

```markdown
# Known decisions — choix techniques volontaires

Ce fichier liste les choix assumés qui ne doivent PAS être remontés comme
findings dans les revues de code.

## Distribution / signature (app non distribuée pour l'instant)
- **`SUFeedURL = https://example.invalid/appcast.xml`** : placeholder
  volontaire — échec bruyant plutôt qu'un feed accidentel. À remplacer par une
  URL HTTPS réelle **et** ajouter `SUPublicEDKey` (générée via
  `generate_keys` de Sparkle) avant toute distribution.
- **Certificat auto-signé "Onyx Local"** (`scripts/setup-cert.sh`) et
  **`com.apple.security.cs.disable-library-validation = true`** : setup de dev
  mono-machine. La distribution réelle exige Developer ID + notarisation et la
  suppression de cet entitlement.
- **`Package.resolved` non commité** : aucun usage de git sur cette machine
  pour ce projet (choix du propriétaire).

## Détection
- **Firefox non supporté** pour la détection Meet : pas d'API AppleScript
  d'énumération d'onglets. Idem Slack web. Les enregistrements calendrier
  fonctionnent quand même (auto-stop sur endDate + marge).
- **Slack Huddle : code constant "huddle"** — une seule huddle possible à la
  fois ; un identifiant de fenêtre était instable (recréation de fenêtre =
  arrêt en plein huddle).

## Modèles
- **Whisper téléchargé par WhisperKit** (snapshot HF multi-fichiers) : pas de
  checksum épinglé côté Onyx — l'intégrité est déléguée à WhisperKit/HF.
  Les assets sherpa (fichiers uniques), eux, sont épinglés SHA-256.
- **Pas de reprise (resumeData) des téléchargements de modèles** : un download
  interrompu repart de zéro. Volume acceptable (~35 MB pour sherpa).

## Audio
- **Pas de normalisation DSP** : `Normalizer` valide le format et copie — le
  recorder écrit déjà du 16 kHz mono float32.
- **`transcript.md` conservé, WAV supprimés après conversion m4a** (Cleanup).
```

- [ ] **Step 3: Vérifier**

Run: `plutil -lint Resources/Info.plist` → OK.

---

### Task 22: Vérification finale — suite complète, packaging, relance

- [ ] **Step 1: Suite de tests complète**

Run: `swift test 2>&1 | tail -15`
Attendu : 0 failure. Sinon, corriger avant de continuer.

- [ ] **Step 2: Grep anti-régression**

```bash
grep -rn "precondition(" Sources/RecorderCore/ && echo "FAIL: precondition restante" || echo OK
grep -rn "try!" Sources/Onyx/ | grep -v Regex && echo "à justifier" || echo OK
grep -rn "yvan.betremieux@gmail.com" Sources/ && echo FAIL || echo OK
grep -rn "startHostTime" Sources/ && echo FAIL || echo OK
```

- [ ] **Step 3: Packaging + lancement**

```bash
bash scripts/build-app.sh
pkill -x Onyx 2>/dev/null || true
open dist/Onyx.app
sleep 3 && pgrep -x Onyx && echo "Onyx running" || echo "FAIL: app did not start"
```

- [ ] **Step 4: Log check rapide**

```bash
log show --last 2m --predicate 'subsystem CONTAINS "onyx" OR process == "Onyx"' 2>/dev/null | tail -30
```

Vérifier : pas de crash, boucles bootées une seule fois.

---

## Self-review (fait à l'écriture du plan)

- **Couverture spec :** C1→T12, C2→T14, C3→T12, C4→T20 ; H1→T12+T14, H2→T7, H3→T8, H4→T12, H5→T11, H6→T4, H7→T2, H8→T16+T21 (feed/EdDSA documentés known-decisions — infra de distribution inexistante), H9→T14, H10→T9, H11→T10, H12→T17+T19, H13→T14, H14→T14 ; MEDIUMs→T1,3,4,5,7,9,11,13,14,15,16,17 ; LOWs→T4,5,6,9,14,17,18,19,21. Non traité volontairement : resumeData des downloads, bookmark sandbox meetingsFolder, Package.resolved (git interdit) — documentés dans known-decisions.md.
- **Types cohérents :** `RecordingSession.start → String` (T12) utilisé par FakeSession (T12) et RecorderSession (T12) ; `DataCollector` créé T6, utilisé T8/T9/T17 ; `Pipeline.setNotesConfig` créé T13, utilisé T14 ; `SettingsWindow(updater:)` créé T16, appelé T14 (note de compilation croisée incluse) ; `MeetingStorage(root:appVersion:)` existait déjà.
- **Dépendances d'ordre :** T6 (DataCollector) avant T8/T9/T17 ; T13 (setNotesConfig) avant T14 ; T12 (transitions) avant T14 ; T14 et T16 sont co-dépendants pour compiler (note incluse dans les deux).
