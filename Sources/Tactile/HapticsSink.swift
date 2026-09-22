import TactileHaptics
import TactileTransport

/// Bridges the pump thread to the async connection: reports are handed to a
/// serial sender task in order. The pump limits in-flight reports, so the
/// queue stays short.
final class ConnectionHapticsSink: HapticsReportSink, @unchecked Sendable {
    private let continuation: AsyncStream<([UInt8], @Sendable (Bool) -> Void)>.Continuation
    private let task: Task<Void, Never>

    init(connection: DeviceConnection) {
        let (stream, cont) = AsyncStream<([UInt8], @Sendable (Bool) -> Void)>.makeStream()
        continuation = cont
        task = Task.detached(priority: .high) {
            for await (report, done) in stream {
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
        continuation.yield((report, completion))
    }

    func close() {
        continuation.finish()
        task.cancel()
    }
}
