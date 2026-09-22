// Lock-free single-producer / single-consumer ring buffer of Float samples.
// The producer may be an audio render callback; the consumer is the haptics pump.

import Synchronization

public final class SPSCRingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    public let capacity: Int
    private let readIndex = Atomic<Int>(0)   // owned by consumer
    private let writeIndex = Atomic<Int>(0)  // owned by producer
    /// Total samples ever written (producer-owned, monotonic).
    private let writeCount = Atomic<UInt64>(0)
    /// Total samples ever consumed (read or cleared). Consumer-only.
    private var readCount: UInt64 = 0
    /// `writeCount` snapshot of the latest `requestClear()`; everything written
    /// before it is dropped by the consumer on its next `applyPendingClear()`.
    private let clearTarget = Atomic<UInt64>(0)

    /// `capacity` samples; one slot is kept empty to distinguish full from empty.
    public init(capacity: Int) {
        self.capacity = max(capacity, 2) + 1
        storage = .allocate(capacity: self.capacity)
        storage.initialize(repeating: 0, count: self.capacity)
    }

    deinit { storage.deallocate() }

    public var availableToRead: Int {
        let w = writeIndex.load(ordering: .acquiring), r = readIndex.load(ordering: .relaxed)
        return w >= r ? w - r : w + capacity - r
    }

    public var availableToWrite: Int { capacity - 1 - availableToRead }

    /// Writes up to `samples.count`; returns the number written (drops the rest).
    @discardableResult
    public func write(_ samples: UnsafeBufferPointer<Float>) -> Int {
        let r = readIndex.load(ordering: .acquiring)
        var w = writeIndex.load(ordering: .relaxed)
        let free = (r > w ? r - w : r + capacity - w) - 1
        let n = min(free, samples.count)
        for i in 0..<n {
            storage[w] = samples[i]
            w += 1
            if w == capacity { w = 0 }
        }
        writeIndex.store(w, ordering: .releasing)
        writeCount.add(UInt64(n), ordering: .releasing)
        return n
    }

    @discardableResult
    public func write(_ samples: [Float]) -> Int {
        samples.withUnsafeBufferPointer { write($0) }
    }

    /// Reads up to `count` samples into `out`; returns the number read.
    public func read(into out: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let w = writeIndex.load(ordering: .acquiring)
        var r = readIndex.load(ordering: .relaxed)
        let avail = w >= r ? w - r : w + capacity - r
        let n = min(avail, count)
        for i in 0..<n {
            out[i] = storage[r]
            r += 1
            if r == capacity { r = 0 }
        }
        readIndex.store(r, ordering: .releasing)
        readCount &+= UInt64(n)
        return n
    }

    /// Drops everything currently buffered. **Consumer thread only**: `readIndex`
    /// has a single writer. Other threads use `requestClear()`.
    public func clear() {
        skip(availableToRead)
    }

    /// Asks the consumer to drop everything written so far. Callable from any
    /// thread; takes effect at the consumer's next `applyPendingClear()`.
    /// Samples written after this call are kept.
    public func requestClear() {
        let target = writeCount.load(ordering: .acquiring)
        var current = clearTarget.load(ordering: .relaxed)
        while current < target {
            let (exchanged, original) = clearTarget.compareExchange(
                expected: current, desired: target, ordering: .acquiringAndReleasing)
            if exchanged { break }
            current = original
        }
    }

    /// Performs a pending `requestClear()` (consumer thread only). Returns true
    /// if a clear was pending.
    @discardableResult
    public func applyPendingClear() -> Bool {
        let target = clearTarget.load(ordering: .acquiring)
        guard target > readCount else { return false }
        // Everything up to `target` has been published (writeCount is bumped
        // after writeIndex), so it is all within availableToRead.
        skip(Int(min(target - readCount, UInt64(availableToRead))))
        return true
    }

    private func skip(_ n: Int) {
        guard n > 0 else { return }
        var r = readIndex.load(ordering: .relaxed) + n
        if r >= capacity { r -= capacity }
        readIndex.store(r, ordering: .releasing)
        readCount &+= UInt64(n)
    }
}
