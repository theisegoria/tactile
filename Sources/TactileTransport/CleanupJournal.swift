public import Foundation

/// Crash-recovery journal. When a session sends non-neutral output (rumble,
/// trigger effects, a custom lightbar) it records the controller here; a clean
/// shutdown removes the record. If the process crashes, the next session that
/// opens the controller finds the record and sends the neutral state first.
public struct CleanupJournal: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base.appendingPathComponent("Tactile/dirty", isDirectory: true)
        }
    }

    private func file(for key: String) -> URL {
        let safe = key.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return directory.appendingPathComponent(safe.isEmpty ? "unknown" : safe)
    }

    public func markDirty(_ key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let f = file(for: key)
        if !FileManager.default.fileExists(atPath: f.path) {
            try? Data("\(getpid())".utf8).write(to: f, options: .atomic)
        }
    }

    public func markClean(_ key: String) {
        try? FileManager.default.removeItem(at: file(for: key))
    }

    public func isDirty(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: file(for: key).path)
    }
}
