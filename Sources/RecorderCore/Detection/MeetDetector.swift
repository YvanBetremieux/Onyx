import Foundation

public final class MeetDetector: MeetingAppDetector {
    public let app: MeetingApp = .meet

    /// Pas de marge : les échecs de sonde (cause de l'incident du 2026-08-06)
    /// sont déjà neutralisés (`nil`), et un onglet absent d'une sonde réussie
    /// est une vraie fin. 5 s de sonde : JXA sur tous les onglets coûte cher et
    /// expire sous la charge de transcription s'il tourne plus souvent.
    public static let defaultEndedGraceSeconds: TimeInterval = 0

    private let pollSeconds: TimeInterval
    private let endedGraceSeconds: TimeInterval
    private let browserBundles: [String]

    public init(pollSeconds: TimeInterval = 5,
                endedGraceSeconds: TimeInterval = MeetDetector.defaultEndedGraceSeconds,
                browserBundles: [String] = [
                    "com.google.Chrome",
                    "com.apple.Safari",
                    "company.thebrowser.Browser", // Arc
                    "com.brave.Browser",
                ]) {
        self.pollSeconds = pollSeconds
        self.endedGraceSeconds = endedGraceSeconds
        self.browserBundles = browserBundles
    }

    private static let meetURLRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"meet\.google\.com/([a-z]{3}-[a-z]{4}-[a-z]{3})"#,
            options: [.caseInsensitive])
    }()

    public func events() -> AsyncStream<CallLifecycle> {
        AsyncStream { continuation in
            let task = Task.detached { [pollSeconds, endedGraceSeconds, browserBundles] in
                var debouncer = CallDebouncer(endedGraceSeconds: endedGraceSeconds)
                while !Task.isCancelled {
                    let current = Self.pollAllBrowsers(bundles: browserBundles)
                    for ev in debouncer.observe(current) { continuation.yield(ev) }
                    try? await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One poll across all browsers.
    ///
    /// WHY the asymmetry: *presence* found by any successful probe is
    /// trustworthy — a code is a code, regardless of what other browsers
    /// reported — so if any codes were seen the poll is a success carrying
    /// them (otherwise a single persistently failing browser, e.g. Safari
    /// stuck on an automation prompt, would make every poll "unknown"
    /// forever and suppress `.started` for a perfectly visible Chrome Meet).
    /// *Absence*, however, can't be trusted when a probe failed: the failed
    /// browser could have hosted the call, and reporting the partial result
    /// as truth would look like absence and end a live recording (the
    /// 2026-08-06 incident — osascript timeouts under transcription load
    /// fired false `.ended`s on a 1-hour meeting). So: any failure AND no
    /// codes seen → `nil` ("unknown"). A browser that simply isn't running
    /// is a *successful* empty probe. Residual gap, accepted: if the browser
    /// hosting the recorded code fails persistently while another browser
    /// reports a *different* code, the poll counts as successful and the
    /// recorded code's absence clock advances — strictly narrower than the
    /// previous failure modes, and the app records one call at a time.
    static func pollAllBrowsers(bundles: [String]) -> Set<String>? {
        var codes = Set<String>()
        var anyFailure = false
        for bundle in bundles {
            guard let urls = jxaURLs(forBundle: bundle) else {
                anyFailure = true
                continue
            }
            for url in urls {
                let range = NSRange(url.startIndex..<url.endIndex, in: url)
                if let m = meetURLRegex.firstMatch(in: url, range: range),
                   let codeRange = Range(m.range(at: 1), in: url) {
                    codes.insert(String(url[codeRange]))
                }
            }
        }
        if anyFailure && codes.isEmpty { return nil }
        return codes
    }

    /// URLs of all tabs of `bundle`, or `nil` if the probe itself failed
    /// (osascript couldn't launch, was killed by the 10 s timeout, or exited
    /// nonzero). A browser that isn't running returns `[]` — a genuine,
    /// successful "no URLs". The distinction matters: failure means "unknown",
    /// not "no call open".
    static func jxaURLs(forBundle bundle: String) -> [String]? {
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

        // Drain pipes continuously to prevent 64 KB pipe buffer deadlock.
        let stdoutCollector = DataCollector()
        let stderrCollector = DataCollector()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { stdoutCollector.append(d) }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { stderrCollector.append(d) }
        }

        do { try proc.run() } catch { return nil }

        // Kill osascript if it doesn't finish within 10 seconds. SIGTERM
        // first, then escalate to SIGKILL after 2 more seconds: a wedged
        // osascript that ignores SIGTERM would otherwise leave
        // `waitUntilExit()` blocked forever, permanently killing the polling
        // loop. asyncAfter (not a dedicated thread) so a probe every 5 s
        // doesn't accumulate resident watchdog threads.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            guard proc.isRunning else { return }
            proc.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            }
        }
        proc.waitUntilExit()

        // Stop handlers and drain any final bytes.
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        if let d = try? out.fileHandleForReading.readToEnd(), !d.isEmpty {
            stdoutCollector.append(d)
        }

        // Killed by the 10 s timeout (uncaught SIGTERM) or nonzero exit:
        // the probe failed — that is NOT the same as "browser has no tabs".
        guard proc.terminationReason == .exit, proc.terminationStatus == 0 else { return nil }
        let data = stdoutCollector.snapshot
        guard let s = String(data: data, encoding: .utf8), !s.isEmpty else { return [] }
        return s.split(separator: "\n").map(String.init)
    }
}
