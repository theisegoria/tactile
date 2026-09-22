// Lock-free single-producer / single-consumer ring buffer of Float samples.
// The producer may be an audio render callback; the consumer is the haptics pump.

import Synchronization

public final class SPSCRingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    public let capacity: Int
    private let readIndex = Atomic<Int>(0)   // owned by consumer
    private let writeIndex = Atomic<Int>(0)  // owned by producer

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
        return n
    }

    /// Drops everything currently buffered (consumer side).
    public func clear() {
        readIndex.store(writeIndex.load(ordering: .acquiring), ordering: .releasing)
    }
}
