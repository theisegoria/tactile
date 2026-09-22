// Float → signed 8-bit with TPDF dither.

/// Deterministic xorshift RNG so dithering is reproducible in tests.
public struct XorShift32: Sendable {
    private var s: UInt32
    public init(seed: UInt32 = 0x9E37_79B9) { s = seed == 0 ? 1 : seed }
    @inline(__always) public mutating func next() -> UInt32 {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5
        return s
    }
    /// Uniform in [-0.5, 0.5).
    @inline(__always) public mutating func unit() -> Float {
        Float(next() >> 8) / Float(1 << 24) - 0.5
    }
}

public struct Quantizer8: Sendable {
    public var dither: Bool
    private var rng: XorShift32

    public init(dither: Bool = true, seed: UInt32 = 0x9E37_79B9) {
        self.dither = dither
        rng = XorShift32(seed: seed)
    }

    /// Maps [-1, 1] to [-127, 127] (symmetric; -128 unused) with ±1 LSB TPDF dither.
    @inline(__always)
    public mutating func quantize(_ x: Float) -> Int8 {
        var v = x * 127
        if dither, x != 0 { v += rng.unit() + rng.unit() }
        v = v.rounded()
        if v > 127 { v = 127 }
        if v < -127 { v = -127 }
        return Int8(v)
    }
}
