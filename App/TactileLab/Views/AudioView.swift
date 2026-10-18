import AppKit
import SwiftUI
import Tactile
import UniformTypeIdentifiers

struct AudioView: View {
    @Bindable var session: LabSession
    @State private var path = AudioOutputPath.speaker
    @State private var speakerVolume = 80.0
    @State private var headphoneVolume = 40.0
    @State private var micVolume = 32.0
    @State private var file: URL?
    @State private var gain = 1.0
    @State private var bitrate = 64000
    @State private var reportLength = 398
    @State private var payloadOffset = 2
    @State private var prefix = SpeakerAudioFraming.LengthPrefix.u8
    @State private var tag = 0
    @State private var highSequence = true
    @State private var candidate = -1
    @State private var micID = "35"
    @State private var tocOffset = 4
    @State private var lengthOffset = "3"
    @State private var trailer = 4
    @State private var rate = 24000.0
    @State private var channels = 1

    var body: some View {
        Form {
            Section {
                Label("Experimental audio over Bluetooth", systemImage: "flask").font(.headline)
                Text("Routing, speaker framing, and microphone uplink behavior require physical verification. Packet transmission and decoder output do not establish that sound was heard or recorded from the controller.").font(.callout).foregroundStyle(.secondary)
                DurationControl(session: session)
            }
            Section("Routing and volume") {
                Picker("Output route", selection: $path) {
                    Text("Internal speaker").tag(AudioOutputPath.speaker)
                    Text("Headphones").tag(AudioOutputPath.headphones)
                    Text("Left headphone").tag(AudioOutputPath.headphoneLeft)
                    Text("Left headphone + speaker").tag(AudioOutputPath.headphoneLeftAndSpeaker)
                }
                ValueSlider(title: "Speaker volume", value: $speakerVolume, range: 0...255)
                ValueSlider(title: "Headphone volume", value: $headphoneVolume, range: 0...127)
                ValueSlider(title: "Controller mic gain", value: $micVolume, range: 0...64)
                Button("Test Routing") { session.perform(.output(OutputState(audio: routing)), name: "Experimental routing", settings: routingDescription) }.disabled(!session.canOperate)
            }
            Section("Speaker playback") {
                HStack {
                    Button("Choose Audio File…") { file = AudioFiles.choose() }
                    Text(file?.lastPathComponent ?? "No file selected").foregroundStyle(.secondary)
                    Spacer()
                    Button("Play Speaker Test") { play() }.disabled(file == nil || !session.canOperate)
                }
                ValueSlider(title: "Playback gain", value: $gain, range: 0...4, precision: 2)
                HStack {
                    integer("Opus bitrate (6000–512000)", value: $bitrate)
                    integer("Report length (8–65535)", value: $reportLength)
                    Button("Use Descriptor") {
                        if let size = session.diagnostics.descriptor.first(where: { $0.kind == .output && $0.reportID == 0x36 })?.byteLength { reportLength = size }
                    }.disabled(!session.diagnostics.descriptor.contains(where: { $0.kind == .output && $0.reportID == 0x36 }))
                }
                DisclosureGroup("Framing controls · report 0x36") {
                    HStack {
                        integer("Payload offset", value: $payloadOffset)
                        integer("Tag (0–15)", value: $tag)
                        Picker("Length prefix", selection: $prefix) {
                            Text("None").tag(SpeakerAudioFraming.LengthPrefix.none)
                            Text("8-bit").tag(SpeakerAudioFraming.LengthPrefix.u8)
                            Text("16-bit little endian").tag(SpeakerAudioFraming.LengthPrefix.u16LittleEndian)
                        }
                    }
                    Toggle("Sequence in high nibble", isOn: $highSequence)
                    Text("Bluetooth CRC is always enabled. The full report must fit the selected layout; oversized encoded packets are dropped at their original playback time.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Controller microphone uplink") {
                HStack {
                    Button("Scan for Microphone") { session.perform(.scan, name: "Microphone scan", settings: "bounded raw-input scan; mic gain 64") }.disabled(!session.canOperate)
                    Text("Speak or tap near the controller while scanning.").font(.caption).foregroundStyle(.secondary)
                }
                Picker("Candidate layout", selection: $candidate) {
                    Text("Manual layout").tag(-1)
                    ForEach(Array(session.candidates.enumerated()), id: \.offset) { index, candidate in
                        Text("0x\(String(candidate.reportID, radix: 16)) · offset \(candidate.tocOffset) · \(candidate.confidence, format: .percent.precision(.fractionLength(0))) confidence").tag(index)
                    }
                }.onChange(of: candidate) { _, index in
                    guard session.candidates.indices.contains(index) else { return }
                    let value = session.candidates[index]
                    micID = String(value.reportID, radix: 16); tocOffset = value.tocOffset; lengthOffset = value.lengthOffset.map(String.init) ?? ""
                }
                HStack {
                    TextField("Report ID (hex)", text: $micID).textFieldStyle(.roundedBorder)
                    integer("TOC offset", value: $tocOffset)
                    TextField("Length offset (blank = remainder)", text: $lengthOffset).textFieldStyle(.roundedBorder)
                    integer("Trailer bytes", value: $trailer)
                }
                HStack {
                    Picker("Sample rate", selection: $rate) { ForEach([8000.0, 12000, 16000, 24000, 48000], id: \.self) { Text("\(Int($0)) Hz").tag($0) } }
                    Picker("Channels", selection: $channels) { Text("Mono").tag(1); Text("Stereo").tag(2) }
                    Button("Record WAV…") { record() }.disabled(!session.canOperate)
                }
                Text("Without a length field, trailing zeros are retained because they may belong to the Opus packet. A candidate remains unverified until you listen to its recording.").font(.caption).foregroundStyle(.secondary)
                ForEach(session.recordings, id: \.self) { path in
                    HStack { Text(URL(fileURLWithPath: path).lastPathComponent); Spacer(); Button("Reveal WAV") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
                }
            }
        }.formStyle(.grouped)
    }

    private var routing: AudioSettings { AudioSettings(headphoneVolume: UInt8(headphoneVolume), speakerVolume: UInt8(speakerVolume), micVolume: UInt8(micVolume), outputPath: path) }
    private var routingDescription: String { "route=\(path.rawValue); speaker=\(Int(speakerVolume)); headphones=\(Int(headphoneVolume)); mic=\(Int(micVolume))" }
    private func integer(_ label: String, value: Binding<Int>) -> some View {
        HStack { Text(label).font(.caption); TextField(label, value: value, format: .number).textFieldStyle(.roundedBorder).frame(width: 75) }
    }
    private func play() {
        guard let file else { return }
        do {
            guard (0...15).contains(tag), (6000...512000).contains(bitrate) else { throw LabError.invalid("Tag must be 0–15 and bitrate 6000–512000.") }
            var framing = SpeakerAudioFraming(reportLength: reportLength)
            framing.payloadOffset = payloadOffset; framing.tag = UInt8(tag); framing.lengthPrefix = prefix; framing.sequenceInHighNibble = highSequence
            guard framing.isValid, framing.maxPacketBytes > 0 else { throw LabError.invalid("Invalid speaker header, payload, length prefix or CRC layout.") }
            session.perform(.speaker(file, framing, bitrate, Float(gain), routing), name: "Experimental speaker", settings: "\(routingDescription); file=\(file.lastPathComponent); bytes=\(reportLength); offset=\(payloadOffset); prefix=\(prefix.rawValue); tag=\(tag); highSequence=\(highSequence); bitrate=\(bitrate); gain=\(gain)")
        } catch { session.showError(error) }
    }
    private func record() {
        do {
            guard let id = UInt8(micID.replacingOccurrences(of: "0x", with: ""), radix: 16), id > 0,
                  (1...65535).contains(tocOffset), (0...65535).contains(trailer) else { throw LabError.invalid("Enter a valid report ID, positive TOC offset and nonnegative trailer size.") }
            let length: Int?
            if lengthOffset.isEmpty { length = nil }
            else {
                guard let value = Int(lengthOffset), value >= 1, value < tocOffset else { throw LabError.invalid("Length offset must be before the TOC and after the report ID.") }
                length = value
            }
            let format = OpusStreamFormat(sampleRate: rate, channels: channels)
            try format.validate()
            let panel = NSSavePanel(); panel.allowedContentTypes = [.wav]; panel.nameFieldStringValue = "Tactile microphone.wav"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let extractor = UplinkExtractor(reportID: id, tocOffset: tocOffset, lengthOffset: length, trailerBytes: trailer)
            session.perform(.record(extractor, format, url), name: "Microphone recording", settings: "report=\(micID); toc=\(tocOffset); length=\(lengthOffset); trailer=\(trailer); rate=\(rate); channels=\(channels); output=\(url.lastPathComponent)")
        } catch { session.showError(error) }
    }
}
