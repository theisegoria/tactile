// Small bounds-checked little-endian helpers. Library code never force-unwraps
// or traps on short input; readers return nil instead.

@usableFromInline
struct ByteReader {
    @usableFromInline let bytes: [UInt8]
    @usableFromInline let base: Int

    @inlinable init(_ bytes: [UInt8], base: Int = 0) {
        self.bytes = bytes
        self.base = base
    }

    @inlinable func u8(_ offset: Int) -> UInt8? {
        let i = base + offset
        return i >= 0 && i < bytes.count ? bytes[i] : nil
    }

    @inlinable func u16(_ offset: Int) -> UInt16? {
        guard let lo = u8(offset), let hi = u8(offset + 1) else { return nil }
        return UInt16(lo) | UInt16(hi) << 8
    }

    @inlinable func i16(_ offset: Int) -> Int16? {
        u16(offset).map { Int16(bitPattern: $0) }
    }

    @inlinable func u32(_ offset: Int) -> UInt32? {
        guard let lo = u16(offset), let hi = u16(offset + 2) else { return nil }
        return UInt32(lo) | UInt32(hi) << 16
    }
}

extension Array where Element == UInt8 {
    /// Lowercase hex dump, space-separated.
    public var hexString: String {
        map { b in
            let s = String(b, radix: 16)
            return s.count == 1 ? "0" + s : s
        }.joined(separator: " ")
    }

    /// Parses "a1 b2 c3" or "a1b2c3" hex. Returns nil on malformed input.
    public init?(hex: String) {
        let cleaned = hex.filter { !$0.isWhitespace }
        guard cleaned.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(cleaned.count / 2)
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let b = UInt8(cleaned[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        self = out
    }
}
