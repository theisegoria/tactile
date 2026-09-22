// Normalisation of feature reports across transports.

public enum FeatureReportFraming {
    /// Bluetooth feature reports carry a trailing CRC-32 seeded with 0xA3.
    /// Verifies and strips it. On USB the bytes are returned unchanged.
    ///
    /// - Parameter bytes: report with the report ID at index 0.
    public static func unwrap(_ bytes: [UInt8], transport: Transport, verifyCRC: Bool = true) throws(ParseError) -> [UInt8] {
        guard let id = bytes.first else { throw .empty }
        guard transport == .bluetooth else { return bytes }
        guard bytes.count > 5 else { throw .tooShort(reportID: id, expected: 6, actual: bytes.count) }
        if verifyCRC, !CRC32.verify(bytes, prefix: .feature) { throw .badCRC(reportID: id) }
        return Array(bytes.dropLast(4))
    }

    /// Ensures a report buffer returned by a HID API starts with its report ID.
    /// Some APIs strip the ID byte for numbered reports.
    public static func normalize(_ bytes: [UInt8], reportID: UInt8, expectedLength: Int?) -> [UInt8] {
        if bytes.first == reportID, expectedLength.map({ bytes.count >= $0 }) ?? true { return bytes }
        if let n = expectedLength, bytes.count == n - 1 { return [reportID] + bytes }
        if bytes.first == reportID { return bytes }
        return [reportID] + bytes
    }
}
