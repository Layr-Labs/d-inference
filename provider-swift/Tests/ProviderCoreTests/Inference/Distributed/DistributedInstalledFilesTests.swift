import Foundation
import Testing
@testable import ProviderCore

/// An installed input the member refuses names the file and the condition it failed, so an operator can act
/// (2026-10-12: a model folder hard-linked into another tool's cache refused every pair start with a generic message).
@Suite struct DistributedInstalledFilesTests {
    private func folder() throws -> URL {
        // The verifier opens every component without following links: use the real path (/var is a link),
        // which `resolvingSymlinksInPath()` would shorten back to /var.
        guard let real = realpath(NSTemporaryDirectory(), nil) else { throw POSIXError(.ENOENT) }
        defer { free(real) }
        let base = URL(fileURLWithPath: String(cString: real))
        let url = base.appendingPathComponent("installed-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }

    private func refusal(_ body: () throws -> Void) -> String {
        do { try body(); return "" } catch { return "\(error)" }
    }

    @Test func aHardLinkedInputIsRefusedWithItsNameAndLinkCount() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("model-00001-of-00002.safetensors")
        try Data("safe".utf8).write(to: file)
        let pin = ClusterConfigurationCodec.sha256(Data("safe".utf8))
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        _ = try DistributedInstalledFiles.verify(file, expectedSHA256: pin, maximumBytes: 4, deadline: deadline)
        #expect(link(file.path, root.appendingPathComponent("cache-link").path) == 0)
        let message = refusal {
            _ = try DistributedInstalledFiles.verify(file, expectedSHA256: pin, maximumBytes: 4, deadline: deadline)
        }
        #expect(message.contains("model-00001-of-00002.safetensors"))
        #expect(message.contains("has 2 hard links"))
    }

    @Test func eachUnsafeConditionHasItsOwnReason() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("worker")
        try Data("safe".utf8).write(to: file)
        var information = stat()
        #expect(stat(file.path, &information) == 0)
        #expect(DistributedInstalledFiles.unsafeReason(information, maximumBytes: 4, executable: false) == nil)
        #expect(DistributedInstalledFiles.unsafeReason(information, maximumBytes: 3, executable: false)?
            .contains("larger than its bound") == true)
        #expect(DistributedInstalledFiles.unsafeReason(information, maximumBytes: 4, executable: true) == "not executable")
        var shared = information; shared.st_mode |= 0o020
        #expect(DistributedInstalledFiles.unsafeReason(shared, maximumBytes: 4, executable: false) == "writable by group or others")
        var empty = information; empty.st_size = 0
        #expect(DistributedInstalledFiles.unsafeReason(empty, maximumBytes: 4, executable: false) == "empty")
        var directory = stat()
        #expect(stat(root.path, &directory) == 0)
        #expect(DistributedInstalledFiles.unsafeReason(directory, maximumBytes: 4, executable: false) == "not a regular file")
    }
}
