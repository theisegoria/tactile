import Synchronization

/// A FIFO async mutex: `run` executes its bodies one at a time, in arrival
/// order, and keeps the gate held across suspension points inside the body.
/// Not reentrant: a body must never call `run` on the same gate.
final class AsyncGate: Sendable {
    private struct State {
        var busy = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    func run<T, E: Error>(_ body: () async throws(E) -> T) async throws(E) -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let proceed = state.withLock { s -> Bool in
                if s.busy {
                    s.waiters.append(cont)
                    return false
                }
                s.busy = true
                return true
            }
            if proceed { cont.resume() }
        }
    }

    private func release() {
        let next = state.withLock { s -> CheckedContinuation<Void, Never>? in
            guard !s.waiters.isEmpty else {
                s.busy = false
                return nil
            }
            // Ownership passes straight to the next waiter; `busy` stays set.
            return s.waiters.removeFirst()
        }
        next?.resume()
    }
}
