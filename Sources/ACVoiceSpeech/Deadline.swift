import Foundation

/// A result that the first of several racing parties delivers (operation, timer, caller cancellation). Later
/// deliveries are dropped.
final class RaceSlot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var delivered = false
    private var result: Result<T, any Error>?
    private var continuation: CheckedContinuation<T, any Error>?

    /// Returns false when the slot was filled already.
    @discardableResult
    func fill(_ r: Result<T, any Error>) -> Bool {
        let (won, waiter) = lock.withLock { () -> (Bool, CheckedContinuation<T, any Error>?) in
            guard !delivered else { return (false, nil) }
            delivered = true
            if let c = continuation { continuation = nil; return (true, c) }
            result = r
            return (true, nil)
        }
        waiter?.resume(with: r)
        return won
    }

    /// Waits for the first delivery. Call once.
    func wait() async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, any Error>) in
            let ready = lock.withLock { () -> Result<T, any Error>? in
                if let r = result { result = nil; return r }
                continuation = c
                return nil
            }
            if let ready { c.resume(with: ready) }
        }
    }
}

/// Runs `operation` in its own task and returns its value, or nil once `timeout` passed.
///
/// Unlike a task group with a timer child, this returns at the deadline even when the operation ignores
/// cancellation: SpeechAnalyzer calls do (REVIEW M2), and a group always waits for all its children. At the
/// deadline the operation's task is cancelled when `cancelOnTimeout` is set, and may still run to its end in the
/// background, so release what it holds separately (e.g. `cancelAndFinishNow()`). Cancelling the caller throws
/// `CancellationError` at once.
func withDeadline<T: Sendable>(_ timeout: Duration, cancelOnTimeout: Bool = true,
                               _ operation: @escaping @Sendable () async throws -> T) async throws -> T? {
    let slot = RaceSlot<T?>()
    let work = Task {
        do { slot.fill(.success(try await operation())) } catch { slot.fill(.failure(error)) }
    }
    let timer = Task {
        do { try await Task.sleep(for: timeout) } catch { return }
        slot.fill(.success(nil))
    }
    defer { timer.cancel() }
    do {
        let value = try await withTaskCancellationHandler {
            try await slot.wait()
        } onCancel: {
            slot.fill(.failure(CancellationError()))
        }
        if value == nil, cancelOnTimeout { work.cancel() }
        return value
    } catch {
        work.cancel()
        throw error
    }
}
