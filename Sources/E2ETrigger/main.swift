// E2ETrigger — real-conditions end-to-end test harness for Onyx Chantier 2.
//
// Run from the repo root:
//   swift run E2ETrigger
// or via the convenience wrapper:
//   ./scripts/e2e-chantier-2.sh
//
// Phases:
//   0 — Preflight (pgrep, calendar permission, whitelisted calendars)
//   1 — Create test calendar event via AppleScript (+ attendee) or EKEvent fallback
//   2 — Wait for meeting folder to appear in ~/Meetings
//   3 — Verify meta.json contents
//   4 — Simulated crash: pkill Onyx, relaunch
//   5 — Wait for pipeline completion (job.json state == "done")
//   6 — Verify final artifacts (transcript.md, optional notes file)
//   7 — Cleanup (delete calendar event, move meeting folder to /tmp)

import Foundation
import EventKit
import RecorderCore

// ---------------------------------------------------------------------------
// MARK: - Globals & helpers
// ---------------------------------------------------------------------------

var failedAsserts: [String] = []
var createdEventUID: String? = nil
var meetingFolderURL: URL? = nil
var testId: String = ""

func log(_ phase: Int, _ message: String) {
    print("[phase \(phase)] \(message)")
    fflush(stdout)
}

func logBanner(_ message: String) {
    print("\n=== \(message) ===")
    fflush(stdout)
}

func assert(description: String, _ condition: Bool) {
    if condition {
        print("  PASS  \(description)")
    } else {
        print("  FAIL  \(description)")
        failedAsserts.append(description)
    }
}

@discardableResult
func shell(_ command: String) -> (output: String, exitCode: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", command]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try? process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return (output.trimmingCharacters(in: .whitespacesAndNewlines), process.terminationStatus)
}

func failAndExit(_ message: String, code: Int32 = 1) -> Never {
    print("\n[ERROR] \(message)")
    cleanup()
    exit(code)
}

func cleanup() {
    // Delete calendar event if we created one
    if let uid = createdEventUID {
        log(7, "Deleting calendar event (uid: \(uid)) via AppleScript…")
        let script = """
            tell application "Calendar"
                set theEvents to (every event of every calendar whose uid is "\(uid)")
                repeat with e in theEvents
                    delete e
                end repeat
            end tell
            """
        let result = shell(#"osascript -e '\#(script.replacingOccurrences(of: "'", with: "'\\''"))'"#)
        if result.exitCode == 0 {
            log(7, "Calendar event deleted.")
        } else {
            // Try the simpler delete-by-uid form as fallback
            let fallback = """
                tell application "Calendar"
                    repeat with cal in every calendar
                        try
                            set ev to first event of cal whose uid is "\(uid)"
                            delete ev
                        end try
                    end repeat
                end tell
                """
            shell(#"osascript -e '\#(fallback.replacingOccurrences(of: "'", with: "'\\''"))'"#)
            log(7, "Calendar event delete attempted (fallback).")
        }
        createdEventUID = nil
    }

    // Move meeting folder to /tmp to avoid polluting ~/Meetings
    if let folder = meetingFolderURL {
        let dest = URL(fileURLWithPath: "/tmp/onyx-e2e-\(testId)")
        log(7, "Moving meeting folder to \(dest.path)…")
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: folder, to: dest)
            log(7, "Meeting folder moved to \(dest.path)")
        } catch {
            log(7, "Warning: could not move meeting folder: \(error.localizedDescription)")
        }
        meetingFolderURL = nil
    }
}

// ---------------------------------------------------------------------------
// MARK: - Phase 0 — Preflight
// ---------------------------------------------------------------------------

logBanner("Phase 0: Preflight")

// 0a — Is Onyx running?
let pgrep = shell("pgrep -x Onyx")
guard pgrep.exitCode == 0 else {
    print("[phase 0] Onyx is NOT running.")
    print("          Start it first:  open dist/Onyx.app")
    exit(1)
}
log(0, "Onyx is running (pid: \(pgrep.output))")

// 0b — Calendar permission
let store = EKEventStore()
var calAccessGranted = false
let semCal = DispatchSemaphore(value: 0)
if #available(macOS 14.0, *) {
    store.requestFullAccessToEvents { granted, _ in
        calAccessGranted = granted
        semCal.signal()
    }
} else {
    store.requestAccess(to: .event) { granted, _ in
        calAccessGranted = granted
        semCal.signal()
    }
}
semCal.wait()
guard calAccessGranted else {
    print("[phase 0] Calendar access denied. Grant access in System Settings → Privacy & Security → Calendars.")
    exit(1)
}
log(0, "Calendar access granted.")

// 0c — Whitelisted calendars
guard let enabledCalIds = UserDefaults.standard.array(forKey: "enabledCalendarIds") as? [String],
      !enabledCalIds.isEmpty else {
    print("[phase 0] No whitelisted calendars found (UserDefaults key: enabledCalendarIds).")
    print("          Run Onyx onboarding first and enable at least one calendar in Settings.")
    exit(1)
}
log(0, "Whitelisted calendar IDs: \(enabledCalIds)")

// 0d — Look up the first calendar
guard let targetCalendar = store.calendar(withIdentifier: enabledCalIds[0]) else {
    print("[phase 0] Could not find EKCalendar for id \(enabledCalIds[0]).")
    exit(1)
}
log(0, "Using calendar: '\(targetCalendar.title)' (type: \(targetCalendar.type.rawValue))")
if !targetCalendar.allowsContentModifications {
    log(0, "Warning: calendar is read-only. Event creation may fail.")
}
if targetCalendar.source?.sourceType == .calDAV {
    log(0, "Warning: CalDAV/Google calendar — attendees added via AppleScript may not sync reliably.")
}

// ---------------------------------------------------------------------------
// MARK: - Phase 1 — Create test calendar event
// ---------------------------------------------------------------------------

logBanner("Phase 1: Create test calendar event")

testId = String(UUID().uuidString.prefix(8))
let eventTitle = "Onyx E2E \(testId)"
let startDate = Date().addingTimeInterval(75)
let endDate = startDate.addingTimeInterval(300)
let eventNotes = "Test event by E2ETrigger. Meet link: https://meet.google.com/tst-abcd-efg"
let calUID = targetCalendar.calendarIdentifier

// Format dates for AppleScript: "Monday, July 28, 2026 at 12:00:00 PM"
let asFmt = DateFormatter()
asFmt.locale = Locale(identifier: "en_US_POSIX")
asFmt.dateFormat = "EEEE, MMMM d, y 'at' h:mm:ss a"
let startStr = asFmt.string(from: startDate)
let endStr = asFmt.string(from: endDate)

log(1, "testId=\(testId)  title='\(eventTitle)'")
log(1, "start=\(startStr)  end=\(endStr)")
log(1, "Attempting AppleScript event creation with attendee…")

// Build AppleScript — use Here-Doc style in shell to avoid quoting nightmares.
// We write the script to a temp file to avoid shell-escaping issues with the date strings.
let appleScriptContent = """
tell application "Calendar"
    tell (first calendar whose uid is "\(calUID)")
        set newEvent to make new event at end with properties {summary:"\(eventTitle)", start date:date "\(startStr)", end date:date "\(endStr)", description:"\(eventNotes)"}
        tell newEvent
            make new attendee at end with properties {email:"e2e-test@onyx.local"}
        end tell
        return uid of newEvent
    end tell
end tell
"""

let tmpScriptURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("onyx-e2e-\(testId).applescript")
try? appleScriptContent.write(to: tmpScriptURL, atomically: true, encoding: .utf8)

let appleScriptResult = shell("osascript \(tmpScriptURL.path)")
try? FileManager.default.removeItem(at: tmpScriptURL)

var usedAppleScript = false
if appleScriptResult.exitCode == 0 && !appleScriptResult.output.isEmpty {
    createdEventUID = appleScriptResult.output
    usedAppleScript = true
    log(1, "AppleScript succeeded. Event UID: \(createdEventUID!)")
} else {
    log(1, "AppleScript failed (exit \(appleScriptResult.exitCode)): \(appleScriptResult.output)")
    log(1, "Falling back to EventKit (no attendee)…")

    let ekEvent = EKEvent(eventStore: store)
    ekEvent.title = eventTitle
    ekEvent.startDate = startDate
    ekEvent.endDate = endDate
    ekEvent.notes = eventNotes
    ekEvent.calendar = targetCalendar

    do {
        try store.save(ekEvent, span: .thisEvent)
        createdEventUID = ekEvent.eventIdentifier
        log(1, "EKEvent created. Event identifier: \(createdEventUID ?? "nil")")
        log(1, "WARNING: Fallback to EKEvent — event will lack attendees; CalendarMatcher")
        log(1, "         may reject it if attendeeCount > 1 is required.")
        log(1, "         Manually add an attendee in Calendar.app before start time.")

        // If we're in a TTY, wait for user confirmation
        if isatty(STDIN_FILENO) != 0 {
            print("\nPress Enter after adding an attendee in Calendar.app, then continue…")
            _ = readLine()
        }
    } catch {
        failAndExit("Could not create event via EventKit either: \(error.localizedDescription)")
    }
}

// ---------------------------------------------------------------------------
// MARK: - Phase 2 — Wait for meeting folder to appear
// ---------------------------------------------------------------------------

logBanner("Phase 2: Wait for meeting folder")

let meetingsRoot: URL = {
    if let custom = UserDefaults.standard.string(forKey: "meetingsFolder"), !custom.isEmpty {
        return URL(fileURLWithPath: custom.replacingOccurrences(of: "~",
            with: FileManager.default.homeDirectoryForCurrentUser.path))
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Meetings")
}()

log(2, "Watching meetings folder: \(meetingsRoot.path)")
log(2, "Looking for folder whose meta.json matches testId '\(testId)' or calendarEventId…")
log(2, "Polling every 2 s, timeout 3 min…")

let phase2Deadline = Date().addingTimeInterval(180)
var foundFolder: URL? = nil

outerPoll:
while Date() < phase2Deadline {
    Thread.sleep(forTimeInterval: 2)
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: meetingsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
    ) else { continue }

    for entry in contents {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }

        let metaURL = entry.appendingPathComponent("meta.json")
        guard let metaData = try? Data(contentsOf: metaURL),
              let meta = try? AtomicJSON.decoder.decode(MeetingMetadata.self, from: metaData) else { continue }

        // Match by calendarEventId or by title containing testId
        let matchById = (meta.calendarEventId == createdEventUID) ||
                        (createdEventUID.map { meta.calendarEventId?.contains($0) == true } ?? false)
        let matchByTitle = meta.title?.contains(testId) == true

        if matchById || matchByTitle {
            foundFolder = entry
            meetingFolderURL = entry
            let idSource = matchById ? "calendarEventId match" : "title match"
            log(2, "Meeting folder found (\(idSource)): \(entry.path)")
            log(2, "meta.title = \(meta.title ?? "<nil>"), source = \(meta.source.rawValue), calendarEventId = \(meta.calendarEventId ?? "<nil>")")
            break outerPoll
        }
    }
}

guard let meetingFolder = foundFolder else {
    failAndExit("Timed out waiting for meeting folder. Onyx may not have triggered recording.")
}

// ---------------------------------------------------------------------------
// MARK: - Phase 3 — Verify meta.json
// ---------------------------------------------------------------------------

logBanner("Phase 3: Verify meta.json")

let metaURL = meetingFolder.appendingPathComponent("meta.json")
if let metaData = try? Data(contentsOf: metaURL),
   let meta = try? AtomicJSON.decoder.decode(MeetingMetadata.self, from: metaData) {
    assert(description: "source == .calendar", meta.source == .calendar)
    assert(description: "title contains testId '\(testId)'", meta.title?.contains(testId) == true)
    assert(description: "calendarEventId is non-nil (soft check)", meta.calendarEventId != nil)
    log(3, "meta.json: source=\(meta.source.rawValue), title=\(meta.title ?? "<nil>"), calendarEventId=\(meta.calendarEventId ?? "<nil>")")
} else {
    log(3, "WARN: Could not decode meta.json — skipping assertions.")
    failedAsserts.append("meta.json decode failed")
}

// ---------------------------------------------------------------------------
// MARK: - Phase 4 — Simulated crash
// ---------------------------------------------------------------------------

logBanner("Phase 4: Simulated crash & relaunch")

log(4, "pkill Onyx")
shell("pkill -x Onyx")
Thread.sleep(forTimeInterval: 1)

let stillRunning = shell("pgrep -x Onyx")
if stillRunning.exitCode == 0 {
    log(4, "Warning: Onyx still running after pkill (pid: \(stillRunning.output)). Trying SIGKILL…")
    shell("pkill -9 -x Onyx")
    Thread.sleep(forTimeInterval: 1)
} else {
    log(4, "Onyx terminated successfully.")
}

// Resolve repo root from CWD (tool is expected to be run from repo root)
let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let appBundle = repoRoot.appendingPathComponent("dist/Onyx.app")

log(4, "Relaunching Onyx via: open \(appBundle.path)")
shell("open \(appBundle.path)")

log(4, "Waiting 5 s for app to boot…")
Thread.sleep(forTimeInterval: 5)
log(4, "Open the Onyx menu bar item to trigger resumePendingJobs (currently gated on menu appear).")

// ---------------------------------------------------------------------------
// MARK: - Phase 5 — Wait for pipeline completion
// ---------------------------------------------------------------------------

logBanner("Phase 5: Wait for pipeline completion")

let jobURL = meetingFolder.appendingPathComponent("job.json")
log(5, "Watching \(jobURL.path)")
log(5, "Timeout: 5 minutes")

let phase5Deadline = Date().addingTimeInterval(300)
var lastJobState: JobOverallState? = nil
var pipelineDone = false

while Date() < phase5Deadline {
    Thread.sleep(forTimeInterval: 3)
    guard let jobData = try? Data(contentsOf: jobURL),
          let job = try? AtomicJSON.decoder.decode(JobState.self, from: jobData) else { continue }

    if job.state != lastJobState {
        log(5, "Pipeline state: \(job.state.rawValue)")
        lastJobState = job.state
    }

    if job.state == .done {
        pipelineDone = true
        log(5, "Pipeline completed successfully.")
        break
    }
    if job.state == .failed {
        log(5, "Pipeline FAILED: \(job.error ?? "<no error>")")
        failedAsserts.append("pipeline failed: \(job.error ?? "unknown")")
        break
    }
}

if !pipelineDone && lastJobState != .failed {
    log(5, "Timed out waiting for pipeline to complete. Last state: \(lastJobState?.rawValue ?? "<unknown>")")
    failedAsserts.append("pipeline timed out")
}

// ---------------------------------------------------------------------------
// MARK: - Phase 6 — Verify final artifacts
// ---------------------------------------------------------------------------

logBanner("Phase 6: Verify final artifacts")

let transcriptMd = meetingFolder
    .appendingPathComponent("transcripts")
    .appendingPathComponent("transcript.md")
let transcriptExists = FileManager.default.fileExists(atPath: transcriptMd.path)
assert(description: "transcript.md exists", transcriptExists)
log(6, "transcript.md: \(transcriptExists ? "found ✓" : "MISSING ✗") at \(transcriptMd.path)")

// Notes check (soft) — only if both claudeBinaryPath and autoNotesEnabled are set
let claudePath = UserDefaults.standard.string(forKey: "claudeBinaryPath") ?? ""
let autoNotes = UserDefaults.standard.bool(forKey: "autoNotesEnabled")
if !claudePath.isEmpty && autoNotes {
    let defaultLevelRaw = UserDefaults.standard.string(forKey: "defaultNoteLevel") ?? NoteLevel.synthese.rawValue
    let level = NoteLevel(rawValue: defaultLevelRaw) ?? .synthese
    let notesFile = meetingFolder
        .appendingPathComponent("notes")
        .appendingPathComponent("\(level.rawValue).md")
    let notesExist = FileManager.default.fileExists(atPath: notesFile.path)
    if notesExist {
        log(6, "notes/\(level.rawValue).md: found ✓")
    } else {
        log(6, "notes/\(level.rawValue).md: MISSING (soft fail — Claude may have failed)")
        // Not added to failedAsserts — this is a soft check
    }
} else {
    log(6, "Skipping notes check (claudeBinaryPath or autoNotesEnabled not configured).")
}

// ---------------------------------------------------------------------------
// MARK: - Phase 7 — Cleanup
// ---------------------------------------------------------------------------

logBanner("Phase 7: Cleanup")
cleanup()

// ---------------------------------------------------------------------------
// MARK: - Final summary
// ---------------------------------------------------------------------------

logBanner("Summary")

let criticalAsserts = failedAsserts.filter { assert in
    // Soft asserts (notes, calendarEventId) are excluded from exit code determination
    !assert.contains("notes") && !assert.contains("calendarEventId")
}

if failedAsserts.isEmpty {
    print("OVERALL: PASS — all assertions passed.")
    exit(0)
} else {
    print("OVERALL: \(criticalAsserts.isEmpty ? "PARTIAL PASS" : "FAIL") — \(failedAsserts.count) assertion(s) failed:")
    for f in failedAsserts {
        print("  - \(f)")
    }
    exit(criticalAsserts.isEmpty ? 0 : 1)
}
