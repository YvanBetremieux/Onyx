import Foundation

/// Loads / persists `ViewerState` to disk. Debounces `scheduleSave` calls so
/// rapid state mutations (e.g. dragging the resizer) don't hammer the FS.
public final class ViewerStatePersistence: @unchecked Sendable {
    private let url: URL
    private let debounceMs: Int
    private let queue = DispatchQueue(label: "com.onyx.viewer.persist")
    private var pending: DispatchWorkItem?
    /// Last state handed to `scheduleSave` that has not yet been written.
    /// Only ever touched on `queue`, so `flush()` can read it race-free.
    private var lastScheduled: ViewerState?

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

    /// Never throws into the UI: a missing or corrupt file yields defaults.
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

    /// Coalesces bursts of calls: only the last state is written, `debounceMs`
    /// after the final call. The last-scheduled state *can* still be lost if
    /// the process goes away before the deadline (quitting within `debounceMs`
    /// of a change) — call `flush()` on any such path.
    public func scheduleSave(_ state: ViewerState) {
        queue.async {
            self.pending?.cancel()
            self.lastScheduled = state
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.saveImmediately(state)
                self.lastScheduled = nil
            }
            self.pending = work
            self.queue.asyncAfter(deadline: .now() + .milliseconds(self.debounceMs), execute: work)
        }
    }

    /// Cancels any pending debounced write and writes the last scheduled state
    /// right now, synchronously. Call this before the process can go away
    /// (`applicationWillTerminate`, window close) — otherwise a change made
    /// inside the debounce window is silently dropped.
    ///
    /// Runs on the same serial queue as the debounce, so it can neither race
    /// with an in-flight `scheduleSave` nor be undone by a later firing of the
    /// work item it just cancelled. Must not be called *from* `queue`.
    public func flush() {
        queue.sync {
            self.pending?.cancel()
            self.pending = nil
            guard let state = self.lastScheduled else { return }
            self.lastScheduled = nil
            self.saveImmediately(state)
        }
    }
}
