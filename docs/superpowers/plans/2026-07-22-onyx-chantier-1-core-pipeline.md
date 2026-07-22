# Onyx Chantier 1 — Core Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a menu-bar macOS app that records mic + system audio, transcribes and diarises it 100 % offline, and stores each meeting in a predictable on-disk layout with a rebuildable SQLite index.

**Architecture:** Swift 5.9 / SwiftPM project split into a pure `RecorderCore` library and an `Onyx` executable (menu-bar app). Pipeline is disk-driven and idempotent: each step reads status from `job.json`, writes its artifact, marks the step `done`. Crash-safe by design.

**Tech Stack:** Swift 5.9+, macOS 13+, AVFoundation, ScreenCaptureKit, WhisperKit (`large-v3`), sherpa-onnx (pyannote segmentation + 3D-Speaker embedding), GRDB.swift (SQLite), Sparkle (auto-update), XCTest.

**Reference spec:** `docs/superpowers/specs/2026-07-22-onyx-chantier-1-core-pipeline-design.md`

**Autonomous decisions locked in for this plan:**
- Bundle identifier: `com.yvanbetremieux.onyx`
- Code-signing identity (self-signed, generated in Keychain once): `Onyx Local`
- Whisper model: `openai_whisper-large-v3` (auto-downloaded by WhisperKit)
- Diarisation models: `sherpa-onnx-pyannote-segmentation-3-0` + `3dspeaker_speaker-embedding_eres2net_base_sv_zh-cn_3dspeaker_16k`
- Meeting folder root: `~/Meetings/` (overridable in Settings later)
- Model cache root: `~/Library/Application Support/Onyx/models/`
- Index DB path: `~/Library/Application Support/Onyx/index.sqlite`
- Testing: XCTest (aligned with WinTab)

---

## File Structure

```
Onyx/
  Package.swift
  .gitignore
  Sources/
    RecorderCore/
      Support/
        MeetingPaths.swift            # slug + path helpers
        AtomicJSON.swift              # atomic JSON read/write
        Clock.swift                   # shared CMClock for recorders
        Log.swift                     # os.Logger wrapper
      Storage/
        MeetingMetadata.swift         # meta.json model
        JobState.swift                # job.json state machine
        MeetingStorage.swift          # create dirs, write meta/job atomically
      Index/
        IndexSchema.swift             # SQL DDL, migrations
        MeetingIndexer.swift          # GRDB DB pool + insert/upsert
        RescanRunner.swift            # walk ~/Meetings, repopulate index
      Recorder/
        MicRecorder.swift             # AVAudioEngine → wav
        SystemAudioRecorder.swift     # SCStream → wav
        Recorder.swift                # facade coord mic + system
        WavWriter.swift               # 16k mono float32 WAV writer w/ header rewrite
        Mp4Converter.swift            # wav → m4a via AVAssetWriter
      Models/
        ModelManifest.swift           # URLs, expected sizes, sha256
        ModelDownloader.swift         # progress-reporting downloader
      Transcription/
        WhisperTranscriber.swift      # WhisperKit wrapper
      Diarization/
        Diarizer.swift                # sherpa-onnx wrapper
      Pipeline/
        Normalizer.swift              # ensure input format for whisper
        Merger.swift                  # align mic + system whisper + diarisation
        MarkdownRenderer.swift        # transcript.json → transcript.md
        Pipeline.swift                # orchestrator, idempotent
        Cleanup.swift                 # wav → m4a, delete intermediates
    Onyx/
      App.swift                       # OnyxApp @main + MenuBarExtra
      AppState.swift                  # ObservableObject exposed to UI
      Menu/
        MenuBarView.swift             # the menu content
        MenuBarIcon.swift             # icon states (grey/red/yellow)
      Onboarding/
        OnboardingWindow.swift        # single-window sequential flow
        PermissionsChecker.swift      # mic + screen recording checks
        ModelDownloadView.swift       # progress UI
      Settings/
        SettingsWindow.swift
        SettingsStore.swift           # UserDefaults-backed
      Hotkey/
        GlobalHotkey.swift            # Carbon RegisterEventHotKey
      Update/
        UpdaterController.swift       # SparkleUpdater bridge
  Tests/
    RecorderCoreTests/
      MeetingPathsTests.swift
      MeetingMetadataTests.swift
      JobStateTests.swift
      MeetingStorageTests.swift
      MeetingIndexerTests.swift
      RescanRunnerTests.swift
      WavWriterTests.swift
      MergerTests.swift
      MarkdownRendererTests.swift
      PipelineTests.swift
      Fixtures/
        sample_transcripts.json       # for merger/renderer
        sample_audio_30s.wav          # for pipeline integration (created by task)
  scripts/
    setup-cert.sh                     # one-time: create self-signed cert
    build-app.sh                      # build + bundle + sign Onyx.app
    generate-appcast.sh               # Sparkle appcast for releases
  Resources/
    Info.plist                        # app bundle Info.plist template
    Onyx.entitlements                 # hardened runtime entitlements
    AppIcon.icns                      # placeholder icon (task 1)
  docs/
    superpowers/
      specs/2026-07-22-onyx-chantier-1-core-pipeline-design.md
      plans/2026-07-22-onyx-chantier-1-core-pipeline.md
```

---

## Task 1: Bootstrap SwiftPM project

**Files:**
- Create: `Package.swift`
- Create: `.gitignore`
- Create: `Sources/RecorderCore/Support/Log.swift`
- Create: `Sources/Onyx/App.swift`
- Create: `Tests/RecorderCoreTests/SmokeTest.swift`

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Onyx",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RecorderCore", targets: ["RecorderCore"]),
        .executable(name: "Onyx", targets: ["Onyx"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "RecorderCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
        .executableTarget(
            name: "Onyx",
            dependencies: [
                "RecorderCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .testTarget(name: "RecorderCoreTests", dependencies: ["RecorderCore"]),
    ]
)
```

Sherpa-onnx SwiftPM integration is added in Task 15; if the SwiftPM package resolution fails we fall back to an XCFramework drop-in there.

- [ ] **Step 2: Write `.gitignore`**

```gitignore
.build/
.swiftpm/
DerivedData/
*.xcodeproj/
Onyx.app/
build/
dist/
*.dmg
*.zip
appcast.xml
.DS_Store
```

- [ ] **Step 3: Write `Sources/RecorderCore/Support/Log.swift`**

```swift
import Foundation
import os

public enum Log {
    public static let recorder     = Logger(subsystem: "com.yvanbetremieux.onyx", category: "recorder")
    public static let pipeline     = Logger(subsystem: "com.yvanbetremieux.onyx", category: "pipeline")
    public static let storage      = Logger(subsystem: "com.yvanbetremieux.onyx", category: "storage")
    public static let transcription = Logger(subsystem: "com.yvanbetremieux.onyx", category: "transcription")
    public static let diarization  = Logger(subsystem: "com.yvanbetremieux.onyx", category: "diarization")
    public static let ui           = Logger(subsystem: "com.yvanbetremieux.onyx", category: "ui")
}
```

- [ ] **Step 4: Write `Sources/Onyx/App.swift` (minimal stub)**

```swift
import SwiftUI

@main
struct OnyxApp: App {
    var body: some Scene {
        MenuBarExtra("Onyx", systemImage: "mic") {
            Text("Onyx v0.1.0")
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)
    }
}
```

- [ ] **Step 5: Write smoke test**

`Tests/RecorderCoreTests/SmokeTest.swift`:
```swift
import XCTest
@testable import RecorderCore

final class SmokeTest: XCTestCase {
    func testLoggerAvailable() {
        Log.storage.info("smoke test log")
    }
}
```

- [ ] **Step 6: Build & test**

Run:
```bash
swift build
swift test
```

Expected: build succeeds, 1 test passes. Downloads deps on first run.

- [ ] **Step 7: Commit**

```bash
git add Package.swift .gitignore Sources Tests
git commit -m "chore: bootstrap SwiftPM project structure"
```

---

## Task 2: Meeting slug + paths (`MeetingPaths`)

**Files:**
- Create: `Sources/RecorderCore/Support/MeetingPaths.swift`
- Test: `Tests/RecorderCoreTests/MeetingPathsTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import RecorderCore

final class MeetingPathsTests: XCTestCase {
    func testSlugFromDateIsStable() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 22
        comps.hour = 14; comps.minute = 32
        comps.timeZone = TimeZone(identifier: "Europe/Paris")
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        XCTAssertEqual(MeetingPaths.slug(for: date, timeZone: comps.timeZone!),
                       "2026-07-22_14h32")
    }

    func testMeetingFolderComposition() {
        let root = URL(fileURLWithPath: "/tmp/Meetings")
        let paths = MeetingPaths(root: root, slug: "2026-07-22_14h32")
        XCTAssertEqual(paths.root.path,        "/tmp/Meetings/2026-07-22_14h32")
        XCTAssertEqual(paths.audio.path,       "/tmp/Meetings/2026-07-22_14h32/audio")
        XCTAssertEqual(paths.transcripts.path, "/tmp/Meetings/2026-07-22_14h32/transcripts")
        XCTAssertEqual(paths.meta.path,        "/tmp/Meetings/2026-07-22_14h32/meta.json")
        XCTAssertEqual(paths.job.path,         "/tmp/Meetings/2026-07-22_14h32/job.json")
        XCTAssertEqual(paths.transcriptMd.path,"/tmp/Meetings/2026-07-22_14h32/transcripts/transcript.md")
    }
}
```

- [ ] **Step 2: Run tests (expected: FAIL — MeetingPaths undefined)**

Run: `swift test --filter MeetingPathsTests`

- [ ] **Step 3: Implement `MeetingPaths`**

```swift
import Foundation

public struct MeetingPaths: Equatable {
    public let root: URL
    public let slug: String

    public init(root: URL, slug: String) {
        self.root = root.appendingPathComponent(slug, isDirectory: true)
        self.slug = slug
    }

    public var audio: URL          { root.appendingPathComponent("audio", isDirectory: true) }
    public var transcripts: URL    { root.appendingPathComponent("transcripts", isDirectory: true) }
    public var meta: URL           { root.appendingPathComponent("meta.json") }
    public var job: URL            { root.appendingPathComponent("job.json") }

    public var micWav: URL         { audio.appendingPathComponent("mic.wav") }
    public var systemWav: URL      { audio.appendingPathComponent("system.wav") }
    public var micNormalized: URL  { audio.appendingPathComponent("mic_normalized.wav") }
    public var systemNormalized: URL { audio.appendingPathComponent("system_normalized.wav") }
    public var micM4a: URL         { audio.appendingPathComponent("mic.m4a") }
    public var systemM4a: URL      { audio.appendingPathComponent("system.m4a") }

    public var whisperMic: URL     { transcripts.appendingPathComponent("whisper_mic.json") }
    public var whisperSystem: URL  { transcripts.appendingPathComponent("whisper_system.json") }
    public var diarization: URL    { transcripts.appendingPathComponent("diarization.json") }
    public var transcriptJson: URL { transcripts.appendingPathComponent("transcript.json") }
    public var transcriptMd: URL   { transcripts.appendingPathComponent("transcript.md") }

    public static func slug(for date: Date, timeZone: TimeZone = .current) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = timeZone
        fmt.dateFormat = "yyyy-MM-dd_HH'h'mm"
        return fmt.string(from: date)
    }
}
```

- [ ] **Step 4: Run tests (expected: PASS)**

Run: `swift test --filter MeetingPathsTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/RecorderCore/Support/MeetingPaths.swift Tests/RecorderCoreTests/MeetingPathsTests.swift
git commit -m "feat(storage): MeetingPaths — slug + on-disk path helpers"
```

---

## Task 3: Atomic JSON helper

**Files:**
- Create: `Sources/RecorderCore/Support/AtomicJSON.swift`

- [ ] **Step 1: Write `AtomicJSON.swift`**

Used everywhere we persist state; failure mid-write must never leave a half-written JSON on disk.

```swift
import Foundation

public enum AtomicJSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        let tmp = url.appendingPathExtension("tmp.\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try decoder.decode(type, from: data)
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`. Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/RecorderCore/Support/AtomicJSON.swift
git commit -m "feat(support): AtomicJSON for crash-safe state writes"
```

---

## Task 4: `MeetingMetadata` model

**Files:**
- Create: `Sources/RecorderCore/Storage/MeetingMetadata.swift`
- Test: `Tests/RecorderCoreTests/MeetingMetadataTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
@testable import RecorderCore

final class MeetingMetadataTests: XCTestCase {
    func testRoundTripJSON() throws {
        let started = Date(timeIntervalSince1970: 1_784_819_535) // deterministic
        let meta = MeetingMetadata(
            id: "2026-07-22_14h32",
            startedAt: started,
            endedAt: nil,
            durationSeconds: nil,
            title: nil,
            source: .manual,
            appVersion: "0.1.0",
            models: .init(whisper: "large-v3", diarization: "sherpa-pyannote-3.1")
        )
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meta-\(UUID().uuidString).json")
        try AtomicJSON.write(meta, to: tmp)
        let back = try AtomicJSON.read(MeetingMetadata.self, from: tmp)
        XCTAssertEqual(back, meta)
    }
}
```

- [ ] **Step 2: Run (FAIL)**

Run: `swift test --filter MeetingMetadataTests`

- [ ] **Step 3: Implement**

```swift
import Foundation

public struct MeetingMetadata: Codable, Equatable {
    public enum Source: String, Codable { case manual, calendar, huddle }

    public struct Models: Codable, Equatable {
        public var whisper: String
        public var diarization: String
        public init(whisper: String, diarization: String) {
            self.whisper = whisper; self.diarization = diarization
        }
    }

    public var id: String
    public var startedAt: Date
    public var endedAt: Date?
    public var durationSeconds: Int?
    public var title: String?
    public var source: Source
    public var appVersion: String
    public var models: Models

    public init(id: String, startedAt: Date, endedAt: Date?, durationSeconds: Int?,
                title: String?, source: Source, appVersion: String, models: Models) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.title = title
        self.source = source
        self.appVersion = appVersion
        self.models = models
    }
}
```

- [ ] **Step 4: Run (PASS)**

`swift test --filter MeetingMetadataTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/RecorderCore/Storage/MeetingMetadata.swift Tests/RecorderCoreTests/MeetingMetadataTests.swift
git commit -m "feat(storage): MeetingMetadata model + JSON round-trip test"
```

---

## Task 5: `JobState` machine

**Files:**
- Create: `Sources/RecorderCore/Storage/JobState.swift`
- Test: `Tests/RecorderCoreTests/JobStateTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import RecorderCore

final class JobStateTests: XCTestCase {
    func testFreshJobHasAllPendingSteps() {
        let job = JobState.fresh()
        XCTAssertEqual(job.state, .recording)
        for step in JobStep.allCases {
            XCTAssertEqual(job.steps[step]?.status, .pending)
        }
    }

    func testMarkDoneUpdatesStep() {
        var job = JobState.fresh()
        job.markStarted(.normalize, at: Date(timeIntervalSince1970: 1))
        job.markDone(.normalize, at: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(job.steps[.normalize]?.status, .done)
        XCTAssertEqual(job.steps[.normalize]?.startedAt?.timeIntervalSince1970, 1)
        XCTAssertEqual(job.steps[.normalize]?.completedAt?.timeIntervalSince1970, 2)
    }

    func testIsResumableWhenNotTerminal() {
        var job = JobState.fresh()
        job.state = .transcribing
        XCTAssertTrue(job.isResumable)
        job.state = .done; XCTAssertFalse(job.isResumable)
        job.state = .failed; XCTAssertFalse(job.isResumable)
    }
}
```

- [ ] **Step 2: Run (FAIL)**

- [ ] **Step 3: Implement**

```swift
import Foundation

public enum JobStep: String, CaseIterable, Codable {
    case normalize, whisperMic = "whisper_mic", whisperSystem = "whisper_system",
         diarize, merge, render, cleanup
}

public enum JobStepStatus: String, Codable {
    case pending, inProgress = "in_progress", done, failed
}

public enum JobOverallState: String, Codable {
    case recording, normalizing, transcribing, diarizing, merging, rendering, cleanup, done, failed
}

public struct JobStepRecord: Codable, Equatable {
    public var status: JobStepStatus
    public var startedAt: Date?
    public var completedAt: Date?
    public var error: String?
    public init(status: JobStepStatus = .pending, startedAt: Date? = nil,
                completedAt: Date? = nil, error: String? = nil) {
        self.status = status; self.startedAt = startedAt
        self.completedAt = completedAt; self.error = error
    }
}

public struct JobState: Codable, Equatable {
    public var state: JobOverallState
    public var steps: [JobStep: JobStepRecord]
    public var error: String?

    public init(state: JobOverallState, steps: [JobStep: JobStepRecord], error: String? = nil) {
        self.state = state; self.steps = steps; self.error = error
    }

    public static func fresh() -> JobState {
        var s = [JobStep: JobStepRecord]()
        for step in JobStep.allCases { s[step] = JobStepRecord() }
        return JobState(state: .recording, steps: s)
    }

    public var isResumable: Bool { state != .done && state != .failed }
    public func stepStatus(_ step: JobStep) -> JobStepStatus { steps[step]?.status ?? .pending }

    public mutating func markStarted(_ step: JobStep, at date: Date = Date()) {
        var rec = steps[step] ?? JobStepRecord()
        rec.status = .inProgress; rec.startedAt = date; rec.error = nil
        steps[step] = rec
    }

    public mutating func markDone(_ step: JobStep, at date: Date = Date()) {
        var rec = steps[step] ?? JobStepRecord()
        rec.status = .done; rec.completedAt = date; rec.error = nil
        steps[step] = rec
    }

    public mutating func markFailed(_ step: JobStep, error: String, at date: Date = Date()) {
        var rec = steps[step] ?? JobStepRecord()
        rec.status = .failed; rec.completedAt = date; rec.error = error
        steps[step] = rec
        state = .failed
        self.error = error
    }

    // Custom JSON coding to keep dictionary key = JobStep.rawValue.
    private enum CodingKeys: String, CodingKey { case state, steps, error }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(JobOverallState.self, forKey: .state)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        let raw = try c.decode([String: JobStepRecord].self, forKey: .steps)
        var out = [JobStep: JobStepRecord]()
        for (k, v) in raw {
            guard let step = JobStep(rawValue: k) else {
                throw DecodingError.dataCorruptedError(forKey: .steps, in: c,
                    debugDescription: "unknown step \(k)")
            }
            out[step] = v
        }
        for step in JobStep.allCases where out[step] == nil { out[step] = JobStepRecord() }
        steps = out
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(error, forKey: .error)
        let raw = Dictionary(uniqueKeysWithValues: steps.map { ($0.key.rawValue, $0.value) })
        try c.encode(raw, forKey: .steps)
    }
}
```

- [ ] **Step 4: Run (PASS)**

`swift test --filter JobStateTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/RecorderCore/Storage/JobState.swift Tests/RecorderCoreTests/JobStateTests.swift
git commit -m "feat(storage): JobState machine + JSON coding"
```

---

## Task 6: `MeetingStorage` — create/read meeting folders

**Files:**
- Create: `Sources/RecorderCore/Storage/MeetingStorage.swift`
- Test: `Tests/RecorderCoreTests/MeetingStorageTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import RecorderCore

final class MeetingStorageTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("onyx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCreateMeetingProducesLayoutAndInitialFiles() throws {
        let storage = MeetingStorage(root: root)
        let paths = try storage.createMeeting(startedAt: Date(timeIntervalSince1970: 1_784_819_535))
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.audio.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.meta.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.job.path))
        let meta = try AtomicJSON.read(MeetingMetadata.self, from: paths.meta)
        XCTAssertEqual(meta.source, .manual)
        let job = try AtomicJSON.read(JobState.self, from: paths.job)
        XCTAssertEqual(job.state, .recording)
    }

    func testListMeetingsReturnsSortedDescending() throws {
        let storage = MeetingStorage(root: root)
        _ = try storage.createMeeting(startedAt: Date(timeIntervalSince1970: 1_000_000_000))
        _ = try storage.createMeeting(startedAt: Date(timeIntervalSince1970: 1_100_000_000))
        let list = try storage.listMeetings()
        XCTAssertEqual(list.count, 2)
        XCTAssertGreaterThan(list[0].slug, list[1].slug)
    }
}
```

- [ ] **Step 2: Run (FAIL)**

- [ ] **Step 3: Implement**

```swift
import Foundation

public final class MeetingStorage {
    public let root: URL
    private let fileManager: FileManager
    private let appVersion: String

    public init(root: URL, fileManager: FileManager = .default, appVersion: String = "0.1.0") {
        self.root = root
        self.fileManager = fileManager
        self.appVersion = appVersion
    }

    public func createMeeting(startedAt: Date, timeZone: TimeZone = .current) throws -> MeetingPaths {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let slug = MeetingPaths.slug(for: startedAt, timeZone: timeZone)
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

    public func loadMetadata(_ paths: MeetingPaths) throws -> MeetingMetadata {
        try AtomicJSON.read(MeetingMetadata.self, from: paths.meta)
    }

    public func saveMetadata(_ meta: MeetingMetadata, at paths: MeetingPaths) throws {
        try AtomicJSON.write(meta, to: paths.meta)
    }

    public func loadJob(_ paths: MeetingPaths) throws -> JobState {
        try AtomicJSON.read(JobState.self, from: paths.job)
    }

    public func saveJob(_ job: JobState, at paths: MeetingPaths) throws {
        try AtomicJSON.write(job, to: paths.job)
    }

    public struct Listing: Equatable {
        public let slug: String
        public let path: URL
    }

    public func listMeetings() throws -> [Listing] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        let entries = try fileManager.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { Listing(slug: $0.lastPathComponent, path: $0) }
            .sorted { $0.slug > $1.slug }
    }
}
```

- [ ] **Step 4: Run (PASS)**

`swift test --filter MeetingStorageTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/RecorderCore/Storage/MeetingStorage.swift Tests/RecorderCoreTests/MeetingStorageTests.swift
git commit -m "feat(storage): MeetingStorage — create dirs, meta, job"
```

---

## Task 7: WAV writer (16 kHz mono float32 with header rewrite)

**Files:**
- Create: `Sources/RecorderCore/Recorder/WavWriter.swift`
- Test: `Tests/RecorderCoreTests/WavWriterTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
@testable import RecorderCore

final class WavWriterTests: XCTestCase {
    func testProducesValidWavHeaderAfterFinish() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("t-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let writer = try WavWriter(url: tmp, sampleRate: 16000, channels: 1)
        let samples = [Float](repeating: 0.1, count: 16000) // 1 s
        try samples.withUnsafeBufferPointer { try writer.write($0) }
        try writer.finish()

        let data = try Data(contentsOf: tmp)
        XCTAssertGreaterThan(data.count, 44)                                   // header + payload
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data[36..<40], encoding: .ascii), "data")
        // subformat: IEEE_FLOAT (3) little-endian at offset 20..22
        XCTAssertEqual(data[20], 3); XCTAssertEqual(data[21], 0)
    }

    func testHeaderRewriteDuringRecordingKeepsFileReadable() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("t-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let writer = try WavWriter(url: tmp, sampleRate: 16000, channels: 1)
        let block = [Float](repeating: 0.0, count: 16000)
        try block.withUnsafeBufferPointer { try writer.write($0) }
        try writer.flushHeader()

        let mid = try Data(contentsOf: tmp)
        // ChunkSize at offset 4 (little-endian UInt32)
        let chunkSize = mid.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertGreaterThan(chunkSize, 0)
    }
}
```

- [ ] **Step 2: Run (FAIL)**

- [ ] **Step 3: Implement**

```swift
import Foundation

public final class WavWriter {
    private let handle: FileHandle
    private let sampleRate: UInt32
    private let channels: UInt16
    private let bitsPerSample: UInt16 = 32
    private var byteCount: UInt64 = 0
    private var closed = false

    public init(url: URL, sampleRate: Int, channels: Int) throws {
        self.sampleRate = UInt32(sampleRate)
        self.channels = UInt16(channels)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
        try writeHeader(dataBytes: 0) // placeholder
    }

    public func write(_ samples: UnsafeBufferPointer<Float>) throws {
        let data = Data(buffer: samples)
        try handle.write(contentsOf: data)
        byteCount += UInt64(data.count)
    }

    /// Rewrite the RIFF/data sizes so an outside reader sees a valid file mid-recording.
    public func flushHeader() throws {
        try handle.synchronize()
        let cur = try handle.offset()
        try handle.seek(toOffset: 0)
        try writeHeader(dataBytes: UInt32(byteCount))
        try handle.seek(toOffset: cur)
        try handle.synchronize()
    }

    public func finish() throws {
        guard !closed else { return }
        try flushHeader()
        try handle.close()
        closed = true
    }

    deinit { try? finish() }

    private func writeHeader(dataBytes: UInt32) throws {
        var header = Data(count: 44)
        header.replaceSubrange(0..<4,  with: "RIFF".data(using: .ascii)!)
        header.setLE(UInt32(36 &+ dataBytes),      at: 4)   // ChunkSize
        header.replaceSubrange(8..<12, with: "WAVE".data(using: .ascii)!)
        header.replaceSubrange(12..<16, with: "fmt ".data(using: .ascii)!)
        header.setLE(UInt32(16),                   at: 16)  // Subchunk1Size = 16 for PCM/float
        header.setLE(UInt16(3),                    at: 20)  // AudioFormat = 3 (IEEE float)
        header.setLE(channels,                     at: 22)
        header.setLE(sampleRate,                   at: 24)
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        header.setLE(byteRate,                     at: 28)
        let blockAlign = channels * (bitsPerSample / 8)
        header.setLE(blockAlign,                   at: 32)
        header.setLE(bitsPerSample,                at: 34)
        header.replaceSubrange(36..<40, with: "data".data(using: .ascii)!)
        header.setLE(dataBytes,                    at: 40)  // Subchunk2Size
        try handle.write(contentsOf: header)
    }
}

private extension Data {
    mutating func setLE<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { bytes in
            replaceSubrange(offset..<offset + MemoryLayout<T>.size, with: bytes)
        }
    }
}
```

- [ ] **Step 4: Run (PASS)**

`swift test --filter WavWriterTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/RecorderCore/Recorder/WavWriter.swift Tests/RecorderCoreTests/WavWriterTests.swift
git commit -m "feat(recorder): WavWriter — crash-safe 16k mono float32 WAV"
```

---

## Task 8: `MicRecorder` (AVAudioEngine → WAV)

**Files:**
- Create: `Sources/RecorderCore/Recorder/MicRecorder.swift`

- [ ] **Step 1: Implement**

```swift
import AVFoundation

public final class MicRecorder {
    public struct Config {
        public var sampleRate: Double = 16_000
        public init() {}
    }

    private let engine = AVAudioEngine()
    private let config: Config
    private var writer: WavWriter?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat!
    private var startHostTime: UInt64 = 0

    public init(config: Config = .init()) { self.config = config }

    /// Host time (mach_absolute_time) at which recording started, for cross-source alignment.
    public var startHostTimeNs: UInt64 { startHostTime }

    public func start(writingTo url: URL) throws {
        writer = try WavWriter(url: url, sampleRate: Int(config.sampleRate), channels: 1)
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: config.sampleRate,
            channels: 1,
            interleaved: false)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buf, when in
            guard let self else { return }
            if self.startHostTime == 0 { self.startHostTime = when.hostTime }
            self.process(inputBuffer: buf)
        }
        try engine.start()
        Log.recorder.info("MicRecorder started at hostTime \(self.startHostTime)")
    }

    public func stop() throws {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try writer?.finish()
        writer = nil
        Log.recorder.info("MicRecorder stopped")
    }

    public func flushHeader() throws { try writer?.flushHeader() }

    private func process(inputBuffer: AVAudioPCMBuffer) {
        guard let converter, let writer else { return }
        let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var err: NSError?
        var supplied = false
        let status = converter.convert(to: out, error: &err) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true; outStatus.pointee = .haveData; return inputBuffer
        }
        if status == .error {
            Log.recorder.error("Mic conversion error: \(err?.localizedDescription ?? "?")")
            return
        }
        guard let ch = out.floatChannelData?[0] else { return }
        let count = Int(out.frameLength)
        let buffer = UnsafeBufferPointer(start: ch, count: count)
        do { try writer.write(buffer) }
        catch { Log.recorder.error("Mic writer failed: \(error.localizedDescription)") }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`. Expected: success.

Note: no unit test — depends on real mic input. Covered by the manual integration test in Task 18.

- [ ] **Step 3: Commit**

```bash
git add Sources/RecorderCore/Recorder/MicRecorder.swift
git commit -m "feat(recorder): MicRecorder — AVAudioEngine 16k mono → WAV"
```

---

## Task 9: `SystemAudioRecorder` (ScreenCaptureKit → WAV)

**Files:**
- Create: `Sources/RecorderCore/Recorder/SystemAudioRecorder.swift`

- [ ] **Step 1: Implement**

```swift
import ScreenCaptureKit
import AVFoundation

@available(macOS 13.0, *)
public final class SystemAudioRecorder: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private var writer: WavWriter?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat!
    private var startHostTime: UInt64 = 0

    public var startHostTimeNs: UInt64 { startHostTime }

    public func start(writingTo url: URL) async throws {
        writer = try WavWriter(url: url, sampleRate: 16_000, channels: 1)
        targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: 16_000, channels: 1, interleaved: false)

        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                           onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "Onyx", code: 100,
                          userInfo: [NSLocalizedDescriptionKey: "No display for SCStream"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2

        let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        try await s.startCapture()
        self.stream = s
        Log.recorder.info("SystemAudioRecorder started")
    }

    public func stop() async throws {
        try await stream?.stopCapture()
        stream = nil
        try writer?.finish()
        writer = nil
        Log.recorder.info("SystemAudioRecorder stopped")
    }

    public func flushHeader() throws { try writer?.flushHeader() }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid, CMSampleBufferDataIsReady(sb) else { return }
        if startHostTime == 0 {
            let host = mach_absolute_time()
            startHostTime = host
        }
        guard let pcm = pcmBuffer(from: sb), let writer else { return }
        writeConverted(pcm, to: writer)
    }

    private func pcmBuffer(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc)?.pointee
        else { return nil }
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
        CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames),
                                                     into: buf.mutableAudioBufferList)
        return buf
    }

    private func writeConverted(_ input: AVAudioPCMBuffer, to writer: WavWriter) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var err: NSError?
        var supplied = false
        let status = converter.convert(to: out, error: &err) { _, s in
            if supplied { s.pointee = .noDataNow; return nil }
            supplied = true; s.pointee = .haveData; return input
        }
        if status == .error {
            Log.recorder.error("System conv error: \(err?.localizedDescription ?? "?")")
            return
        }
        guard let ch = out.floatChannelData?[0] else { return }
        let bp = UnsafeBufferPointer(start: ch, count: Int(out.frameLength))
        do { try writer.write(bp) }
        catch { Log.recorder.error("System writer failed: \(error.localizedDescription)") }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`.

- [ ] **Step 3: Commit**

```bash
git add Sources/RecorderCore/Recorder/SystemAudioRecorder.swift
git commit -m "feat(recorder): SystemAudioRecorder via ScreenCaptureKit"
```

---

## Task 10: `Recorder` facade + header-flush timer

**Files:**
- Create: `Sources/RecorderCore/Recorder/Recorder.swift`

- [ ] **Step 1: Implement**

```swift
import Foundation

@available(macOS 13.0, *)
public final class Recorder {
    public enum State: String { case idle, recording, stopping }

    public private(set) var state: State = .idle
    public private(set) var paths: MeetingPaths?
    public private(set) var startedAt: Date?

    private let storage: MeetingStorage
    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()
    private var flushTimer: Timer?

    public init(storage: MeetingStorage) { self.storage = storage }

    public func start() async throws -> MeetingPaths {
        precondition(state == .idle, "Recorder must be idle to start")
        let now = Date()
        let paths = try storage.createMeeting(startedAt: now)
        self.paths = paths; self.startedAt = now
        state = .recording

        try mic.start(writingTo: paths.micWav)
        try await system.start(writingTo: paths.systemWav)

        flushTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            try? self?.mic.flushHeader()
            try? self?.system.flushHeader()
        }
        Log.recorder.info("Recorder started for \(paths.slug)")
        return paths
    }

    public func stop() async throws -> MeetingPaths {
        guard state == .recording, let paths, let startedAt else {
            throw NSError(domain: "Onyx", code: 200,
                          userInfo: [NSLocalizedDescriptionKey: "Not recording"])
        }
        state = .stopping
        flushTimer?.invalidate(); flushTimer = nil
        try mic.stop()
        try await system.stop()

        var meta = try storage.loadMetadata(paths)
        let end = Date()
        meta.endedAt = end
        meta.durationSeconds = Int(end.timeIntervalSince(startedAt))
        try storage.saveMetadata(meta, at: paths)

        var job = try storage.loadJob(paths)
        job.state = .normalizing
        try storage.saveJob(job, at: paths)

        state = .idle
        Log.recorder.info("Recorder stopped, duration=\(meta.durationSeconds ?? 0)s")
        return paths
    }
}
```

- [ ] **Step 2: Build**

- [ ] **Step 3: Commit**

```bash
git add Sources/RecorderCore/Recorder/Recorder.swift
git commit -m "feat(recorder): Recorder facade — coord mic + system + flush"
```

---

## Task 11: `Mp4Converter` (WAV → M4A)

**Files:**
- Create: `Sources/RecorderCore/Recorder/Mp4Converter.swift`

- [ ] **Step 1: Implement**

```swift
import AVFoundation

public enum Mp4Converter {
    public static func convert(wav: URL, to m4a: URL) async throws {
        let asset = AVURLAsset(url: wav)
        guard let export = AVAssetExportSession(asset: asset,
                                                presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "Onyx", code: 300,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create exporter"])
        }
        try? FileManager.default.removeItem(at: m4a)
        export.outputURL = m4a
        export.outputFileType = .m4a
        await export.export()
        if export.status != .completed {
            throw export.error ?? NSError(domain: "Onyx", code: 301)
        }
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
swift build
git add Sources/RecorderCore/Recorder/Mp4Converter.swift
git commit -m "feat(recorder): Mp4Converter — AVAssetExportSession"
```

---

## Task 12: `Merger` — align three sources

**Files:**
- Create: `Sources/RecorderCore/Pipeline/Merger.swift`
- Test: `Tests/RecorderCoreTests/MergerTests.swift`

- [ ] **Step 1: Define wire types**

Add to `Sources/RecorderCore/Pipeline/Merger.swift`:

```swift
import Foundation

public struct WhisperSegment: Codable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public var confidence: Double?
    public init(start: Double, end: Double, text: String, confidence: Double? = nil) {
        self.start = start; self.end = end; self.text = text; self.confidence = confidence
    }
}

public struct DiarSegment: Codable, Equatable {
    public var start: Double
    public var end: Double
    public var speakerId: String
    public init(start: Double, end: Double, speakerId: String) {
        self.start = start; self.end = end; self.speakerId = speakerId
    }
    private enum CodingKeys: String, CodingKey { case start, end, speakerId = "speaker_id" }
}

public struct TranscriptSegment: Codable, Equatable {
    public var start: Double
    public var end: Double
    public var speaker: String
    public var text: String
}

public enum Merger {
    /// Combine mic (tagged "MOI") and system Whisper segments (assigned to the diarisation
    /// speaker whose interval overlaps the segment most).
    public static func merge(mic: [WhisperSegment],
                             system: [WhisperSegment],
                             diarization: [DiarSegment]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        for m in mic {
            out.append(.init(start: m.start, end: m.end, speaker: "MOI", text: m.text))
        }
        for s in system {
            let speaker = assignSpeaker(to: s, diar: diarization)
            out.append(.init(start: s.start, end: s.end, speaker: speaker, text: s.text))
        }
        out.sort { $0.start < $1.start }
        return out
    }

    static func assignSpeaker(to segment: WhisperSegment, diar: [DiarSegment]) -> String {
        var best: (id: String, overlap: Double) = ("UNKNOWN", 0)
        for d in diar {
            let ov = max(0, min(segment.end, d.end) - max(segment.start, d.start))
            if ov > best.overlap { best = (d.speakerId, ov) }
        }
        return best.id
    }
}
```

- [ ] **Step 2: Write failing tests**

```swift
import XCTest
@testable import RecorderCore

final class MergerTests: XCTestCase {
    func testMicSegmentsAreTaggedMoi() {
        let mic = [WhisperSegment(start: 0, end: 2, text: "hello")]
        let out = Merger.merge(mic: mic, system: [], diarization: [])
        XCTAssertEqual(out, [.init(start: 0, end: 2, speaker: "MOI", text: "hello")])
    }

    func testSystemSegmentGetsMaxOverlapSpeaker() {
        let sys = [WhisperSegment(start: 5, end: 8, text: "hi")]
        let diar = [
            DiarSegment(start: 4, end: 6, speakerId: "SPEAKER_00"),
            DiarSegment(start: 6, end: 9, speakerId: "SPEAKER_01"),
        ]
        let out = Merger.merge(mic: [], system: sys, diarization: diar)
        XCTAssertEqual(out.first?.speaker, "SPEAKER_01") // 2s overlap vs 1s
    }

    func testMergedTimelineIsSortedByStart() {
        let mic = [WhisperSegment(start: 3, end: 4, text: "b")]
        let sys = [WhisperSegment(start: 1, end: 2, text: "a"),
                   WhisperSegment(start: 5, end: 6, text: "c")]
        let out = Merger.merge(mic: mic, system: sys, diarization: [])
        XCTAssertEqual(out.map(\.text), ["a", "b", "c"])
    }

    func testSystemSegmentWithoutDiarizationFallsBackToUnknown() {
        let sys = [WhisperSegment(start: 0, end: 1, text: "x")]
        XCTAssertEqual(Merger.merge(mic: [], system: sys, diarization: []).first?.speaker,
                       "UNKNOWN")
    }
}
```

- [ ] **Step 3: Run (PASS)**

`swift test --filter MergerTests`

- [ ] **Step 4: Commit**

```bash
git add Sources/RecorderCore/Pipeline/Merger.swift Tests/RecorderCoreTests/MergerTests.swift
git commit -m "feat(pipeline): Merger — align mic + system + diarisation"
```

---

## Task 13: `MarkdownRenderer`

**Files:**
- Create: `Sources/RecorderCore/Pipeline/MarkdownRenderer.swift`
- Test: `Tests/RecorderCoreTests/MarkdownRendererTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
@testable import RecorderCore

final class MarkdownRendererTests: XCTestCase {
    func testRendersHeadingsAndBodies() {
        let started = Date(timeIntervalSince1970: 1_784_819_535) // 2026-07-22 12:32:15 UTC
        let segs = [
            TranscriptSegment(start: 0.0, end: 4.2, speaker: "MOI", text: "Bonjour."),
            TranscriptSegment(start: 4.5, end: 7.1, speaker: "SPEAKER_00", text: "Salut."),
        ]
        let out = MarkdownRenderer.render(segments: segs, meetingStart: started,
                                          slug: "2026-07-22_12h32",
                                          timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(out.contains("# Meeting 2026-07-22_12h32"))
        XCTAssertTrue(out.contains("## 12:32:15 — MOI"))
        XCTAssertTrue(out.contains("Bonjour."))
        XCTAssertTrue(out.contains("## 12:32:19 — SPEAKER_00"))
    }
}
```

- [ ] **Step 2: Run (FAIL)**

- [ ] **Step 3: Implement**

```swift
import Foundation

public enum MarkdownRenderer {
    public static func render(segments: [TranscriptSegment], meetingStart: Date,
                              slug: String, timeZone: TimeZone = .current) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = timeZone
        fmt.dateFormat = "HH:mm:ss"

        var out = "# Meeting \(slug)\n\n"
        for seg in segments {
            let abs = meetingStart.addingTimeInterval(seg.start)
            out += "## \(fmt.string(from: abs)) — \(seg.speaker)\n"
            out += "\(seg.text)\n\n"
        }
        return out
    }
}
```

- [ ] **Step 4: Run (PASS)**

- [ ] **Step 5: Commit**

```bash
git add Sources/RecorderCore/Pipeline/MarkdownRenderer.swift Tests/RecorderCoreTests/MarkdownRendererTests.swift
git commit -m "feat(pipeline): MarkdownRenderer — human-readable transcript"
```

---

## Task 14: `Normalizer` (ensure Whisper input format)

**Files:**
- Create: `Sources/RecorderCore/Pipeline/Normalizer.swift`

- [ ] **Step 1: Implement**

Since the recorder already writes 16 kHz mono float32, Normalizer is a copy step that verifies the format. It's still a distinct pipeline stage so it can be replaced later without touching orchestration.

```swift
import AVFoundation

public enum Normalizer {
    public static func normalize(input: URL, output: URL) throws {
        let file = try AVAudioFile(forReading: input)
        let inputFormat = file.processingFormat
        precondition(inputFormat.sampleRate == 16_000 && inputFormat.channelCount == 1,
                     "Recorder wrote unexpected format")
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.copyItem(at: input, to: output)
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
swift build
git add Sources/RecorderCore/Pipeline/Normalizer.swift
git commit -m "feat(pipeline): Normalizer — verify + copy step"
```

---

## Task 15: `ModelManifest` + `ModelDownloader`

**Files:**
- Create: `Sources/RecorderCore/Models/ModelManifest.swift`
- Create: `Sources/RecorderCore/Models/ModelDownloader.swift`

- [ ] **Step 1: Manifest**

```swift
import Foundation

public struct ModelAsset {
    public let id: String
    public let remoteURL: URL
    public let relativeInstallPath: String
    public let sha256: String?
}

public enum ModelManifest {
    // WhisperKit downloads its own model files from HuggingFace when initialised
    // with a model name string (see Task 16). We track it here for the onboarding UI only.
    public static let whisperLargeV3 = ModelAsset(
        id: "openai_whisper-large-v3",
        remoteURL: URL(string: "https://huggingface.co/argmaxinc/whisperkit-coreml")!,
        relativeInstallPath: "whisperkit/openai_whisper-large-v3",
        sha256: nil
    )

    // sherpa-onnx pyannote segmentation
    public static let sherpaSegmentation = ModelAsset(
        id: "sherpa-onnx-pyannote-segmentation-3-0",
        remoteURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2")!,
        relativeInstallPath: "sherpa/segmentation",
        sha256: nil
    )

    public static let sherpaEmbedding = ModelAsset(
        id: "3dspeaker_speaker-embedding_eres2net_base_sv_zh-cn_3dspeaker_16k",
        remoteURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speaker-embedding_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx")!,
        relativeInstallPath: "sherpa/embedding.onnx",
        sha256: nil
    )

    public static let installRoot: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Onyx/models", isDirectory: true)
    }()

    public static func installedPath(for asset: ModelAsset) -> URL {
        installRoot.appendingPathComponent(asset.relativeInstallPath)
    }
}
```

- [ ] **Step 2: Downloader**

```swift
import Foundation

public final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    public struct Progress {
        public let asset: ModelAsset
        public let bytesReceived: Int64
        public let bytesExpected: Int64
    }

    public typealias ProgressHandler = (Progress) -> Void

    private var handler: ProgressHandler?
    private var pending: [(ModelAsset, CheckedContinuation<URL, Error>)] = []
    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    public func download(_ asset: ModelAsset, progress: @escaping ProgressHandler) async throws -> URL {
        let dest = ModelManifest.installedPath(for: asset)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        return try await withCheckedThrowingContinuation { cont in
            handler = progress
            let task = session.downloadTask(with: asset.remoteURL)
            pending.append((asset, cont))
            task.taskDescription = asset.id
            task.resume()
        }
    }

    public func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                           totalBytesExpectedToWrite total: Int64) {
        guard let id = downloadTask.taskDescription,
              let (asset, _) = pending.first(where: { $0.0.id == id }) else { return }
        handler?(.init(asset: asset, bytesReceived: totalBytesWritten, bytesExpected: total))
    }

    public func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription,
              let idx = pending.firstIndex(where: { $0.0.id == id }) else { return }
        let (asset, cont) = pending.remove(at: idx)
        let dest = ModelManifest.installedPath(for: asset)
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            cont.resume(returning: dest)
        } catch { cont.resume(throwing: error) }
    }

    public func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription,
              let idx = pending.firstIndex(where: { $0.0.id == id }) else { return }
        let (_, cont) = pending.remove(at: idx)
        cont.resume(throwing: error)
    }
}
```

- [ ] **Step 3: Build + commit**

```bash
swift build
git add Sources/RecorderCore/Models
git commit -m "feat(models): ModelManifest + ModelDownloader (URLSession + progress)"
```

Note: for the sherpa segmentation asset (`.tar.bz2`) the on-disk layout after unpack is a directory. Task 17 (Diarizer) does the unpack step at first use.

---

## Task 16: `WhisperTranscriber` wrapper

**Files:**
- Create: `Sources/RecorderCore/Transcription/WhisperTranscriber.swift`

- [ ] **Step 1: Implement**

```swift
import Foundation
import WhisperKit

public actor WhisperTranscriber {
    private var kit: WhisperKit?
    private let modelName = "openai_whisper-large-v3"
    private let language: String

    public init(language: String = "fr") { self.language = language }

    private func ensureLoaded() async throws -> WhisperKit {
        if let kit { return kit }
        let modelFolder = ModelManifest.installedPath(for: ModelManifest.whisperLargeV3)
        let cfg = WhisperKitConfig(
            model: modelName,
            modelFolder: modelFolder.path,
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: true,
            download: true
        )
        let k = try await WhisperKit(config: cfg)
        kit = k
        return k
    }

    public func transcribe(wavPath: URL, to jsonPath: URL) async throws {
        let kit = try await ensureLoaded()
        let opts = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0.0,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: 5,
            wordTimestamps: false,
            withoutTimestamps: false
        )
        let results = try await kit.transcribe(audioPath: wavPath.path, decodeOptions: opts)
        var segments: [WhisperSegment] = []
        for r in results {
            for s in r.segments {
                segments.append(.init(start: Double(s.start), end: Double(s.end),
                                      text: s.text.trimmingCharacters(in: .whitespaces),
                                      confidence: s.avgLogprob.map(Double.init)))
            }
        }
        try AtomicJSON.write(segments, to: jsonPath)
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
swift build
git add Sources/RecorderCore/Transcription/WhisperTranscriber.swift
git commit -m "feat(transcription): WhisperTranscriber — WhisperKit wrapper"
```

---

## Task 17: `Diarizer` (sherpa-onnx)

**Files:**
- Create: `Sources/RecorderCore/Diarization/Diarizer.swift`
- Modify: `Package.swift` (add sherpa-onnx dep)

- [ ] **Step 1: Add sherpa-onnx to `Package.swift`**

Insert into `dependencies`:
```swift
.package(url: "https://github.com/k2-fsa/sherpa-onnx.git", branch: "master"),
```

And add `.product(name: "SherpaOnnx", package: "sherpa-onnx")` to the `RecorderCore` target dependencies.

Attempt `swift package resolve`. If the SwiftPM package fails to build (sherpa-onnx historically ships an XCFramework rather than a pure SwiftPM product), abort the SwiftPM approach and instead:
1. Download the prebuilt `sherpa-onnx.xcframework` from https://github.com/k2-fsa/sherpa-onnx/releases into `Vendor/SherpaOnnx.xcframework/`.
2. Add a `binaryTarget(name: "SherpaOnnx", path: "Vendor/SherpaOnnx.xcframework")` to `Package.swift` and depend on it.
3. Commit the .gitignore rule to exclude `Vendor/*.xcframework` from git, download it via a `scripts/fetch-sherpa.sh` helper.

Which route worked is a per-machine decision — record it in the commit message.

- [ ] **Step 2: Implement `Diarizer`**

```swift
import Foundation
// import SherpaOnnx  // enable once integration is settled in Step 1

public struct DiarizationResult {
    public let segments: [DiarSegment]
}

public final class Diarizer {
    private let segmentationModelPath: URL
    private let embeddingModelPath: URL

    public init(segmentation: URL = ModelManifest.installedPath(for: ModelManifest.sherpaSegmentation),
                embedding: URL = ModelManifest.installedPath(for: ModelManifest.sherpaEmbedding)) {
        self.segmentationModelPath = segmentation
        self.embeddingModelPath = embedding
    }

    /// Reads a 16k mono float32 WAV and writes `diarization.json` = [DiarSegment].
    /// See sherpa-onnx offline speaker diarization examples for the exact C API call sequence
    /// (SherpaOnnxOfflineSpeakerDiarization + segmentation/embedding configs).
    public func diarize(wavPath: URL, to jsonPath: URL) throws {
        let segments = try runSherpa(on: wavPath)
        try AtomicJSON.write(segments, to: jsonPath)
    }

    private func runSherpa(on wavPath: URL) throws -> [DiarSegment] {
        // Implementation detail depends on which sherpa-onnx Swift surface ends up integrated.
        // The Swift binding exposes an OfflineSpeakerDiarization type that returns an array of
        // {start, end, speaker: Int32} tuples; map them to DiarSegment("SPEAKER_%02d", speaker).
        // See: https://k2-fsa.github.io/sherpa/onnx/speaker-diarization/index.html
        fatalError("Wire sherpa-onnx OfflineSpeakerDiarization here after Step 1 integration path is resolved.")
    }
}
```

- [ ] **Step 3: Wire the sherpa call**

Replace the `fatalError` body with the actual sherpa call following the pattern from the sherpa-onnx repo's `swift-api-examples/offline-speaker-diarization.swift`. Map results:
```
SherpaSpeakerSegment(start, end, speaker: Int32) → DiarSegment(start, end, "SPEAKER_\(String(format: "%02d", speaker))")
```

- [ ] **Step 4: Build + commit**

```bash
swift build
git add Sources/RecorderCore/Diarization/Diarizer.swift Package.swift
git commit -m "feat(diarization): Diarizer — sherpa-onnx offline diarisation"
```

---

## Task 18: `Cleanup` (WAV → M4A + delete intermediates)

**Files:**
- Create: `Sources/RecorderCore/Pipeline/Cleanup.swift`

- [ ] **Step 1: Implement**

```swift
import Foundation

public enum Cleanup {
    public static func run(paths: MeetingPaths) async throws {
        try await Mp4Converter.convert(wav: paths.micWav, to: paths.micM4a)
        try await Mp4Converter.convert(wav: paths.systemWav, to: paths.systemM4a)
        for f in [paths.micWav, paths.systemWav,
                  paths.micNormalized, paths.systemNormalized] {
            try? FileManager.default.removeItem(at: f)
        }
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
swift build
git add Sources/RecorderCore/Pipeline/Cleanup.swift
git commit -m "feat(pipeline): Cleanup — wav→m4a + delete intermediates"
```

---

## Task 19: `Pipeline` orchestrator (idempotent, resumable)

**Files:**
- Create: `Sources/RecorderCore/Pipeline/Pipeline.swift`
- Test: `Tests/RecorderCoreTests/PipelineTests.swift`

- [ ] **Step 1: Implement orchestrator**

```swift
import Foundation

public actor Pipeline {
    private let storage: MeetingStorage
    private let whisper: WhisperTranscriber
    private let diarizer: Diarizer

    public init(storage: MeetingStorage,
                whisper: WhisperTranscriber = .init(),
                diarizer: Diarizer = .init()) {
        self.storage = storage; self.whisper = whisper; self.diarizer = diarizer
    }

    public func run(paths: MeetingPaths) async throws {
        try await runStep(.normalize, paths: paths, overall: .normalizing) {
            try Normalizer.normalize(input: paths.micWav, output: paths.micNormalized)
            try Normalizer.normalize(input: paths.systemWav, output: paths.systemNormalized)
        }
        try await runStep(.whisperMic, paths: paths, overall: .transcribing) {
            try await self.whisper.transcribe(wavPath: paths.micNormalized, to: paths.whisperMic)
        }
        try await runStep(.whisperSystem, paths: paths, overall: .transcribing) {
            try await self.whisper.transcribe(wavPath: paths.systemNormalized, to: paths.whisperSystem)
        }
        try await runStep(.diarize, paths: paths, overall: .diarizing) {
            try self.diarizer.diarize(wavPath: paths.systemNormalized, to: paths.diarization)
        }
        try await runStep(.merge, paths: paths, overall: .merging) {
            let mic  = try AtomicJSON.read([WhisperSegment].self, from: paths.whisperMic)
            let sys  = try AtomicJSON.read([WhisperSegment].self, from: paths.whisperSystem)
            let diar = try AtomicJSON.read([DiarSegment].self,   from: paths.diarization)
            let merged = Merger.merge(mic: mic, system: sys, diarization: diar)
            try AtomicJSON.write(merged, to: paths.transcriptJson)
        }
        try await runStep(.render, paths: paths, overall: .rendering) {
            let segs = try AtomicJSON.read([TranscriptSegment].self, from: paths.transcriptJson)
            let meta = try self.storage.loadMetadata(paths)
            let md = MarkdownRenderer.render(segments: segs, meetingStart: meta.startedAt,
                                             slug: paths.slug)
            try md.data(using: .utf8)!.write(to: paths.transcriptMd, options: .atomic)
        }
        try await runStep(.cleanup, paths: paths, overall: .cleanup) {
            try await Cleanup.run(paths: paths)
        }
        var job = try storage.loadJob(paths)
        job.state = .done
        try storage.saveJob(job, at: paths)
        Log.pipeline.info("Pipeline done for \(paths.slug)")
    }

    private func runStep(_ step: JobStep, paths: MeetingPaths,
                         overall: JobOverallState,
                         body: @Sendable () async throws -> Void) async throws {
        var job = try storage.loadJob(paths)
        if job.stepStatus(step) == .done {
            Log.pipeline.info("Skip \(step.rawValue) — already done for \(paths.slug)")
            return
        }
        job.state = overall
        job.markStarted(step)
        try storage.saveJob(job, at: paths)
        do {
            try await body()
            var updated = try storage.loadJob(paths)
            updated.markDone(step)
            try storage.saveJob(updated, at: paths)
        } catch {
            var updated = try storage.loadJob(paths)
            updated.markFailed(step, error: String(describing: error))
            try storage.saveJob(updated, at: paths)
            throw error
        }
    }
}
```

- [ ] **Step 2: Write pipeline test (uses stubs for whisper + diarizer)**

Add a protocol for testability. Edit `WhisperTranscriber` and `Diarizer` to conform to lightweight protocols so the test can inject fakes:

- Add to `Sources/RecorderCore/Pipeline/Pipeline.swift`:
```swift
public protocol WhisperTranscribing: Sendable {
    func transcribe(wavPath: URL, to jsonPath: URL) async throws
}
public protocol Diarizing: Sendable {
    func diarize(wavPath: URL, to jsonPath: URL) throws
}
```
- Make `WhisperTranscriber` conform (`extension WhisperTranscriber: WhisperTranscribing {}`) and `Diarizer` conform (`extension Diarizer: Diarizing {}`).
- Change `Pipeline.init` to accept `whisper: any WhisperTranscribing`, `diarizer: any Diarizing`.

Test:
```swift
import XCTest
@testable import RecorderCore

final class PipelineTests: XCTestCase {
    struct FakeWhisper: WhisperTranscribing {
        let output: [WhisperSegment]
        func transcribe(wavPath: URL, to jsonPath: URL) async throws {
            try AtomicJSON.write(output, to: jsonPath)
        }
    }
    struct FakeDiar: Diarizing {
        let output: [DiarSegment]
        func diarize(wavPath: URL, to jsonPath: URL) throws {
            try AtomicJSON.write(output, to: jsonPath)
        }
    }

    func testFullPipelineRunsAllStepsAndProducesMd() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("onyx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = MeetingStorage(root: root)
        let started = Date(timeIntervalSince1970: 1_784_819_535)
        let paths = try storage.createMeeting(startedAt: started)

        // fake WAVs — content is irrelevant since Whisper/Diarizer are faked
        try Data([0]).write(to: paths.micWav)
        try Data([0]).write(to: paths.systemWav)

        let whisper = FakeWhisper(output: [
            .init(start: 0, end: 1, text: "moi parle")
        ])
        let diar = FakeDiar(output: [
            .init(start: 0, end: 1, speakerId: "SPEAKER_00"),
        ])
        // System whisper stub reuses same fake but we'll swap output via a second instance
        struct DualWhisper: WhisperTranscribing {
            let mic: [WhisperSegment]; let sys: [WhisperSegment]
            func transcribe(wavPath: URL, to jsonPath: URL) async throws {
                let payload = wavPath.lastPathComponent.contains("mic") ? mic : sys
                try AtomicJSON.write(payload, to: jsonPath)
            }
        }
        let dual = DualWhisper(
            mic: [.init(start: 0, end: 1, text: "moi parle")],
            sys: [.init(start: 1, end: 2, text: "alice repond")]
        )

        let pipeline = Pipeline(storage: storage, whisper: dual, diarizer: diar)
        try await pipeline.run(paths: paths)

        let job = try storage.loadJob(paths)
        XCTAssertEqual(job.state, .done)
        let merged = try AtomicJSON.read([TranscriptSegment].self, from: paths.transcriptJson)
        XCTAssertEqual(merged.map(\.speaker), ["MOI", "SPEAKER_00"])
        let md = try String(contentsOf: paths.transcriptMd, encoding: .utf8)
        XCTAssertTrue(md.contains("MOI"))
        XCTAssertTrue(md.contains("SPEAKER_00"))
    }

    func testSecondRunSkipsCompletedSteps() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("onyx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = MeetingStorage(root: root)
        let paths = try storage.createMeeting(startedAt: Date())
        try Data([0]).write(to: paths.micWav); try Data([0]).write(to: paths.systemWav)

        actor CallCounter { var n = 0; func bump() { n += 1 } }
        let counter = CallCounter()

        struct CountingWhisper: WhisperTranscribing {
            let counter: CallCounter
            func transcribe(wavPath: URL, to jsonPath: URL) async throws {
                await counter.bump()
                try AtomicJSON.write([WhisperSegment](), to: jsonPath)
            }
        }
        let whisper = CountingWhisper(counter: counter)
        struct EmptyDiar: Diarizing {
            func diarize(wavPath: URL, to jsonPath: URL) throws {
                try AtomicJSON.write([DiarSegment](), to: jsonPath)
            }
        }
        let pipeline = Pipeline(storage: storage, whisper: whisper, diarizer: EmptyDiar())
        try await pipeline.run(paths: paths)
        let firstCount = await counter.n
        try await pipeline.run(paths: paths) // resume — everything already done
        let secondCount = await counter.n
        XCTAssertEqual(firstCount, secondCount) // whisper NOT re-invoked
    }
}
```

- [ ] **Step 3: Run**

`swift test --filter PipelineTests`

- [ ] **Step 4: Commit**

```bash
git add Sources/RecorderCore/Pipeline/Pipeline.swift Sources/RecorderCore/Transcription Sources/RecorderCore/Diarization Tests/RecorderCoreTests/PipelineTests.swift
git commit -m "feat(pipeline): orchestrator + resume logic + integration test"
```

---

## Task 20: SQLite index schema

**Files:**
- Create: `Sources/RecorderCore/Index/IndexSchema.swift`

- [ ] **Step 1: Implement**

```swift
import Foundation
import GRDB

public enum IndexSchema {
    public static let currentVersion = 1

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
        return m
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
swift build
git add Sources/RecorderCore/Index/IndexSchema.swift
git commit -m "feat(index): SQLite schema + migrator"
```

---

## Task 21: `MeetingIndexer`

**Files:**
- Create: `Sources/RecorderCore/Index/MeetingIndexer.swift`
- Test: `Tests/RecorderCoreTests/MeetingIndexerTests.swift`

- [ ] **Step 1: Failing test**

```swift
import XCTest
import GRDB
@testable import RecorderCore

final class MeetingIndexerTests: XCTestCase {
    func testUpsertMeetingWritesRow() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("idx-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let indexer = try MeetingIndexer(dbPath: tmp)
        let started = Date(timeIntervalSince1970: 1_784_819_535)
        let meta = MeetingMetadata(id: "2026-07-22_14h32", startedAt: started,
                                   endedAt: nil, durationSeconds: 60, title: nil,
                                   source: .manual, appVersion: "0.1.0",
                                   models: .init(whisper: "large-v3", diarization: "sh-3.0"))
        try indexer.upsert(meta: meta, folderPath: URL(fileURLWithPath: "/tmp/x/2026-07-22_14h32"),
                           transcriptState: "done", transcript: [
            .init(start: 0, end: 1, speaker: "MOI", text: "bonjour"),
            .init(start: 1, end: 2, speaker: "SPEAKER_00", text: "salut"),
        ])
        let count = try indexer.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meetings") ?? 0
        }
        XCTAssertEqual(count, 1)
        let ftsCount = try indexer.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcripts_fts WHERE meeting_id = ?",
                             arguments: ["2026-07-22_14h32"]) ?? 0
        }
        XCTAssertEqual(ftsCount, 2)
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation
import GRDB

public final class MeetingIndexer {
    public let writer: DatabaseWriter
    public var reader: DatabaseReader { writer }

    public init(dbPath: URL) throws {
        try FileManager.default.createDirectory(at: dbPath.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        writer = try DatabasePool(path: dbPath.path)
        try IndexSchema.migrator().migrate(writer)
    }

    public func upsert(meta: MeetingMetadata, folderPath: URL,
                       transcriptState: String,
                       transcript: [TranscriptSegment]) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO meetings (id, path, started_at, duration_seconds, title,
                                       transcript_state, indexed_at)
                VALUES (?, ?, ?, ?, ?, ?, datetime('now'))
                ON CONFLICT(id) DO UPDATE SET
                    path=excluded.path,
                    started_at=excluded.started_at,
                    duration_seconds=excluded.duration_seconds,
                    title=excluded.title,
                    transcript_state=excluded.transcript_state,
                    indexed_at=excluded.indexed_at
                """,
                arguments: [meta.id, folderPath.path,
                            ISO8601DateFormatter().string(from: meta.startedAt),
                            meta.durationSeconds, meta.title,
                            transcriptState])
            try db.execute(sql: "DELETE FROM transcripts_fts WHERE meeting_id = ?",
                           arguments: [meta.id])
            for seg in transcript {
                try db.execute(sql: """
                    INSERT INTO transcripts_fts (meeting_id, speaker, text) VALUES (?, ?, ?)
                    """, arguments: [meta.id, seg.speaker, seg.text])
            }
        }
    }
}
```

- [ ] **Step 3: Run tests (PASS)**

`swift test --filter MeetingIndexerTests`

- [ ] **Step 4: Commit**

```bash
git add Sources/RecorderCore/Index/MeetingIndexer.swift Tests/RecorderCoreTests/MeetingIndexerTests.swift
git commit -m "feat(index): MeetingIndexer — upsert + FTS population"
```

---

## Task 22: `RescanRunner`

**Files:**
- Create: `Sources/RecorderCore/Index/RescanRunner.swift`
- Test: `Tests/RecorderCoreTests/RescanRunnerTests.swift`

- [ ] **Step 1: Failing test**

```swift
import XCTest
@testable import RecorderCore

final class RescanRunnerTests: XCTestCase {
    func testRescanRebuildsFromFolder() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rescan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("idx.sqlite")

        let storage = MeetingStorage(root: root.appendingPathComponent("Meetings"))
        let paths = try storage.createMeeting(startedAt: Date(timeIntervalSince1970: 1_784_819_535))
        try AtomicJSON.write([TranscriptSegment(start: 0, end: 1, speaker: "MOI", text: "hey")],
                             to: paths.transcriptJson)
        var job = try storage.loadJob(paths); job.state = .done
        try storage.saveJob(job, at: paths)

        let indexer = try MeetingIndexer(dbPath: dbPath)
        let runner = RescanRunner(storage: storage, indexer: indexer)
        try await runner.rescan()

        let count = try indexer.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meetings") ?? 0
        }
        XCTAssertEqual(count, 1)
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

public struct RescanRunner {
    public let storage: MeetingStorage
    public let indexer: MeetingIndexer

    public func rescan() async throws {
        for listing in try storage.listMeetings() {
            let paths = MeetingPaths(root: storage.root, slug: listing.slug)
            guard let meta = try? storage.loadMetadata(paths),
                  let job  = try? storage.loadJob(paths) else { continue }
            let state = job.state == .done ? "done"
                       : job.state == .failed ? "failed" : "in_progress"
            let segments: [TranscriptSegment]
            if FileManager.default.fileExists(atPath: paths.transcriptJson.path) {
                segments = (try? AtomicJSON.read([TranscriptSegment].self,
                                                 from: paths.transcriptJson)) ?? []
            } else { segments = [] }
            try indexer.upsert(meta: meta, folderPath: paths.root,
                               transcriptState: state, transcript: segments)
        }
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
swift test --filter RescanRunnerTests
git add Sources/RecorderCore/Index/RescanRunner.swift Tests/RecorderCoreTests/RescanRunnerTests.swift
git commit -m "feat(index): RescanRunner — rebuild index from disk"
```

---

## Task 23: `SettingsStore` + `AppState`

**Files:**
- Create: `Sources/Onyx/Settings/SettingsStore.swift`
- Create: `Sources/Onyx/AppState.swift`

- [ ] **Step 1: Implement `SettingsStore`**

```swift
import Foundation

public final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published public var language: String {
        didSet { defaults.set(language, forKey: "language") }
    }
    @Published public var meetingsFolder: URL {
        didSet { defaults.set(meetingsFolder.path, forKey: "meetingsFolder") }
    }
    @Published public var autoUpdateEnabled: Bool {
        didSet { defaults.set(autoUpdateEnabled, forKey: "autoUpdate") }
    }

    public init() {
        language = defaults.string(forKey: "language") ?? "fr"
        let defaultFolder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Meetings")
        if let s = defaults.string(forKey: "meetingsFolder") {
            meetingsFolder = URL(fileURLWithPath: s)
        } else { meetingsFolder = defaultFolder }
        autoUpdateEnabled = defaults.object(forKey: "autoUpdate") as? Bool ?? true
    }
}
```

- [ ] **Step 2: Implement `AppState`**

```swift
import Foundation
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
    private let recorder: Recorder
    private let pipeline: Pipeline

    public init() {
        storage = MeetingStorage(root: settings.meetingsFolder)
        let dbURL = FileManager.default.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask)[0]
            .appendingPathComponent("Onyx/index.sqlite")
        indexer = try! MeetingIndexer(dbPath: dbURL)
        recorder = Recorder(storage: storage)
        pipeline = Pipeline(storage: storage)
    }

    public func toggleRecording() {
        Task {
            do {
                switch uiState {
                case .idle:
                    let paths = try await recorder.start()
                    currentSlug = paths.slug
                    uiState = .recording
                case .recording:
                    let paths = try await recorder.stop()
                    uiState = .transcribing
                    try await pipeline.run(paths: paths)
                    let meta = try storage.loadMetadata(paths)
                    let segs = (try? AtomicJSON.read([TranscriptSegment].self,
                                                     from: paths.transcriptJson)) ?? []
                    try indexer.upsert(meta: meta, folderPath: paths.root,
                                       transcriptState: "done", transcript: segs)
                    currentSlug = nil
                    uiState = .idle
                case .transcribing:
                    // start a new recording concurrently — allowed
                    let paths = try await recorder.start()
                    currentSlug = paths.slug
                    uiState = .recording
                }
            } catch {
                lastError = String(describing: error)
                uiState = .idle
            }
        }
    }

    public func resumePendingJobs() {
        Task.detached {
            for listing in (try? await self.storage.listMeetings()) ?? [] {
                let paths = MeetingPaths(root: self.storage.root, slug: listing.slug)
                guard let job = try? self.storage.loadJob(paths), job.isResumable else { continue }
                try? await self.pipeline.run(paths: paths)
            }
        }
    }
}
```

- [ ] **Step 3: Build + commit**

```bash
swift build
git add Sources/Onyx
git commit -m "feat(app): SettingsStore + AppState wiring"
```

---

## Task 24: MenuBarExtra UI

**Files:**
- Create: `Sources/Onyx/Menu/MenuBarView.swift`
- Create: `Sources/Onyx/Menu/MenuBarIcon.swift`
- Modify: `Sources/Onyx/App.swift`

- [ ] **Step 1: `MenuBarIcon.swift`**

```swift
import SwiftUI

struct MenuBarIcon: View {
    let state: AppState.UIState
    var body: some View {
        switch state {
        case .idle:         Image(systemName: "mic")
        case .recording:    Image(systemName: "record.circle").foregroundColor(.red)
        case .transcribing: Image(systemName: "hourglass").foregroundColor(.yellow)
        }
    }
}
```

- [ ] **Step 2: `MenuBarView.swift`**

```swift
import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var app: AppState

    var body: some View {
        Group {
            switch app.uiState {
            case .idle:
                Button("Start recording  ⌘⇧R") { app.toggleRecording() }
            case .recording:
                Text("Recording \(app.currentSlug ?? "")")
                Button("Stop recording  ⌘⇧R") { app.toggleRecording() }
            case .transcribing:
                Text("Transcribing…")
                Button("Start new recording  ⌘⇧R") { app.toggleRecording() }
            }
            Divider()
            Button("Open meetings folder") {
                NSWorkspace.shared.open(app.settings.meetingsFolder)
            }
            Button("Settings…") { openSettingsWindow() }
            Button("Rescan meetings") {
                Task { try? await RescanRunner(storage: app.storage,
                                               indexer: app.indexer).rescan() }
            }
            Divider()
            Button("Quit Onyx") { NSApplication.shared.terminate(nil) }
        }
    }
}

@MainActor func openSettingsWindow() {
    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
}
```

- [ ] **Step 3: Update `App.swift`**

```swift
import SwiftUI

@main
struct OnyxApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(app: appState)
                .onAppear { appState.resumePendingJobs() }
        } label: {
            MenuBarIcon(state: appState.uiState)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsWindow(settings: appState.settings, storage: appState.storage,
                           indexer: appState.indexer)
        }
    }
}
```

- [ ] **Step 4: Build + commit**

```bash
swift build
git add Sources/Onyx
git commit -m "feat(ui): MenuBarExtra + icon states"
```

---

## Task 25: Global hotkey ⌘⇧R

**Files:**
- Create: `Sources/Onyx/Hotkey/GlobalHotkey.swift`
- Modify: `Sources/Onyx/App.swift`

- [ ] **Step 1: Implement `GlobalHotkey`**

```swift
import Carbon.HIToolbox
import AppKit

public final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var handler: () -> Void = {}
    private static var instance: GlobalHotkey?

    public init() { GlobalHotkey.instance = self }

    public func register(keyCode: UInt32 = UInt32(kVK_ANSI_R),
                         modifiers: UInt32 = UInt32(cmdKey | shiftKey),
                         onTrigger: @escaping () -> Void) {
        handler = onTrigger
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            GlobalHotkey.instance?.handler()
            return noErr
        }, 1, &eventType, nil, nil)
        var id = EventHotKeyID(signature: OSType(0x4F4E5958), id: 1) // "ONYX"
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(),
                            0, &hotKeyRef)
    }

    deinit { if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) } }
}
```

- [ ] **Step 2: Wire into App**

In `App.swift`, add a `.onAppear` on the `MenuBarExtra` content:
```swift
.onAppear {
    appState.resumePendingJobs()
    hotkey.register { Task { @MainActor in appState.toggleRecording() } }
}
```
And declare `@State private var hotkey = GlobalHotkey()` on `OnyxApp`.

- [ ] **Step 3: Build + commit**

```bash
swift build
git add Sources/Onyx
git commit -m "feat(hotkey): global ⌘⇧R toggles recording"
```

---

## Task 26: Onboarding — permissions + model download

**Files:**
- Create: `Sources/Onyx/Onboarding/PermissionsChecker.swift`
- Create: `Sources/Onyx/Onboarding/OnboardingWindow.swift`
- Create: `Sources/Onyx/Onboarding/ModelDownloadView.swift`
- Modify: `Sources/Onyx/App.swift`

- [ ] **Step 1: `PermissionsChecker`**

```swift
import AVFoundation
import ScreenCaptureKit
import CoreGraphics

public enum PermissionsChecker {
    public static func micGranted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { c in
                AVCaptureDevice.requestAccess(for: .audio) { ok in c.resume(returning: ok) }
            }
        default: return false
        }
    }

    public static func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    public static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }
}
```

- [ ] **Step 2: `ModelDownloadView`**

```swift
import SwiftUI
import RecorderCore

struct ModelDownloadView: View {
    @State private var status: String = "Preparing…"
    @State private var progress: Double = 0
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(status).font(.headline)
            ProgressView(value: progress).frame(width: 320)
        }
        .padding(40)
        .task { await run() }
    }

    private func run() async {
        let downloader = ModelDownloader()
        let assets: [ModelAsset] = [
            ModelManifest.whisperLargeV3,
            ModelManifest.sherpaSegmentation,
            ModelManifest.sherpaEmbedding,
        ]
        for (i, a) in assets.enumerated() {
            status = "Downloading \(a.id) (\(i+1)/\(assets.count))…"
            do {
                _ = try await downloader.download(a) { p in
                    if p.bytesExpected > 0 {
                        Task { @MainActor in progress = Double(p.bytesReceived) / Double(p.bytesExpected) }
                    }
                }
            } catch { status = "Failed \(a.id): \(error.localizedDescription)"; return }
        }
        onDone()
    }
}
```

- [ ] **Step 3: `OnboardingWindow`**

```swift
import SwiftUI
import AppKit

public struct OnboardingWindow: View {
    enum Step { case welcome, mic, screen, models, done }
    @State private var step: Step = .welcome
    let onCompleted: () -> Void

    public init(onCompleted: @escaping () -> Void) { self.onCompleted = onCompleted }

    public var body: some View {
        VStack(spacing: 24) {
            switch step {
            case .welcome:
                Text("Welcome to Onyx").font(.largeTitle)
                Text("Offline meeting recorder + transcript").foregroundColor(.secondary)
                Button("Continue") { step = .mic }
            case .mic:
                Text("Microphone access").font(.title)
                Button("Grant microphone") {
                    Task {
                        _ = await PermissionsChecker.micGranted()
                        step = .screen
                    }
                }
            case .screen:
                Text("Screen recording").font(.title)
                Text("Required to capture system audio (Zoom, Meet, Huddle…)")
                    .foregroundColor(.secondary).multilineTextAlignment(.center)
                Button("Grant screen recording") {
                    PermissionsChecker.requestScreenRecording()
                    step = .models
                }
            case .models:
                ModelDownloadView { step = .done }
            case .done:
                Text("You're ready").font(.title)
                Button("Start using Onyx") {
                    UserDefaults.standard.set(true, forKey: "onboardingDone")
                    onCompleted()
                    NSApplication.shared.keyWindow?.close()
                }
            }
        }
        .padding(40).frame(width: 480, height: 320)
    }
}
```

- [ ] **Step 4: Show onboarding on first launch**

In `App.swift`, on `OnyxApp` init: check `UserDefaults.standard.bool(forKey: "onboardingDone")`. If false, open a `NSWindow` hosting `OnboardingWindow` before creating the menu bar.

```swift
init() {
    if !UserDefaults.standard.bool(forKey: "onboardingDone") {
        DispatchQueue.main.async { Self.showOnboarding() }
    }
}

private static func showOnboarding() {
    let win = NSWindow(contentRect: .init(x: 0, y: 0, width: 480, height: 320),
                       styleMask: [.titled, .closable],
                       backing: .buffered, defer: false)
    win.center(); win.title = "Onyx — Setup"
    win.contentView = NSHostingView(rootView: OnboardingWindow { win.close() })
    win.makeKeyAndOrderFront(nil)
}
```

- [ ] **Step 5: Build + commit**

```bash
swift build
git add Sources/Onyx/Onboarding Sources/Onyx/App.swift
git commit -m "feat(onboarding): permissions + models download flow"
```

---

## Task 27: Settings window

**Files:**
- Create: `Sources/Onyx/Settings/SettingsWindow.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI
import RecorderCore

struct SettingsWindow: View {
    @ObservedObject var settings: SettingsStore
    let storage: MeetingStorage
    let indexer: MeetingIndexer

    var body: some View {
        Form {
            Section("Language") {
                Picker("Transcription language", selection: $settings.language) {
                    Text("Français").tag("fr")
                    Text("English").tag("en")
                    Text("Auto").tag("auto")
                }
            }
            Section("Storage") {
                LabeledContent("Meetings folder", value: settings.meetingsFolder.path)
                Button("Choose folder…") { pickFolder() }
                Button("Rescan meetings folder") {
                    Task { try? await RescanRunner(storage: storage, indexer: indexer).rescan() }
                }
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $settings.autoUpdateEnabled)
            }
        }
        .padding(24).frame(width: 480)
    }

    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false; p.canChooseDirectories = true
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let url = p.url { settings.meetingsFolder = url }
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
swift build
git add Sources/Onyx/Settings
git commit -m "feat(settings): SettingsWindow — language, folder, updates"
```

---

## Task 28: Sparkle integration

**Files:**
- Create: `Sources/Onyx/Update/UpdaterController.swift`
- Modify: `Sources/Onyx/App.swift`
- Modify: `Resources/Info.plist` (created in Task 29)

- [ ] **Step 1: Implement `UpdaterController`**

```swift
import Foundation
import Sparkle

public final class UpdaterController: ObservableObject {
    public let controller: SPUStandardUpdaterController
    public init(startAutomatically: Bool) {
        controller = SPUStandardUpdaterController(startingUpdater: startAutomatically,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    }
    public func checkNow() { controller.checkForUpdates(nil) }
}
```

- [ ] **Step 2: Wire in `App`**

Add `@StateObject private var updater = UpdaterController(startAutomatically: true)` in `OnyxApp`. Sparkle pulls the appcast URL from the bundle's `Info.plist` (`SUFeedURL`) — that's set in Task 29.

- [ ] **Step 3: Build + commit**

```bash
swift build
git add Sources/Onyx/Update Sources/Onyx/App.swift
git commit -m "feat(update): Sparkle updater controller"
```

---

## Task 29: `.app` bundle template + `build-app.sh`

**Files:**
- Create: `Resources/Info.plist`
- Create: `Resources/Onyx.entitlements`
- Create: `scripts/setup-cert.sh`
- Create: `scripts/build-app.sh`

- [ ] **Step 1: `Resources/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>            <string>com.yvanbetremieux.onyx</string>
  <key>CFBundleName</key>                  <string>Onyx</string>
  <key>CFBundleDisplayName</key>           <string>Onyx</string>
  <key>CFBundleExecutable</key>            <string>Onyx</string>
  <key>CFBundlePackageType</key>           <string>APPL</string>
  <key>CFBundleShortVersionString</key>    <string>0.1.0</string>
  <key>CFBundleVersion</key>               <string>1</string>
  <key>LSMinimumSystemVersion</key>        <string>13.0</string>
  <key>LSUIElement</key>                   <true/>
  <key>NSMicrophoneUsageDescription</key>
    <string>Onyx records your microphone during meetings you start manually.</string>
  <key>NSScreenCaptureDescription</key>
    <string>Onyx captures system audio so meeting participants are transcribed.</string>
  <key>SUFeedURL</key>
    <string>https://example.invalid/appcast.xml</string>
  <key>SUEnableInstallerLauncherService</key><false/>
</dict>
</plist>
```

Replace `SUFeedURL` before the first real release. Placeholder host is intentionally invalid so a misconfigured build fails loudly rather than pointing at production.

- [ ] **Step 2: `Resources/Onyx.entitlements`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key>       <true/>
  <key>com.apple.security.device.microphone</key>        <true/>
</dict>
</plist>
```

- [ ] **Step 3: `scripts/setup-cert.sh`** (one-time bootstrap)

```bash
#!/usr/bin/env bash
set -euo pipefail
NAME="Onyx Local"
if security find-identity -v -p codesigning login.keychain-db | grep -q "$NAME"; then
  echo "Cert '$NAME' already exists in login keychain."
  exit 0
fi
cat > /tmp/onyx-cert.conf <<EOF
[req]
distinguished_name = req_dn
prompt = no
[req_dn]
CN = $NAME
EOF
openssl req -new -x509 -days 3650 -nodes \
    -config /tmp/onyx-cert.conf \
    -keyout /tmp/onyx.key -out /tmp/onyx.crt
openssl pkcs12 -export -out /tmp/onyx.p12 \
    -inkey /tmp/onyx.key -in /tmp/onyx.crt -passout pass:onyx
security import /tmp/onyx.p12 -k login.keychain-db -P onyx -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" login.keychain-db
rm -f /tmp/onyx.key /tmp/onyx.crt /tmp/onyx.p12 /tmp/onyx-cert.conf
echo "Cert '$NAME' installed. BACK IT UP: export to .p12 via Keychain Access."
```

Make executable: `chmod +x scripts/setup-cert.sh`. Add note to spec/README: **exporter le .p12 hors machine tout de suite**, sinon perdre le keychain force la redemande de permissions à tous les users.

- [ ] **Step 4: `scripts/build-app.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
CONF="release"
APP_NAME="Onyx"
BUNDLE_ID="com.yvanbetremieux.onyx"
CERT_NAME="Onyx Local"
BUILD_DIR=".build/apple/Products/Release"
DIST_DIR="dist"

echo "→ swift build -c $CONF"
swift build -c "$CONF" --arch arm64

rm -rf "$DIST_DIR/$APP_NAME.app"
mkdir -p "$DIST_DIR/$APP_NAME.app/Contents/MacOS"
mkdir -p "$DIST_DIR/$APP_NAME.app/Contents/Resources"

cp .build/arm64-apple-macosx/release/Onyx "$DIST_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist          "$DIST_DIR/$APP_NAME.app/Contents/Info.plist"
cp Resources/Onyx.entitlements   "$DIST_DIR/$APP_NAME.app/Contents/Resources/"

echo "→ codesign with '$CERT_NAME'"
codesign --deep --force --options runtime \
  --entitlements Resources/Onyx.entitlements \
  --sign "$CERT_NAME" \
  "$DIST_DIR/$APP_NAME.app"

echo "→ verify"
codesign --verify --verbose=2 "$DIST_DIR/$APP_NAME.app"
spctl --assess --type execute --verbose=4 "$DIST_DIR/$APP_NAME.app" || true
echo "Built $DIST_DIR/$APP_NAME.app"
```

`chmod +x scripts/build-app.sh`.

- [ ] **Step 5: First bundle build**

```bash
./scripts/setup-cert.sh           # one-time
./scripts/build-app.sh
open dist/Onyx.app                # first launch (Gatekeeper: right-click → Open)
```

- [ ] **Step 6: Commit**

```bash
git add Resources scripts
git commit -m "feat(dist): Info.plist + entitlements + build/sign scripts"
```

---

## Task 30: `generate-appcast.sh` (Sparkle release helper)

**Files:**
- Create: `scripts/generate-appcast.sh`

- [ ] **Step 1: Script**

```bash
#!/usr/bin/env bash
set -euo pipefail
# Requires: brew install --cask sparkle (provides `generate_appcast`)
DIST_DIR="${1:-dist/releases}"
mkdir -p "$DIST_DIR"
generate_appcast "$DIST_DIR"
echo "Appcast at $DIST_DIR/appcast.xml"
echo "Host the whole $DIST_DIR/ folder somewhere reachable (e.g. GitHub Releases + a static appcast.xml URL)."
```

`chmod +x scripts/generate-appcast.sh`.

- [ ] **Step 2: Commit**

```bash
git add scripts/generate-appcast.sh
git commit -m "feat(dist): Sparkle appcast helper"
```

---

## Task 31: Manual end-to-end validation

- [ ] **Step 1: Run automated tests**

```bash
swift test
```
Expected: all suites green.

- [ ] **Step 2: Record a real 5-min meeting**

1. Open `dist/Onyx.app` (right-click → Open first time).
2. Complete onboarding (grant mic + screen recording, wait for models to download).
3. Join a real Google Meet with someone.
4. Trigger recording via ⌘⇧R.
5. After ~5 min, ⌘⇧R again to stop.
6. Wait for transcript (yellow icon → grey).
7. Open `~/Meetings/`, verify latest folder contains `audio/mic.m4a`, `audio/system.m4a`, `transcripts/transcript.md`.
8. Open `transcript.md`, verify it reads well and speakers are separated (MOI + SPEAKER_0X).

- [ ] **Step 3: Crash-recovery test**

1. Start a recording.
2. After 60 s, `killall Onyx`.
3. Re-open Onyx.app.
4. Verify: the incomplete meeting folder still contains readable WAVs, and `resumePendingJobs()` picks it back up (yellow icon on relaunch, transcript is produced).

- [ ] **Step 4: Permissions-preservation test**

1. Note current time.
2. Rebuild with `./scripts/build-app.sh` (no changes needed).
3. Reinstall to `/Applications/Onyx.app`.
4. Launch → verify NO mic/screen-recording prompt appears again.

- [ ] **Step 5: Commit release notes**

Write `CHANGELOG.md` for v0.1.0 covering these steps then:
```bash
git add CHANGELOG.md
git commit -m "docs: v0.1.0 changelog"
```

---

## Self-review notes

Spec coverage check (§ refers to spec sections):

- §1 objectifs / §2 périmètre → Tasks 1, 8-10, 12-19, 26-30 cover the pipeline; hors-périmètre respected (no calendar, Claude, viewer).
- §3 archi → RecorderCore vs Onyx split (Task 1), disk-driven contracts throughout.
- §4 Recorder + WAV + M4A + state machine → Tasks 7-11.
- §5 pipeline 6 steps → Tasks 12-19 (Normalize, Whisper mic/system, Diarize, Merge, Render, Cleanup).
- §6 storage layout + meta.json + job.json + SQLite index → Tasks 4-6, 20-22.
- §7 stack SwiftPM aligned WinTab → Task 1.
- §8 UX / signature stable / Sparkle / onboarding → Tasks 23-30.
- §9 testing → Unit tests in Tasks 2, 4, 5, 6, 7, 12, 13, 19, 21, 22 ; manual crash + permissions in Task 31.
- §10 risques mitigés (cert backup dans Task 29 step 3 ; sherpa integration fallback in Task 17).
- §11 livrables → covered by Task 31.

Diarizer sherpa integration (Task 17 Step 3) is the highest-risk task — leave time for it. Everything else is well-trodden Swift.
