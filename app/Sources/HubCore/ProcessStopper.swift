import Foundation

/// Stops a process from another thread, such as a search that typing has made stale.
/// A stop before launch keeps the process from starting at all.
public final class ProcessStopper: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false

    public init() {}

    /// Starts `process` unless a stop came first; false when it did.
    public func launch(_ process: Process) throws -> Bool {
        try lock.withLock {
            guard !stopped else { return false }
            try process.run()
            self.process = process
            return true
        }
    }

    public func stop() {
        lock.withLock {
            stopped = true
            if let process, process.isRunning { process.terminate() }
        }
    }
}
