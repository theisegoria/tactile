// EXPERIMENTAL (gate 6): speaker/headphone/mic audio and Edge profile
// research. Everything here rests on unverified protocol facts; see
// PROTOCOL.md §Gate 6 and docs/receipts/gate-6.md. APIs may change or vanish.

public import Foundation
public import TactileAudio
public import TactileCore
public import TactileTransport

extension Controller {
    /// The controller's own report descriptor, parsed.
    public var reportDescriptor: HIDDescriptor? {
        try? HIDDescriptor(parsing: [UInt8](info.reportDescriptor))
    }

    // MARK: Audio routing and volume

    /// Sets headphone/speaker/mic volume and the output path (0x31 bytes 4–7). 🔬
    public func setAudio(_ settings: AudioSettings) async throws(TransportError) {
        try await apply(OutputState(audio: settings))
    }

    // MARK: Speaker audio (report 0x36, 🔬)

    /// Framing for report 0x36 sized from this controller's descriptor, or nil
    /// if the descriptor declares no such output report.
    public func speakerFraming() -> SpeakerAudioFraming? {
        guard let r = reportDescriptor?.report(.output, id: 0x36) else { return nil }
        var f = SpeakerAudioFraming(reportLength: r.byteLength)
        f.crc = transport == .bluetooth
        return f
    }

    /// Haptics framing with the 0x32 length from this controller's descriptor
    /// when it declares one; the documented defaults otherwise.
    public func hapticsFraming() -> HapticsFraming {
        var f = HapticsFraming.documented
        if let r = reportDescriptor?.report(.output, id: HapticsFormat.reportID) { f.reportLength = r.byteLength }
        return f
    }

    /// Attaches a speaker stream to the haptics pump (Bluetooth): while
    /// `source` has audio, each 10.667 ms tick sends report 0x36 with the
    /// haptics and one audio frame. Starts haptics if they are not running.
    /// Pass nil to detach. The attachment survives reconnects.
    public func attachSpeaker(_ source: (any SpeakerPacketSource)?, framing: SpeakerAudioFraming? = nil) async throws(TransportError) {
        guard let source else {
            setSpeakerSource(nil, framing: nil)
            return
        }
        guard transport == .bluetooth else {
            throw .notSupported("USB speaker audio goes through the controller's USB audio device")
        }
        guard let f = framing ?? speakerFraming(), f.layout == .subPackets, f.maxPacketBytes > 0 else {
            throw .notSupported("the report descriptor declares no usable output report 0x36")
        }
        setSpeakerSource(source, framing: f)
        if !hapticsRunning { try await startHaptics(framing: hapticsFraming()) }
    }

    /// Detaches `source` if it is still the attached speaker stream.
    public func detachSpeaker(ifAttached source: any SpeakerPacketSource) async {
        clearSpeakerSource(ifIdenticalTo: source)
    }

    /// Streams an audio file to the controller as Opus in report 0x36 (Bluetooth).
    /// Route it first with `setAudio(AudioSettings(speakerVolume:outputPath:))`.
    public func playSpeakerAudio(url: URL, framing: SpeakerAudioFraming? = nil, bitRate: Int = SpeakerAudioFraming.opusBitRate,
                                 gain: Float = 1) async throws -> SpeakerStreamStats {
        guard let c = connection else { throw TransportError.deviceUnavailable }
        guard let f = framing ?? speakerFraming() else {
            throw TransportError.notSupported("the report descriptor declares no output report 0x36; pass a framing explicitly")
        }
        let stream = SpeakerStream(framing: f, bitRate: bitRate) { report in
            try await c.sendExperimentalOutputReport(report)
        }
        return try await stream.play(url: url, gain: gain)
    }

    // MARK: Raw input and microphone uplink (🔬)

    /// Every input report as received, including unknown report IDs.
    public func rawInputReports() async -> AsyncStream<RawInputReport> {
        guard let c = connection else { return AsyncStream { $0.finish() } }
        return await c.rawInputReports()
    }

    /// Collects raw input for `duration` and ranks places that look like an Opus
    /// stream. Talk or tap near the controller's microphone while it runs.
    public func scanForMicUplink(duration: Duration = .seconds(5)) async -> (candidates: [UplinkCandidate], counts: [UInt8: Int]) {
        var scanner = UplinkScanner()
        scanner.trailerBytes = transport == .bluetooth ? 4 : 0
        let reports = await rawInputReports()
        let bounded = DeadlineStream(reports, duration: duration)
        defer { bounded.cancel() }
        do {
            for try await r in bounded.stream { scanner.add(r.bytes) }
        } catch { /* A scan returns the observations collected before cancellation. */ }
        return (scanner.candidates(), scanner.reportCounts)
    }

    /// Records the microphone uplink to a WAV file using a layout found by
    /// `scanForMicUplink`.
    public func recordMicUplink(extractor: UplinkExtractor, format: OpusStreamFormat = .microphone,
                                to url: URL, duration: Duration) async throws -> MicUplinkStats {
        let decoder = try MicUplinkDecoder(extractor: extractor, format: format)
        let raw = await rawInputReports()
        let bytes = AsyncStream<[UInt8]>(bufferingPolicy: .bufferingNewest(256)) { cont in
            let t = Task {
                for await r in raw { cont.yield(r.bytes) }
                cont.finish()
            }
            cont.onTermination = { _ in t.cancel() }
        }
        return try await decoder.record(reports: bytes, to: url, duration: duration)
    }

    // MARK: Feature-report snapshots (Edge profiles, stick modules)

    /// Reads every feature report the descriptor declares. Read-only: no
    /// feature report is ever written.
    public func featureSnapshot(label: String) async -> FeatureSnapshot {
        var snap = FeatureSnapshot(label: label)
        guard let c = connection, let d = reportDescriptor else {
            snap.failures[0] = "not connected or descriptor unparsable"
            return snap
        }
        for r in d.reports(.feature) where r.reportID != 0 {
            guard !Task.isCancelled else { break }
            do {
                snap.reports[r.reportID] = try await c.getFeatureReport(r.reportID, length: r.byteLength)
            } catch {
                snap.failures[r.reportID] = "\(error)"
            }
        }
        return snap
    }
}
