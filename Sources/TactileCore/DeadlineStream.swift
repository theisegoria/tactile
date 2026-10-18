/// Bounds a subscription by wall-clock duration and buffer size. The deadline
/// finishes the output independently of whether the upstream sends another item.
/// Owners must call cancel when they stop consuming before the stream ends.
package struct DeadlineStream<Element: Sendable>: Sendable {
    package let stream: AsyncThrowingStream<Element, any Error>
    private let continuation: AsyncThrowingStream<Element, any Error>.Continuation

    package init<S: AsyncSequence & Sendable>(_ source: S, duration: Duration, bufferingNewest: Int = 256)
    where S.Element == Element {
        let (stream, continuation) = AsyncThrowingStream<Element, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(max(1, bufferingNewest)))
        self.stream = stream
        self.continuation = continuation
        guard duration > .zero else { continuation.finish(); return }
        let producer = Task {
            do {
                for try await value in source {
                    try Task.checkCancellation()
                    if case .terminated = continuation.yield(value) { break }
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        let deadline = Task {
            do { try await Task.sleep(for: duration) } catch { return }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            producer.cancel()
            deadline.cancel()
        }
    }

    package func cancel() { continuation.finish() }
}
