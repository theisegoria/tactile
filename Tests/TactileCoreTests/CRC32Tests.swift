import Testing
@testable import TactileCore

@Suite struct CRC32Tests {
    // Source: standard CRC-32/ISO-HDLC check value (catalogue of CRC algorithms).
    @Test func checkValue() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
    }

    // Source: zlib.crc32(b"\xa2") — tools/gen_vectors.py.
    @Test func outputPrefixSeed() {
        #expect(CRC32.checksum([0xA2]) == 0xEADA_2D49)
        #expect(CRC32(prefix: .output).value == 0xEADA_2D49)
    }

    @Test func sealAndVerifyRoundTrip() {
        var r = [UInt8](repeating: 0x5A, count: 78)
        CRC32.seal(&r, prefix: .output)
        #expect(CRC32.verify(r, prefix: .output))
        #expect(!CRC32.verify(r, prefix: .input))
        r[10] ^= 1
        #expect(!CRC32.verify(r, prefix: .output))
    }

    @Test func verifyRejectsShort() {
        #expect(!CRC32.verify([1, 2, 3, 4], prefix: .input))
    }
}
