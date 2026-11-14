import Darwin
import Foundation
import Security

@_silgen_name("csops")
private func csops(_ pid: pid_t, _ operation: UInt32, _ buffer: UnsafeMutableRawPointer?, _ size: Int) -> Int32

/// Binds a launched child to the executable bytes that were verified.
///
/// A file is verified by path and then executed by path, so the same user
/// could replace it in between. The kernel fixes the image's CodeDirectory at
/// exec and enforces it page by page, so a child whose running cdhash is one
/// derived from the verified bytes runs exactly those bytes. Launchers call
/// this with the child's process identifier after the spawn and before the
/// first byte goes to its input; a refusal kills the child.
enum DistributedInstalledLaunchImage {
    static func verifier(expected: Set<Data>) throws -> @Sendable (pid_t) throws -> Void {
        guard !expected.isEmpty else {
            throw ClusterConfigurationError.invalid("The installed executable has no code signature to launch")
        }
        return { pid in try require(pid: pid, expected: expected) }
    }

    /// The child is ours and not yet reaped, so its process identifier still
    /// names it. Code Signing Services must find it valid, and both the
    /// kernel's cdhash of the running image (`CS_OPS_CDHASH`) and the one
    /// Code Signing Services reports must be expected. The kernel's own value
    /// is required because the reported one is read from the file on disk.
    static func require(pid: pid_t, expected: Set<Data>) throws {
        var code: SecCode?
        var information: CFDictionary?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary,
                                             [], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopySigningInformation(unsafeBitCast(code, to: SecStaticCode.self),
                                            SecCSFlags(rawValue: kSecCSDynamicInformation), &information) == errSecSuccess,
              let reported = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              expected.contains(reported), let running = kernelHash(pid), expected.contains(running) else {
            throw ClusterConfigurationError.invalid("The launched executable is not the verified installed one")
        }
    }

    private static func kernelHash(_ pid: pid_t) -> Data? {
        var hash = [UInt8](repeating: 0, count: DistributedInstalledCodeDirectory.hashBytes)
        // CS_OPS_CDHASH
        guard csops(pid, 5, &hash, hash.count) == 0 else { return nil }
        return Data(hash)
    }
}
