import Testing
@testable import TactileCore

// Gate 6 (experimental). Vectors are hand-built from the stated facts; none
// are device captures.

@Suite struct AudioSettingsTests {
    let builder = OutputReportBuilder(features: FeatureSet(vibrationV2: true, hasEdgeButtons: false))

    @Test func encodesFlagsAndBytes() {
        let c = builder.encodeCommon(OutputState(audio: AudioSettings(
            headphoneVolume: 0x50, speakerVolume: 0xC0, micVolume: 0x20, outputPath: .speaker)))
        #expect(c[OutputLayout.validFlag0] == 0xF0)
        #expect(Array(c[4...7]) == [0x50, 0xC0, 0x20, 0x30])
        #expect(c[OutputLayout.validFlag1] == 0)
    }

    @Test func clampsRangesAndLeavesUncontrolledFlagsClear() {
        let c = builder.encodeCommon(OutputState(audio: AudioSettings(headphoneVolume: 0xFF, micVolume: 0xFF)))
        #expect(c[OutputLayout.validFlag0] == OutputLayout.flag0HeadphoneVolume | OutputLayout.flag0MicVolume)
        #expect(c[4] == 0x7F && c[6] == 0x40)
        #expect(c[5] == 0 && c[7] == 0)
    }

    @Test func outputPathBitsDoNotClobberExtraBits() {
        let a = AudioSettings(outputPath: .headphoneLeftAndSpeaker, audioControlExtraBits: 0x31)
        #expect(a.audioControlByte == 0x21)
    }

    @Test func mergingKeepsEarlierFields() {
        let s = OutputState(audio: AudioSettings(speakerVolume: 10))
            .merging(OutputState(audio: AudioSettings(outputPath: .headphones)))
        #expect(s.audio?.speakerVolume == 10)
        #expect(s.audio?.outputPath == .headphones)
    }
}

@Suite struct HIDDescriptorTests {
    // Usage page generic desktop, gamepad collection; report 0x01 input
    // 8 bytes; report 0x31 output 77 bytes; report 0x36 output 397 bytes
    // (vendor page, 16-bit count); report 0x05 feature 40 bytes; push/pop.
    let descriptor = hex("""
        05 01 09 05 a1 01
        85 01 75 08 95 08 81 02
        06 00 ff
        85 31 95 4d 91 02
        a4 85 36 96 8d 01 91 02 b4
        85 05 95 28 b1 02
        c0
        """)

    @Test func sizes() throws {
        let d = try HIDDescriptor(parsing: descriptor)
        #expect(d.report(.input, id: 0x01)?.byteLength == 9)
        #expect(d.report(.output, id: 0x31)?.byteLength == 78)
        #expect(d.report(.output, id: 0x36)?.byteLength == 398)
        #expect(d.report(.feature, id: 0x05)?.byteLength == 41)
        #expect(d.report(.output, id: 0x36)?.isVendorDefined == true)
        #expect(d.report(.input, id: 0x01)?.isVendorDefined == false)
        #expect(d.reports(.output).map(\.reportID) == [0x31, 0x36])
    }

    @Test func truncatedAndBadPop() {
        #expect(throws: HIDDescriptor.ParseError.truncated(offset: 0)) { try HIDDescriptor(parsing: [0x96, 0x01]) }
        #expect(throws: HIDDescriptor.ParseError.popWithoutPush(offset: 0)) { try HIDDescriptor(parsing: [0xB4]) }
    }

    @Test func longItemsSkipped() throws {
        let d = try HIDDescriptor(parsing: [0xFE, 0x02, 0x10, 0xAA, 0xBB, 0x85, 0x02, 0x75, 0x08, 0x95, 0x02, 0xB1, 0x02])
        #expect(d.report(.feature, id: 0x02)?.byteLength == 3)
    }
}

@Suite struct SpeakerAudioReportTests {
    @Test func framesPacketWithLengthAndCRC() throws {
        var b = SpeakerAudioReportBuilder(framing: SpeakerAudioFraming(reportLength: 32))
        let r = try b.build(opusPacket: [0xF4, 0xAA, 0xBB])
        #expect(r.count == 32)
        #expect(Array(r[0...5]) == [0x36, 0x00, 0x03, 0xF4, 0xAA, 0xBB])
        #expect(r[6..<28].allSatisfy { $0 == 0 })
        #expect(CRC32.verify(r, prefix: .output))
        let r2 = try b.build(opusPacket: [0xF4])
        #expect(r2[1] == 0x10)
    }

    @Test func variants() throws {
        var f = SpeakerAudioFraming(reportLength: 16)
        f.lengthPrefix = .u16LittleEndian
        f.crc = false
        f.sequenceInHighNibble = false
        f.tag = 0x5
        var b = SpeakerAudioReportBuilder(framing: f)
        let r = try b.build(opusPacket: [1, 2])
        #expect(Array(r[0...5]) == [0x36, 0x50, 0x02, 0x00, 1, 2])
        #expect(f.maxPacketBytes == 12)
    }

    @Test func rejectsOversizeAndBadFraming() {
        var b = SpeakerAudioReportBuilder(framing: SpeakerAudioFraming(reportLength: 10))
        #expect(throws: SpeakerAudioReportBuilder.BuildError.packetTooLarge(size: 4, max: 3)) {
            try b.build(opusPacket: [1, 2, 3, 4])
        }
        var tiny = SpeakerAudioReportBuilder(framing: SpeakerAudioFraming(reportLength: 3))
        #expect(throws: SpeakerAudioReportBuilder.BuildError.self) { try tiny.build(opusPacket: []) }
    }
}

@Suite struct OpusTests {
    // TOC bytes observed from macOS's own Opus encoder: 48 kHz stereo 10 ms
    // produced 0xF4; 24 kHz mono produced 0x60.
    @Test func tocDecoding() {
        let celt = OpusTOC(0xF4)
        #expect(celt.config == 30 && celt.mode == .celt && celt.bandwidthHz == 48000)
        #expect(celt.frameDurationMicros == 10_000 && celt.stereo && celt.frameCountCode == 0)
        let hybrid = OpusTOC(0x60)
        #expect(hybrid.mode == .hybrid && hybrid.bandwidthHz == 24000 && hybrid.frameDurationMicros == 10_000 && !hybrid.stereo)
        let silk = OpusTOC(0x08)
        #expect(silk.mode == .silk && silk.bandwidthHz == 8000 && silk.frameDurationMicros == 20_000)
        #expect(OpusTOC(0x83).frameDurationMicros == 2_500)
    }

    /// Synthetic uplink: report 0x35, byte 1 counter, byte 3 length, byte 4 TOC
    /// 0x60 (24 kHz hybrid mono 10 ms), then pseudo-random payload.
    func uplinkReports(_ n: Int) -> [[UInt8]] {
        var rng = UInt32(7)
        func next() -> UInt8 { rng = rng &* 1_103_515_245 &+ 12345; return UInt8(truncatingIfNeeded: rng >> 16) }
        return (0..<n).map { k in
            var r = [UInt8](repeating: 0, count: 64)
            r[0] = 0x35
            r[1] = UInt8(k & 0xFF)
            let len = 30 + Int(next() % 20)
            r[3] = UInt8(len)
            r[4] = 0x60
            for i in 5..<(4 + len) { r[i] = next() }
            return r
        }
    }

    @Test func scannerFindsUplinkAndLengthField() throws {
        var s = UplinkScanner()
        for r in uplinkReports(100) { s.add(r) }
        // Known reports are ignored; a constant non-audio report is not a candidate.
        for _ in 0..<100 { s.add([0x31] + [UInt8](repeating: 0x60, count: 77)) }
        for _ in 0..<100 { s.add([0x40, 0x60, 0x60, 0x60]) }
        let c = s.candidates()
        let best = try #require(c.first)
        #expect(best.reportID == 0x35 && best.tocOffset == 4 && best.lengthOffset == 3)
        #expect(best.dominantTOC == OpusTOC(0x60))
        #expect(!c.contains { $0.reportID == 0x40 || $0.reportID == 0x31 })
        #expect(s.reportCounts[0x31] == nil)
    }

    @Test func extractor() {
        let r = uplinkReports(1)[0]
        let e = UplinkExtractor(reportID: 0x35, tocOffset: 4, lengthOffset: 3)
        let p = e.packet(from: r)
        #expect(p?.count == Int(r[3]) && p?.first == 0x60)
        #expect(e.packet(from: [0x31, 0, 0]) == nil)
        var bad = r
        bad[3] = 200
        #expect(e.packet(from: bad) == nil)
        let noLen = UplinkExtractor(reportID: 0x35, tocOffset: 4, lengthOffset: nil, trailerBytes: 0)
        #expect(noLen.packet(from: [0x35, 0, 0, 0, 0x60, 1, 2, 0, 0]) == [0x60, 1, 2])
    }
}

@Suite struct FeatureSnapshotTests {
    @Test func diff() {
        let a = FeatureSnapshot(label: "profile 1", reports: [0x20: [0x20, 1, 2, 3, 4], 0x60: [0x60, 9], 0x61: [0x61]])
        let b = FeatureSnapshot(label: "profile 2", reports: [0x20: [0x20, 1, 9, 9, 4, 5], 0x60: [0x60, 9], 0x62: [0x62]])
        let d = a.diff(to: b)
        #expect(d.map(\.reportID) == [0x20, 0x61, 0x62])
        #expect(d[0].change == .changed && d[0].ranges == [2..<4, 5..<6])
        #expect(d[1].change == .removed && d[2].change == .added)
        #expect(d[0].description.contains("02 03 → 09 09"))
    }
}
