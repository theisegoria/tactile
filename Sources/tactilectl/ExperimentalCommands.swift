// EXPERIMENTAL (gate 6) commands: audio routing, speaker streaming, mic
// uplink discovery/recording, report-descriptor and feature-report research.

import Foundation
import Tactile

enum ExperimentalCommands {
    static let banner = "⚠︎ experimental (gate 6): based on unverified protocol facts"

    /// Value following `flag`, if present.
    static func option(_ a: [String], _ flag: String) -> String? {
        guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static func byte(_ a: [String], _ flag: String, max: Int = 255) throws -> UInt8? {
        guard let s = option(a, flag) else { return nil }
        let v = s.hasPrefix("0x") ? Int(s.dropFirst(2), radix: 16) : Int(s)
        guard let v, v >= 0, v <= max else { throw CLIError("\(flag) must be 0…\(max), got '\(s)'") }
        return UInt8(v)
    }

    static func positional(_ a: [String], valueFlags: Set<String>) -> [String] {
        var out: [String] = []
        var skip = false
        for x in a {
            if skip { skip = false; continue }
            if valueFlags.contains(x) { skip = true; continue }
            if x.hasPrefix("--") { continue }
            out.append(x)
        }
        return out
    }

    // MARK: descriptor

    static func descriptor(_ c: Controller) {
        let bytes = [UInt8](c.info.reportDescriptor)
        print("report descriptor: \(bytes.count) bytes")
        guard let d = c.reportDescriptor else {
            print("  (could not parse)")
            return
        }
        for kind in HIDReportKind.allCases {
            for r in d.reports(kind) { print("  \(r)\(r.isVendorDefined ? "  [vendor]" : "")") }
        }
    }

    // MARK: audio routing

    static func audio(_ c: Controller, _ a: [String]) async throws {
        print(banner)
        var s = AudioSettings()
        s.headphoneVolume = try byte(a, "--headphone", max: 0x7F)
        s.speakerVolume = try byte(a, "--speaker")
        s.micVolume = try byte(a, "--mic", max: 0x40)
        if let p = option(a, "--path") {
            let paths: [String: AudioOutputPath] = [
                "headphones": .headphones, "headphone-left": .headphoneLeft,
                "headphone-left-speaker": .headphoneLeftAndSpeaker, "speaker": .speaker,
            ]
            guard let path = paths[p] else { throw CLIError("--path must be one of \(paths.keys.sorted().joined(separator: ", "))") }
            s.outputPath = path
        }
        guard s != AudioSettings() else {
            throw CLIError("usage: audio [--headphone 0-127] [--speaker 0-255] [--mic 0-64] [--path headphones|headphone-left|headphone-left-speaker|speaker]")
        }
        try await c.setAudio(s)
        print("audio → \(s)")
    }

    // MARK: speaker

    static func speaker(_ c: Controller, _ a: [String]) async throws {
        print(banner)
        guard let path = positional(a, valueFlags: ["--gain", "--bitrate", "--report-length", "--speaker", "--path"]).first else {
            throw CLIError("usage: speaker <file> [--gain G] [--bitrate BPS] [--report-length N] [--speaker 0-255] [--path speaker|headphones]")
        }
        let gain = try option(a, "--gain").map { v -> Float in
            guard let g = Float(v), g.isFinite, g >= 0, g <= 8 else { throw CLIError("--gain must be 0…8") }
            return g
        } ?? 1
        let bitRate = try option(a, "--bitrate").map { v -> Int in
            guard let b = Int(v), b >= 6000, b <= 512_000 else { throw CLIError("--bitrate must be 6000…512000") }
            return b
        } ?? 96_000
        var framing = c.speakerFraming()
        if let n = option(a, "--report-length") {
            guard let len = Int(n), len >= 8, len <= 1024 else { throw CLIError("--report-length must be 8…1024") }
            framing = SpeakerAudioFraming(reportLength: len)
            framing?.crc = c.transport == .bluetooth
        }
        guard let framing else {
            throw CLIError("the descriptor declares no output report 0x36; pass --report-length to try anyway")
        }
        // Route to the speaker unless told otherwise.
        let routing = AudioSettings(speakerVolume: try byte(a, "--speaker") ?? 0xC0,
                                    outputPath: option(a, "--path") == "headphones" ? .headphones : .speaker)
        try await c.setAudio(routing)
        print("report 0x36: \(framing.reportLength) bytes, max Opus packet \(framing.maxPacketBytes) B, bitrate \(bitRate)")
        let stats = try await c.playSpeakerAudio(url: URL(fileURLWithPath: path), framing: framing, bitRate: bitRate, gain: gain)
        print(stats)
        if stats.packetsDroppedOversize > 0 { print("hint: lower --bitrate so packets fit the report") }
    }

    // MARK: microphone

    static func micScan(_ c: Controller, _ a: [String]) async throws -> UplinkCandidate? {
        print(banner)
        let seconds = try a.first.map { try Commands.parseSeconds($0, "mic-scan seconds") } ?? 5
        try? await c.setAudio(AudioSettings(micVolume: 0x40))
        print("scanning raw input for \(seconds) s — talk or tap near the controller's microphone…")
        let (candidates, counts) = await c.scanForMicUplink(duration: .milliseconds(Int(seconds * 1000)))
        print("unknown input report IDs: " + (counts.isEmpty ? "none" : counts.sorted { $0.key < $1.key }
            .map { "0x\(String($0.key, radix: 16)) ×\($0.value)" }.joined(separator: ", ")))
        if candidates.isEmpty {
            print("no Opus-looking stream found (try louder input, a longer scan, or --exclusive)")
        }
        for cand in candidates.prefix(5) { print("  \(cand)") }
        return candidates.first
    }

    static func micRecord(_ c: Controller, _ a: [String]) async throws {
        let pos = positional(a, valueFlags: ["--report", "--toc", "--length", "--rate", "--channels"])
        guard let out = pos.first else {
            throw CLIError("usage: mic-record <out.wav> [seconds] [--report 0xID --toc N [--length N]] [--rate 24000] [--channels 1]")
        }
        let seconds = try pos.dropFirst().first.map { try Commands.parseSeconds($0, "mic-record seconds") } ?? 10
        let extractor: UplinkExtractor
        if let rid = try byte(a, "--report"), let toc = option(a, "--toc").flatMap(Int.init) {
            extractor = UplinkExtractor(reportID: rid, tocOffset: toc, lengthOffset: option(a, "--length").flatMap(Int.init),
                                        trailerBytes: c.transport == .bluetooth ? 4 : 0)
        } else {
            guard let best = try await micScan(c, ["5"]) else { throw CLIError("no uplink found; pass --report/--toc explicitly") }
            extractor = UplinkExtractor(best, trailerBytes: c.transport == .bluetooth ? 4 : 0)
        }
        let rate = option(a, "--rate").flatMap(Double.init) ?? 24000
        let channels = option(a, "--channels").flatMap(Int.init) ?? 1
        print("recording \(seconds) s from report 0x\(String(extractor.reportID, radix: 16)) → \(out)")
        let stats = try await c.recordMicUplink(extractor: extractor, format: OpusStreamFormat(sampleRate: rate, channels: channels),
                                                to: URL(fileURLWithPath: out), duration: .milliseconds(Int(seconds * 1000)))
        print(stats)
    }

    // MARK: feature snapshots

    static func features(_ c: Controller, _ a: [String]) async throws {
        print(banner)
        let label = option(a, "--label") ?? "snapshot"
        let snap = await c.featureSnapshot(label: label)
        for (id, bytes) in snap.reports.sorted(by: { $0.key < $1.key }) {
            print("0x\(String(id, radix: 16)) (\(bytes.count) B): \(bytes.hexString)")
        }
        for (id, err) in snap.failures.sorted(by: { $0.key < $1.key }) { print("0x\(String(id, radix: 16)) failed: \(err)") }
        if let path = option(a, "--save") {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(snap).write(to: URL(fileURLWithPath: path))
            print("saved \(path)")
        }
    }

    static func featuresDiff(_ a: [String]) throws {
        guard a.count >= 2 else { throw CLIError("usage: features-diff <before.json> <after.json>") }
        let dec = JSONDecoder()
        let x = try dec.decode(FeatureSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: a[0])))
        let y = try dec.decode(FeatureSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: a[1])))
        let d = x.diff(to: y)
        print("\(x.label) → \(y.label): \(d.isEmpty ? "no differences" : "\(d.count) report(s) differ")")
        d.forEach { print($0) }
    }
}
