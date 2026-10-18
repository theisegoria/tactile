import TactileHaptics
import TactileTransport
import Synchronization

/// Bridges the pump thread to the async connection: reports are handed to a
/// serial sender task in order. The pump limits in-flight reports, so the
/// queue stays short.
final class ConnectionHapticsSink: HapticsReportSink, @unchecked Sendable {
    private let continuation: AsyncStream<([UInt8], @Sendable (Bool) -> Void)>.Continuation
    private let task: Task<Void, Never>
    private let closed = ClosedFlag()

    private final class ClosedFlag: Sendable {
        let value = Atomic<Bool>(false)
    }

    init(connection: DeviceConnection) {
        let (stream, cont) = AsyncStream<([UInt8], @Sendable (Bool) -> Void)>.makeStream()
        continuation = cont
        let closed = self.closed
        task = Task.detached(priority: .high) {
            for await (report, done) in stream {
                guard !closed.value.load(ordering: .acquiring) else { done(false); continue }
                do {
                    try await connection.sendHapticsReport(report)
                    done(true)
                } catch {
                    done(false)
                }
            }
        }
    }

    func submit(_ report: [UInt8], completion: @escaping @Sendable (Bool) -> Void) {
        if case .terminated = continuation.yield((report, completion)) { completion(false) }
    }

    func close() {
        closed.value.store(true, ordering: .releasing)
        // Drain queued completions without sending them. Cancelling the stream
        // would abandon those callbacks and permanently consume pump slots.
        continuation.finish()
    }
}
