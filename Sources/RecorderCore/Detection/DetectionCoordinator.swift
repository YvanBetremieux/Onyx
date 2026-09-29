import Foundation

public actor DetectionCoordinator {
    private let detectors: [any MeetingAppDetector]
    private let debounceEndedSeconds: TimeInterval

    private var pendingEnded: [String: Task<Void, Never>] = [:]
    /// UUID token per key — incremented each time a new debounce task is created.
    /// The task captures the token at creation time and bails out if it no longer
    /// matches by the time the sleep expires, preventing ghost `.ended` events.
    private var debounceTokens: [String: UUID] = [:]

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
        }
        continuation.finish()
    }

    private func handle(_ ev: CallLifecycle,
                        from app: MeetingApp,
                        sink: AsyncStream<CallEvent>.Continuation) {
        switch ev {
        case .started(let code):
            let key = "\(app.rawValue):\(code)"
            if let pending = pendingEnded.removeValue(forKey: key) {
                // Flicker suppression: cancel the pending .ended and do NOT re-emit
                // .started — from the consumer's perspective the call never dropped.
                // Also invalidate the token so any in-flight emitEnded call is suppressed.
                pending.cancel()
                debounceTokens[key] = nil
                return
            }
            sink.yield(CallEvent(app: app, kind: .started, code: code))

        case .ended(let code):
            let key = "\(app.rawValue):\(code)"
            pendingEnded[key]?.cancel()
            let token = UUID()
            debounceTokens[key] = token
            let delaySeconds = debounceEndedSeconds
            let task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                // Double-guard: cooperative cancellation + UUID token.
                // The token check closes the race window where isCancelled may not
                // yet be visible but the token was already replaced by a newer task.
                guard !Task.isCancelled else { return }
                await self?.emitEnded(app: app, code: code, token: token, sink: sink)
            }
            pendingEnded[key] = task
        }
    }

    private func emitEnded(app: MeetingApp,
                           code: String,
                           token: UUID,
                           sink: AsyncStream<CallEvent>.Continuation) {
        let key = "\(app.rawValue):\(code)"
        // Token guard: if the stored token no longer matches, a newer debounce task
        // has been scheduled (call resumed), so suppress this ghost `.ended` event.
        guard debounceTokens[key] == token else { return }
        debounceTokens[key] = nil
        pendingEnded[key] = nil
        sink.yield(CallEvent(app: app, kind: .ended, code: code))
    }
}
