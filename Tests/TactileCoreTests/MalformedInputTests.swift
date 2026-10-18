import Testing
@testable import TactileCore

@Suite struct MalformedInputTests {
    @Test func descriptorSizeOverflow() {
        #expect(throws: HIDDescriptor.ParseError.sizeOverflow(offset: 10)) {
            try HIDDescriptor(parsing: [0x77, 255, 255, 255, 255, 0x97, 255, 255, 255, 255, 0x81, 0])
        }
        #expect(throws: HIDDescriptor.ParseError.sizeOverflow(offset: 12)) {
            try HIDDescriptor(parsing: [0x77, 255, 255, 255, 255, 0x97, 255, 255, 255, 127, 0x81, 0, 0x81, 0])
        }
        let report = HIDReportInfo(kind: .input, reportID: 1, bitLength: .max, usagePage: nil)
        #expect(report.byteLength == Int.max / 8 + 2)
    }

    @Test func scannerMixedLengthsAndInvalidParameters() {
        var scanner = UplinkScanner()
        for i in 0..<19 { scanner.add([0x35, 0, 2, 0x60, UInt8(i), 0, 0, 0, 0]) }
        scanner.add([0x35])
        #expect(scanner.candidates().isEmpty)
        scanner.maxOffset = .min
        #expect(scanner.candidates().isEmpty)
        scanner.maxOffset = 20
        scanner.trailerBytes = -1
        #expect(scanner.candidates().isEmpty)
        for _ in 0..<500 { scanner.add([0x35]) }
        #expect(scanner.reportCounts[0x35] == 520)
    }

    @Test func extractorRejectsAllOutOfBoundsLayouts() {
        let report: [UInt8] = [0x35, 2, 0x60, 0, 0, 0, 0, 0]
        for offset in [Int.min, -1, 0, 4, 8, Int.max] {
            #expect(UplinkExtractor(reportID: 0x35, tocOffset: offset, lengthOffset: 1).packet(from: report) == nil)
        }
        for trailer in [Int.min, -1, 8, Int.max] {
            #expect(UplinkExtractor(reportID: 0x35, tocOffset: 2, lengthOffset: 1, trailerBytes: trailer).packet(from: report) == nil)
        }
        for length in [-1, 0, 2, 8, Int.max] {
            #expect(UplinkExtractor(reportID: 0x35, tocOffset: 2, lengthOffset: length).packet(from: report) == nil)
        }
        #expect(UplinkExtractor(reportID: 0x35, tocOffset: 2, lengthOffset: 1).packet(from: report) == [0x60, 0])
    }

    @Test func speakerValidatesWholeLayoutBeforeAllocation() {
        for length in [Int.min, -1, 0, 1, 2, 3, 4, 5, 6, 7, Int.max] {
            var framing = SpeakerAudioFraming(reportLength: length)
            framing.lengthPrefix = .u16LittleEndian
            var builder = SpeakerAudioReportBuilder(framing: framing)
            #expect(!framing.isValid)
            #expect(throws: SpeakerAudioReportBuilder.BuildError.self) { try builder.build(opusPacket: []) }
        }
        var f = SpeakerAudioFraming(reportLength: 400)
        #expect(f.maxPacketBytes == 255)
        var builder = SpeakerAudioReportBuilder(framing: f)
        #expect(throws: SpeakerAudioReportBuilder.BuildError.packetTooLarge(size: 256, max: 255)) {
            try builder.build(opusPacket: Array(repeating: 1, count: 256))
        }
        f.lengthPrefix = .u16LittleEndian
        f.reportLength = 65_535
        #expect(f.maxPacketBytes == 65_527)
        f.payloadOffset = .max
        #expect(!f.isValid && f.maxPacketBytes == 0)
    }

    @Test func CRCStrippingMustMatchDeclaredLength() throws {
        var report = [UInt8](repeating: 0, count: 41)
        report[0] = 5
        report[1] = 5
        CRC32.seal(&report, prefix: .feature)
        let payload = Array(report.dropLast(4))
        for input in [report, Array(report.dropFirst()), payload, Array(payload.dropFirst())] {
            #expect(try FeatureReportFraming.decode(input, reportID: 5, expectedLength: 41, transport: .bluetooth) == payload)
        }
        report[2] ^= 1
        #expect(throws: ParseError.badCRC(reportID: 5)) {
            try FeatureReportFraming.decode(report, reportID: 5, expectedLength: 41, transport: .bluetooth)
        }
        #expect(throws: ParseError.self) {
            try FeatureReportFraming.decode(Array(report.dropLast(2)), reportID: 5, expectedLength: 41, transport: .bluetooth)
        }
    }
}
