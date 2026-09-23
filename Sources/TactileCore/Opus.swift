// EXPERIMENTAL (gate 6): Opus packet inspection (RFC 6716 §3.1) and a
// heuristic scanner that looks for Opus packets inside unknown input reports,
// to locate the controller's microphone uplink (lead: Opus at 24 kHz, 🔬).

/// A decoded Opus TOC (table-of-contents) byte.
public struct OpusTOC: Sendable, Hashable, Codable, CustomStringConvertible {
    public enum Mode: String, Sendable, Codable { case silk, hybrid, celt }

    public var raw: UInt8
    public var config: Int { Int(raw >> 3) }
    public var stereo: Bool { raw & 0x04 != 0 }
    /// 0 = one frame, 1 = two equal frames, 2 = two different, 3 = arbitrary count.
    public var frameCountCode: Int { Int(raw & 0x03) }

    public init(_ raw: UInt8) { self.raw = raw }

    public var mode: Mode {
        switch config {
        case 0...11: .silk
        case 12...15: .hybrid
        default: .celt
        }
    }

    /// Audio bandwidth as a sample rate: 8, 12, 16, 24 or 48 kHz.
    public var bandwidthHz: Int {
        switch config {
        case 0...3, 16...19: 8000
        case 4...7: 12000
        case 8...11, 20...23: 16000
        case 12...13, 24...27: 24000
        default: 48000  // 14…15, 28…31
        }
    }

    /// Duration of one frame in microseconds.
    public var frameDurationMicros: Int {
        switch config {
        case 0...11: [10_000, 20_000, 40_000, 60_000][config % 4]
        case 12...15: [10_000, 20_000][config % 2]
        default: [2_500, 5_000, 10_000, 20_000][config % 4]
        }
    }

    public var description: String {
        "\(mode.rawValue) \(bandwidthHz / 1000) kHz \(Double(frameDurationMicros) / 1000) ms "
            + (stereo ? "stereo" : "mono") + " code \(frameCountCode)"
    }
}

/// A place in an input report that looks like the start of an Opus packet.
public struct UplinkCandidate: Sendable, Hashable, Codable, CustomStringConvertible {
    public var reportID: UInt8
    public var reportLength: Int
    public var tocOffset: Int
    /// Offset of a one-byte packet length directly before the TOC, when found.
    public var lengthOffset: Int?
    public var dominantTOC: OpusTOC
    /// Fraction (0…1) of sampled reports whose TOC byte equals the dominant one.
    public var confidence: Double
    public var samples: Int

    public var description: String {
        "report 0x\(hexString(reportID, width: 2)) (\(reportLength) B): TOC @\(tocOffset)"
            + (lengthOffset.map { ", length @\($0)" } ?? "")
            + " → \(dominantTOC) [\(Int(confidence * 100))% of \(samples)]"
    }
}

/// Collects raw input reports and ranks where an Opus stream might sit.
public struct UplinkScanner: Sendable {
    /// Report IDs whose layout is already known and never carry audio.
    public var ignoredReportIDs: Set<UInt8> = [0x01, 0x31]
    public var maxOffset = 24
    public var minSamples = 20
    /// Trailing bytes that are not payload (4 = Bluetooth CRC; 0 over USB).
    public var trailerBytes = 4
    private var byID: [UInt8: [[UInt8]]] = [:]
    private let cap = 400

    public init() {}

    public mutating func add(_ report: [UInt8]) {
        guard let id = report.first, !ignoredReportIDs.contains(id) else { return }
        var list = byID[id, default: []]
        if list.count < cap { list.append(report) }
        byID[id] = list
    }

    public var reportCounts: [UInt8: Int] { byID.mapValues(\.count) }

    /// Candidates ordered by confidence. A real Opus stream from one encoder keeps
    /// the same TOC byte (same mode, bandwidth, frame size, channels) packet after
    /// packet, while ordinary report fields vary or sit at zero.
    public func candidates() -> [UplinkCandidate] {
        var out: [UplinkCandidate] = []
        for (id, reports) in byID where reports.count >= minSamples {
            let len = reports.map(\.count).max() ?? 0
            for off in 1..<min(maxOffset, len) {
                var counts: [UInt8: Int] = [:]
                for r in reports where off < r.count { counts[r[off], default: 0] += 1 }
                guard let (toc, n) = counts.max(by: { $0.value < $1.value }), toc != 0, toc != 0xFF else { continue }
                let t = OpusTOC(toc)
                // Plausible for a controller mic: one or two frames of 10/20 ms.
                guard [10_000, 20_000].contains(t.frameDurationMicros), t.frameCountCode <= 1 else { continue }
                let confidence = Double(n) / Double(reports.count)
                guard confidence >= 0.8 else { continue }
                // The compressed bytes after the TOC must vary, or this is just a
                // constant field. Steady input repeats the first payload bytes, so
                // compare everything after the TOC. (Digital silence can produce
                // identical packets: make noise into the mic while scanning.)
                // The trailing four bytes are excluded: a Bluetooth CRC changes in
                // every report and would make any constant field look like audio.
                let following = Set(reports.map { r in
                    Array(r[min(off + 1, r.count)..<max(min(off + 1, r.count), r.count - trailerBytes)])
                })
                guard following.count > reports.count / 4 else { continue }
                var lengthOffset: Int?
                if off >= 1 {
                    let lens = reports.map { Int($0[off - 1]) }
                    let fits = lens.allSatisfy { $0 > 0 && off + $0 <= len }
                    if fits && Set(lens).count > 1 { lengthOffset = off - 1 }
                }
                out.append(UplinkCandidate(reportID: id, reportLength: len, tocOffset: off, lengthOffset: lengthOffset,
                                           dominantTOC: t, confidence: confidence, samples: reports.count))
            }
        }
        return out.sorted { ($0.confidence, $0.lengthOffset != nil ? 1 : 0) > ($1.confidence, $1.lengthOffset != nil ? 1 : 0) }
    }
}

/// Pulls Opus packets out of uplink reports once a candidate layout is chosen.
public struct UplinkExtractor: Sendable, Hashable, Codable {
    public var reportID: UInt8
    public var tocOffset: Int
    public var lengthOffset: Int?
    /// Bytes to drop from the end (the Bluetooth CRC).
    public var trailerBytes: Int

    public init(reportID: UInt8, tocOffset: Int, lengthOffset: Int?, trailerBytes: Int = 4) {
        self.reportID = reportID
        self.tocOffset = tocOffset
        self.lengthOffset = lengthOffset
        self.trailerBytes = trailerBytes
    }

    public init(_ c: UplinkCandidate, trailerBytes: Int = 4) {
        self.init(reportID: c.reportID, tocOffset: c.tocOffset, lengthOffset: c.lengthOffset, trailerBytes: trailerBytes)
    }

    /// The Opus packet in `report`, or nil if the report is not an uplink report.
    public func packet(from report: [UInt8]) -> [UInt8]? {
        guard report.first == reportID, tocOffset < report.count else { return nil }
        let end = max(tocOffset, report.count - trailerBytes)
        if let lo = lengthOffset, lo < report.count {
            let n = Int(report[lo])
            guard n > 0, tocOffset + n <= end else { return nil }
            return Array(report[tocOffset..<(tocOffset + n)])
        }
        // No length field: take everything up to the trailer, minus zero padding.
        var e = end
        while e > tocOffset + 1, report[e - 1] == 0 { e -= 1 }
        return Array(report[tocOffset..<e])
    }
}
