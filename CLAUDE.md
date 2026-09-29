# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Onyx is a native macOS menu-bar app that records meetings (mic + system audio), transcribes them
with WhisperKit, diarizes speakers with sherpa-onnx, merges the two into a transcript, and
optionally generates meeting notes via a local `claude -p` CLI call. Recording can be triggered
manually, by matching an EventKit calendar event, or by detecting a live Google Meet / Slack
Huddle window.

## Build, test, run

```bash
swift build                                  # debug build
swift build -c release --arch arm64          # release build (what build-app.sh uses)
swift test                                   # run all tests
swift test --filter PipelineTests            # run one test target/class
swift test --filter PipelineTests/testName   # run one test method
```

First-time setup fetches vendored native deps (not checked into git):

```bash
scripts/fetch-sherpa.sh     # downloads sherpa-onnx dylibs + headers into Vendor/
scripts/setup-cert.sh       # installs a local self-signed "Onyx Local" codesign identity
```

Packaging a runnable `.app` (build + bundle dylibs/Sparkle.framework + inside-out codesign):

```bash
scripts/build-app.sh        # produces dist/Onyx.app
```

`Sources/CSherpaOnnx` links against `Vendor/sherpa-onnx/lib` via `unsafeFlags` rpath in
`Package.swift` for local dev only; `build-app.sh` re-homes the dylibs into
`Contents/Frameworks` with a proper rpath for distribution. See `docs/known-decisions.md`
before "fixing" anything that looks incomplete there (Sparkle appcast wiring, nil SHA-256
checksums in `ModelManifest.swift`, `FILL_ME_IN` hash in `fetch-sherpa.sh`) — these are
documented deliberate gaps, not bugs.

`scripts/e2e-chantier-2.sh` builds and runs the `E2ETrigger` executable target, a harness for
exercising the calendar/detection auto-trigger path under real conditions (reads
`ONYX_E2E_ATTENDEE` env var).

## Architecture

Two targets matter: `RecorderCore` (library, all logic, unit-tested) and `Onyx` (SwiftUI
menu-bar app, thin UI layer over `RecorderCore`). `DiarizerSmoke` and `E2ETrigger` are small
standalone executables for manual/E2E verification, not part of the app bundle.

### Recording lifecycle state machine

`AutoTriggerOrchestrator` (actor, `Autotrigger/AutoTriggerOrchestrator.swift`) is the single
source of truth for whether Onyx is idle/starting/recording/stopping. All three trigger
sources funnel into it:

- Manual: `AppState.toggleRecording()` → `orchestrator.manualStart()/manualStop()`
- Calendar: `CalendarWatcher` emits `MatchedEvent` → `orchestrator.onCalendarEvent(_:)`
- App detection: `DetectionCoordinator` merges `MeetDetector` (JXA/AppleScript polling) and
  `SlackHuddleDetector` (CGWindowList polling) into `CallEvent`s → `orchestrator.onCallEvent(_:)`

The orchestrator talks to recording only through the `RecordingSession` protocol, implemented by
`RecorderSession`, which wraps `Recorder` + `MeetingStorage` + `Pipeline`. This indirection is
what makes the orchestrator's state transitions unit-testable without real audio I/O — tests
inject a fake `RecordingSession`. `AppState` (in the `Onyx` target) is the only place that wires
concrete calendar/detection sources into the orchestrator and bridges its state to
`@Published` UI state; it also boots background loops (`bootAutotrigger()`) and resumes any
interrupted pipeline jobs (`resumePendingJobs()`) eagerly at launch, not lazily on first UI
appearance.

`state = .starting` / `.stopping` is claimed *before* the `await` into `session.start()/stop()`
so a second trigger arriving during the async gap is ignored rather than racing — this is called
out inline as "C1 fix" / "C3 fix" in the source; preserve that ordering in any changes.

### Pipeline

`Pipeline` (actor, `Pipeline/Pipeline.swift`) runs a fixed sequence of steps against a
`MeetingPaths` (a slug-addressed directory layout under the user's meetings folder):
normalize → whisper (mic + system, independently) → diarize → merge → render markdown →
cleanup → notes (soft-fail step).

Each step's status is persisted to `job.json` (`Storage/JobState.swift`) after every
start/success/failure, which is what makes the pipeline resumable: `runStep` skips a step whose
recorded status is already `.done`, so a crash or app restart mid-pipeline picks back up instead
of re-running from scratch (`AppState.resumePendingJobs()` scans all meetings for `job.isResumable`
at launch and resumes them). `.notes` uses `runStepSoft`, which resets overall state back to
`.done` on failure instead of `.failed` — a notes failure must not block the transcript from being
considered complete.

Data flow between steps is disk-mediated JSON under `MeetingPaths.transcripts` (`AtomicJSON`),
not passed in memory — steps are independently resumable and independently testable against
fixture files.

### Storage layout

`MeetingPaths` (`Support/MeetingPaths.swift`) is the canonical mapping from a meeting `slug`
(`yyyy-MM-dd_HH'h'mm`) to its on-disk files: `audio/`, `transcripts/`, `notes/`, `meta.json`,
`job.json`. `MeetingStorage` owns reading/writing `meta.json` (`MeetingMetadata`) and `job.json`
(`JobState`) atomically. `MeetingIndexer` maintains a separate SQLite index (GRDB) at
`~/Library/Application Support/Onyx/index.sqlite` for fast search/listing; it's rebuilt
automatically if found corrupt at launch rather than crashing the app.

### Merging meetings

Two independent paths end with several recordings living inside one meeting:

- **Automatic** — `ContinuationAbsorber` (pipeline `.absorb` step): a recording restarted after
  a crash mid-meeting (`MeetingMetadata.continuationOf`) is shifted by the *real* wall-clock
  offset between the two starts and appended to its parent.
- **Manual** — `MeetingMerger`, driven from the viewer sidebar's checkbox selection mode
  (`ViewerStore.mergeCheckedMeetings`): meetings picked by hand have no wall-clock relationship,
  so their parts are **butted end-to-end** (part 2 starts where part 1's *audio* ends) and
  recorded in `MeetingMetadata.mergedParts` (slug + offset + duration, frozen at merge time).

Both merge at the transcript level only — **no audio is ever rewritten**. For a merged meeting
`AudioPlayer.load(parts:)` inserts each part's streams at its stored offset in one
`AVMutableComposition`, so one transport and one waveform cover the whole timeline; the absorbed
parts' folders are therefore *kept* on disk (flagged `absorbed` + `mergedInto`, which is what
hides them from the index and the sidebar) rather than trashed. Both paths share
`NoteFanout.regenerate`, which overwrites the carrier's notes over the full transcript with no
exists-on-disk skip.

### Notes generation

`ClaudeNoteGenerator` shells out to a user-configured local `claude` binary (`Process`) with one
of three prompt levels (`NoteLevel`: brief / synthese / detaillee, see
`Notes/NotePromptTemplates.swift`). The binary path and enable/level settings live in
`SettingsStore` and are hot-reloaded into the running `Pipeline` via
`AppState.reloadNotesConfig()` — the pipeline is an actor, so mutating its `notes` config from a
setting change is inherently thread-safe.

### Concurrency conventions

Long-lived stateful components (`Pipeline`, `AutoTriggerOrchestrator`, `DetectionCoordinator`)
are Swift actors. Event sources (`CalendarWatcher.matches()`, `DetectionCoordinator.events()`)
are exposed as `AsyncStream`s consumed via `for await` in `Task.detached` loops started from
`AppState`. Blocking native calls (sherpa-onnx diarization) are explicitly bounced off the
Swift cooperative thread pool onto a `DispatchQueue.global` inside a `withCheckedThrowingContinuation`
to avoid starving other async work — follow this pattern for any other blocking C/native call
added to the pipeline.

## Tests

`Tests/RecorderCoreTests` covers `RecorderCore` only (no UI tests). Tests generally construct
real `MeetingPaths`/`MeetingStorage` against temp directories rather than mocking the
filesystem, and inject fake protocol implementations (`RecordingSession`, `WhisperTranscribing`,
`Diarizing`) for external dependencies. When adding a pipeline step or orchestrator transition,
check `AutoTriggerOrchestratorTests.swift` / `PipelineTests.swift` first for the existing
fixture/fake pattern before inventing a new one.
