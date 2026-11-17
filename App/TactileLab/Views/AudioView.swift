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
    @State private var bitrate = 160000
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LabScreenHeader(title: "Speaker & Audio",
                                detail: "Controller speaker, headphone jack and microphone over Bluetooth. Packets leaving the Mac do not show that sound was heard or recorded; every result here needs your ears.") {
                    LabTag(text: "Unverified on hardware", symbol: "flask")
                }
                NoControllerNotice(session: session)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        CapabilitiesCard(session: session).frame(minWidth: 380)
                        HeadsetStatusCard(readings: session.readings).frame(minWidth: 260, maxWidth: 360)
                    }
                    VStack(spacing: 16) {
                        CapabilitiesCard(session: session)
                        HeadsetStatusCard(readings: session.readings)
                    }
                }
                routingCard
                speakerCard
                microphoneCard
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: session.selectedID) { _, _ in candidate = -1 }
        .accessibilityIdentifier("audioView")
    }

    private var routingCard: some View {
        LabCard(title: "Routing and volume", symbol: "slider.horizontal.3",
                subtitle: "Controller audio settings (output report 0x31). The meaning of individual values is unverified.") {
            Button("Apply Routing", systemImage: "arrow.down.to.line") {
                session.perform(.output(OutputState(audio: routing)), name: "Experimental routing", settings: routingDescription)
            }
            .buttonStyle(.glass)
            .disabled(!session.canOperate)
            .accessibilityIdentifier("applyRouting")
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Output path", selection: $path) {
                    Text("Internal speaker").tag(AudioOutputPath.speaker)
                    Text("Headphones").tag(AudioOutputPath.headphones)
                    Text("Left headphone").tag(AudioOutputPath.headphoneLeft)
                    Text("Left headphone + speaker").tag(AudioOutputPath.headphoneLeftAndSpeaker)
                }
                .frame(maxWidth: 360)
                ValueSlider(title: "Speaker volume", value: $speakerVolume, range: 0...255)
                ValueSlider(title: "Headphone volume", value: $headphoneVolume, range: 0...127)
                ValueSlider(title: "Controller mic gain", value: $micVolume, range: 0...64)
            }
        }
    }

    private var speakerCard: some View {
        LabCard(title: "Speaker playback", symbol: "speaker.wave.2",
                subtitle: "Streams a file as Opus in report 0x36 at the selected path, bounded by the test length. In 0.3 the speaker shares the haptics stream; stats below come from it.") {
            Button("Play Speaker Test", systemImage: "play.fill") { play() }
                .buttonStyle(.glassProminent)
                .disabled(file == nil || !session.canOperate)
                .accessibilityIdentifier("playSpeaker")
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Choose Audio File…") { file = AudioFiles.choose() }.buttonStyle(.glass)
                    Text(file?.lastPathComponent ?? "No file selected").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                ValueSlider(title: "Playback gain", value: $gain, range: 0...4, precision: 2)
                StreamStatsView(session: session)
                    .padding(12)
                    .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 14))
                DisclosureGroup("Framing controls · report 0x36") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            integer("Opus bitrate (6000–512000)", value: $bitrate)
                            integer("Report length (8–65535)", value: $reportLength)
                            Button("Use Descriptor") {
                                if let size = session.diagnostics.descriptor.first(where: { $0.kind == .output && $0.reportID == 0x36 })?.byteLength { reportLength = size }
                            }.disabled(!session.diagnostics.descriptor.contains(where: { $0.kind == .output && $0.reportID == 0x36 }))
                        }
                        HStack {
                            integer("Payload offset", value: $payloadOffset)
                            integer("Tag (0–15)", value: $tag)
                            Picker("Length prefix", selection: $prefix) {
                                Text("None").tag(SpeakerAudioFraming.LengthPrefix.none)
                                Text("8-bit").tag(SpeakerAudioFraming.LengthPrefix.u8)
                                Text("16-bit little endian").tag(SpeakerAudioFraming.LengthPrefix.u16LittleEndian)
                            }.fixedSize()
                        }
                        Toggle("Sequence in high nibble", isOn: $highSequence)
                        Text("Bluetooth CRC is always enabled. Payload offset and prefix apply only to the research layout. The full report must fit; oversized encoded packets are dropped at their original playback time.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    private var microphoneCard: some View {
        LabCard(title: "Controller microphone uplink", symbol: "mic",
                subtitle: "A candidate layout remains unverified until you listen to its recording.") {
            Button("Scan for Microphone") { session.perform(.scan, name: "Microphone scan", settings: "bounded raw-input scan; mic gain 64") }
                .buttonStyle(.glass)
                .disabled(!session.canOperate)
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Speak or tap near the controller while scanning.").font(.caption).foregroundStyle(.secondary)
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
                    TextField("Report ID (hex)", text: $micID).textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
                    integer("TOC offset", value: $tocOffset)
                }
                HStack {
                    TextField("Length offset (blank = remainder)", text: $lengthOffset).textFieldStyle(.roundedBorder)
                    integer("Trailer bytes", value: $trailer)
                }
                HStack {
                    Picker("Sample rate", selection: $rate) { ForEach([8000.0, 12000, 16000, 24000, 48000], id: \.self) { Text("\(Int($0)) Hz").tag($0) } }.fixedSize()
                    Picker("Channels", selection: $channels) { Text("Mono").tag(1); Text("Stereo").tag(2) }.fixedSize()
                    Spacer(minLength: 0)
                    Button("Record WAV…") { record() }.buttonStyle(.glassProminent).disabled(!session.canOperate)
                }
                Text("Without a length field, trailing zeros are retained because they may belong to the Opus packet.").font(.caption).foregroundStyle(.secondary)
                ForEach(session.recordings, id: \.self) { path in
                    HStack { Text(URL(fileURLWithPath: path).lastPathComponent); Spacer(); Button("Reveal WAV") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
                }
            }
        }
    }

    private var routing: AudioSettings { AudioSettings(headphoneVolume: UInt8(headphoneVolume), speakerVolume: UInt8(speakerVolume), micVolume: UInt8(micVolume), outputPath: path) }
    private var routingDescription: String { "route=\(path.rawValue); speaker=\(Int(speakerVolume)); headphones=\(Int(headphoneVolume)); mic=\(Int(micVolume))" }
    private func integer(_ label: String, value: Binding<Int>) -> some View {
        HStack {
            Text(label).font(.caption)
            TextField(label, value: value, format: .number).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 75)
        }
    }
    private func play() {
        guard let file else { return }
        do {
            guard (0...15).contains(tag), (6000...512000).contains(bitrate) else { throw LabError.invalid("Tag must be 0–15 and bitrate 6000–512000.") }
            var framing = SpeakerAudioFraming(reportLength: reportLength)
            framing.payloadOffset = payloadOffset; framing.tag = UInt8(tag); framing.lengthPrefix = prefix; framing.sequenceInHighNibble = highSequence
            // Sub-packet layout (default): payload offset and prefix apply only to the research layout.
            framing.destination = path == .headphones ? .headphones : .speaker
            guard framing.isValid, framing.maxPacketBytes > 0 else { throw LabError.invalid("Invalid speaker header, payload, length prefix or CRC layout.") }
            session.perform(.speaker(file, framing, bitrate, Float(gain), routing), name: "Experimental speaker", settings: "\(routingDescription); layout=\(framing.layout.rawValue); file=\(file.lastPathComponent); bytes=\(reportLength); offset=\(payloadOffset); prefix=\(prefix.rawValue); tag=\(tag); highSequence=\(highSequence); bitrate=\(bitrate); gain=\(gain)")
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
