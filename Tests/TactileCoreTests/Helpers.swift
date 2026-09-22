import TactileCore

/// Parses a hex golden vector; traps in tests on malformed literals.
func hex(_ s: String) -> [UInt8] {
    guard let b = [UInt8](hex: s) else { fatalError("bad hex literal: \(s)") }
    return b
}
