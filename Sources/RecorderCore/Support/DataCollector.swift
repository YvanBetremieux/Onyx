import Foundation

/// Thread-safe data accumulator for draining `Process` pipes continuously
/// via `readabilityHandler` — prevents the 64 KB pipe buffer deadlock.
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
