/// Purger for the retired telemetry disk queue.
///
/// Older provider builds wrote free-form events to
/// `~/.darkbloom/telemetry-queue.jsonl`. This type only removes the two exact
/// legacy queue artifacts; nothing writes the queue any more.

import Foundation

public final class TelemetryOverflowQueue: @unchecked Sendable {
    public static let shared = TelemetryOverflowQueue()

    private let path: URL
    private let lock = NSLock()

    public init(path: URL? = nil) {
        if let path {
            self.path = path
        } else {
            self.path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".darkbloom")
                .appendingPathComponent("telemetry-queue.jsonl")
        }
    }

    /// Removes data persisted by an older build without creating a directory,
    /// lock file, or replacement artifact when nothing exists. Only regular
    /// files at the two exact historical paths are eligible: symlinks,
    /// directories, devices, and other non-regular entries are left untouched.
    /// Removal remains best-effort so housekeeping cannot prevent serving.
    public func purge() {
        lock.lock()
        defer { lock.unlock() }

        removeLegacyArtifactIfRegular(at: path)
        removeLegacyArtifactIfRegular(at: path.appendingPathExtension("tmp"))
    }

    private func removeLegacyArtifactIfRegular(at artifact: URL) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard
            let values = try? artifact.resourceValues(forKeys: keys),
            values.isRegularFile == true,
            values.isSymbolicLink != true
        else { return }
        try? FileManager.default.removeItem(at: artifact)
    }
}
