import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Permission bits for the three files whose hashes identify an installed
/// provider release. Hashes bind bytes; this record also binds whether those
/// bytes can be executed and prevents chmod-only mutations during staging,
/// commit, recovery, and rollback.
struct UpdateArtifactModes: Equatable, Sendable {
    static let executableMask: UInt32 = 0o111

    let binary: UInt32
    let enclave: UInt32
    let metallib: UInt32

    init(binary: URL, enclave: URL, metallib: URL) throws {
        self.binary = try Self.regularFileMode(binary)
        self.enclave = try Self.regularFileMode(enclave)
        self.metallib = try Self.regularFileMode(metallib)
    }

    var nonExecutablePayload: String? {
        if binary & Self.executableMask == 0 {
            return "darkbloom"
        }
        if enclave & Self.executableMask == 0 {
            return "darkbloom-enclave"
        }
        return nil
    }

    func matches(_ record: InstalledReleaseRecord) -> Bool {
        switch (
            record.binaryMode,
            record.enclaveMode,
            record.metallibMode
        ) {
        case (nil, nil, nil):
            return true
        case let (.some(binary), .some(enclave), .some(metallib)):
            return self.binary == binary
                && self.enclave == enclave
                && self.metallib == metallib
        default:
            return false
        }
    }

    private static func regularFileMode(_ url: URL) throws -> UInt32 {
        let descriptor = open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw posixError("open \(url.path) for permission verification")
        }
        defer { _ = close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw posixError("inspect \(url.path) for permission verification")
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EINVAL),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "refuse non-regular release artifact at \(url.path)"
                ]
            )
        }
        return UInt32(status.st_mode & mode_t(0o7777))
    }

    private static func posixError(_ operation: String) -> Error {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\(operation): \(String(cString: strerror(code)))"
            ]
        )
    }
}
