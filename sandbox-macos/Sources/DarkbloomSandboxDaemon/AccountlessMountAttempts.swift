import Darwin
import Foundation
import SandboxRuntime

/// Bounded, ordered attempts. Only the last attempt may be incomplete; every
/// earlier attempt must retain its immutable completion observation.
final class AccountlessMountAttempts {
    private let directory: URL
    private let descriptor: Int32
    private let maintenanceSHA256: String

    init(directory: URL, maintenanceSHA256: String) throws {
        self.directory = directory; self.maintenanceSHA256 = maintenanceSHA256
        descriptor = try SandboxAuthorityFileSystem.openPrivateDirectory(at: directory, createIfMissing: false)
    }
    deinit { close(descriptor) }

    func existing() throws -> [AccountlessMountAttempt] {
        try validate()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        guard names.count <= 16, names == names.indices.map({ String(format: "%04d", $0 + 1) }) else {
            throw AccountlessDiskError.bindingChanged
        }
        let attempts = try names.map { try AccountlessMountAttempt(directory: directory.appendingPathComponent($0),
            maintenanceSHA256: maintenanceSHA256) }
        for attempt in attempts.dropLast() {
            guard try attempt.completion() != nil else { throw AccountlessDiskError.bindingChanged }
        }
        try validate()
        return attempts
    }

    func create() throws -> AccountlessMountAttempt {
        let previous = try existing()
        guard previous.count < 16, try previous.last?.completion() != nil || previous.isEmpty else {
            throw AccountlessDiskError.bindingChanged
        }
        let name = String(format: "%04d", previous.count + 1)
        guard mkdirat(descriptor, name, 0o700) == 0 else { throw AccountlessDiskError.bindingChanged }
        try SandboxAuthorityFileSystem.synchronize(descriptor)
        try validate()
        return try .init(directory: directory.appendingPathComponent(name), maintenanceSHA256: maintenanceSHA256)
    }

    private func validate() throws {
        let current = try SandboxAuthorityFileSystem.openPrivateDirectory(at: directory, createIfMissing: false)
        defer { close(current) }
        guard try SandboxAuthorityFileSystem.sameIdentity(SandboxAuthorityFileSystem.fileMetadata(descriptor),
            SandboxAuthorityFileSystem.fileMetadata(current)) else { throw AccountlessDiskError.bindingChanged }
    }
}
