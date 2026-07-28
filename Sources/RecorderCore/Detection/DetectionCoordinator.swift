import Foundation

public actor DetectionCoordinator {
    private let detectors: [any MeetingAppDetector]
    private let debounceEndedSeconds: TimeInterval

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
                pending.cancel()
                return
            }
            sink.yield(CallEvent(app: app, kind: .started, code: code))

        case .ended(let code):
            let key = "\(app.rawValue):\(code)"
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
