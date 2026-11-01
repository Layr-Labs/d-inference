import Foundation
import Darwin

/// How `provider.toml` is replaced on disk.
enum ProviderConfigFile {
    /// Replaces the file with one rename of a fully written sibling, so a
    /// reader sees the old bytes or the new ones and a failure leaves the old
    /// file as it was.
    ///
    /// The file can hold credentials, and the cluster readers
    /// (`ClusterConfigurationFiles.read(_:maximum:privateMode:)`) refuse one
    /// that group or others can access. It is therefore written owner-only
    /// from its first save, an older group/world-readable file is tightened,
    /// and a stricter existing mode such as read-only is kept.
    static func replace(_ url: URL, with contents: Data) throws {
        let ownerOnly: mode_t = 0o600
        var existing = stat()
        let replacesRegularFile = lstat(url.path, &existing) == 0 && existing.st_mode & S_IFMT == S_IFREG
        let mode = replacesRegularFile ? existing.st_mode & ownerOnly : ownerOnly
        let staged = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.lowercased()).tmp")
        let descriptor = open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, ownerOnly)
        guard descriptor >= 0 else { throw posixError() }
        var renamed = false
        defer {
            close(descriptor)
            if !renamed { unlink(staged.path) }
        }
        try contents.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw posixError() }
                offset += written
            }
        }
        guard fchmod(descriptor, mode) == 0, fsync(descriptor) == 0, rename(staged.path, url.path) == 0 else {
            throw posixError()
        }
        renamed = true
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
