import Testing
@testable import tactilectl

@Suite struct ArgumentTests {
    @Test func rejectsMalformedMicArgumentsBeforeDiscovery() {
        for args in [
            ["out.wav", "--channels", "0"], ["out.wav", "--rate", "nan"],
            ["out.wav", "--report", "0x35"], ["out.wav", "--toc", "-1"],
            ["out.wav", "--report", "0x35", "--toc", "4", "--length", "4"],
            ["out.wav", "--channels"], ["out.wav", "--rate", "no"],
            ["out.wav", "--rate", "24000", "--rate", "48000"]
        ] {
            #expect(throws: (any Error).self) { try ExperimentalCommands.validate("mic-record", args) }
        }
    }
    @Test func rejectsSpeakerRoutingTyposAndMissingValues() {
        for args in [["a.wav", "--path", "speker"], ["a.wav", "--bitrate"], ["a.wav", "--gain", "nan"]] {
            #expect(throws: (any Error).self) { try ExperimentalCommands.validate("speaker", args) }
        }
    }
    @Test func validExplicitMicLayout() throws {
        let args = ["out.wav", "2", "--report", "0x35", "--toc", "4", "--length", "3", "--rate", "24000", "--channels", "1"]
        try ExperimentalCommands.validate("mic-record", args)
        #expect(try ExperimentalCommands.uplinkLayout(args, trailerBytes: 4)?.tocOffset == 4)
    }
}
