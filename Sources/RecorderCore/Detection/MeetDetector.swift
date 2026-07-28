import Foundation

public final class MeetDetector: MeetingAppDetector {
    public let app: MeetingApp = .meet

    private let pollSeconds: TimeInterval
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
                    for c in current.subtracting(active) { continuation.yield(.started(code: c)) }
                    for c in active.subtracting(current) { continuation.yield(.ended(code: c)) }
                    active = current
                    try? await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func pollAllBrowsers(bundles: [String]) -> Set<String> {
        var codes = Set<String>()
        for bundle in bundles {
            for url in jxaURLs(forBundle: bundle) {
                let range = NSRange(url.startIndex..<url.endIndex, in: url)
                if let m = meetURLRegex.firstMatch(in: url, range: range),
                   let codeRange = Range(m.range(at: 1), in: url) {
                    codes.insert(String(url[codeRange]))
                }
            }
        }
        return codes
    }

    static func jxaURLs(forBundle bundle: String) -> [String] {
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
        do { try proc.run(); proc.waitUntilExit() } catch { return [] }
        guard proc.terminationStatus == 0 else { return [] }
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        guard let s = String(data: data, encoding: .utf8), !s.isEmpty else { return [] }
        return s.split(separator: "\n").map(String.init)
    }
}
