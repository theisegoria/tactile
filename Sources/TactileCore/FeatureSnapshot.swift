// EXPERIMENTAL (gate 6): snapshots of every feature report, for diffing Edge
// profile switches and stick-module swaps.

public struct FeatureSnapshot: Sendable, Hashable, Codable {
    public var label: String
    /// Report ID → bytes (report ID first, CRC stripped).
    public var reports: [UInt8: [UInt8]]
    /// Report ID → error text for reports that could not be read.
    public var failures: [UInt8: String]

    public init(label: String, reports: [UInt8: [UInt8]] = [:], failures: [UInt8: String] = [:]) {
        self.label = label
        self.reports = reports
        self.failures = failures
    }
}

public struct FeatureDiff: Sendable, Hashable, Codable, CustomStringConvertible {
    public enum Change: String, Sendable, Codable { case added, removed, changed }

    public var reportID: UInt8
    public var change: Change
    /// Byte ranges that differ (for `.changed`).
    public var ranges: [Range<Int>]
    public var before: [UInt8]?
    public var after: [UInt8]?

    public var description: String {
        let id = "0x\(hexString(reportID, width: 2))"
        switch change {
        case .added: return "\(id) added (\(after?.count ?? 0) bytes)"
        case .removed: return "\(id) removed"
        case .changed:
            let spans = ranges.map { r -> String in
                let b = before.map { Array($0[r.clamped(to: 0..<$0.count)]).hexString } ?? ""
                let a = after.map { Array($0[r.clamped(to: 0..<$0.count)]).hexString } ?? ""
                return "  [\(r.lowerBound)..<\(r.upperBound)] \(b) → \(a)"
            }
            return "\(id) changed:\n" + spans.joined(separator: "\n")
        }
    }
}

extension FeatureSnapshot {
    /// Differences from `self` to `other`, by report ID.
    public func diff(to other: FeatureSnapshot) -> [FeatureDiff] {
        var out: [FeatureDiff] = []
        for id in Set(reports.keys).union(other.reports.keys).sorted() {
            switch (reports[id], other.reports[id]) {
            case (nil, let a?): out.append(FeatureDiff(reportID: id, change: .added, ranges: [], before: nil, after: a))
            case (let b?, nil): out.append(FeatureDiff(reportID: id, change: .removed, ranges: [], before: b, after: nil))
            case (let b?, let a?) where b != a:
                out.append(FeatureDiff(reportID: id, change: .changed, ranges: Self.changedRanges(b, a), before: b, after: a))
            default: break
            }
        }
        return out
    }

    /// Maximal runs of differing byte positions (length changes count as differing).
    static func changedRanges(_ a: [UInt8], _ b: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start: Int?
        for i in 0..<max(a.count, b.count) {
            let differs = i >= a.count || i >= b.count || a[i] != b[i]
            if differs, start == nil { start = i }
            if !differs, let s = start { ranges.append(s..<i); start = nil }
        }
        if let s = start { ranges.append(s..<max(a.count, b.count)) }
        return ranges
    }
}
