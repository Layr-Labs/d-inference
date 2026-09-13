import Darwin
import Foundation
import SandboxGuestProtocol
import SandboxRuntime

enum GuestBootstrapValidation {
    static func validate() async throws {
        try GuestNumericIdentity.validate()
        let users = try await SandboxProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/dscl"),
            arguments: [".", "-list", "/Users"], timeoutSeconds: 5, maximumOutputBytes: 65536)
        guard users.exitCode == 0, !users.standardOutputTruncated else { throw GuestProtocolError.invalidConfiguration }
        if String(decoding: users.standardOutput, as: UTF8.self).split(separator: "\n").contains("lume") {
            let result = try await SandboxProcessRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/dscl"),
            arguments: [".", "-read", "/Users/lume", "AuthenticationAuthority", "UserShell"],
            timeoutSeconds: 5, maximumOutputBytes: 8192)
        let attributes = String(decoding: result.standardOutput, as: UTF8.self)
        guard result.exitCode == 0, !result.standardOutputTruncated,
              attributes.contains(";DisabledUser;"), attributes.contains("/usr/bin/false")
            else { throw GuestProtocolError.invalidConfiguration }
        }

        // A reusable base must not inherit Lume's bootstrap passwordless sudo.
        // No tenant job starts until the guest-local root policy is clean.
        let directory = URL(fileURLWithPath: "/private/etc/sudoers.d", isDirectory: true)
        let entries = FileManager.default.fileExists(atPath: directory.path)
            ? try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) : []
        guard entries.count <= 64 else { throw GuestProtocolError.invalidConfiguration }
        for path in [URL(fileURLWithPath: "/private/etc/sudoers")] + entries {
            let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw GuestProtocolError.invalidConfiguration }
            defer { close(descriptor) }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_uid == 0,
                  metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o022 == 0,
                  metadata.st_size >= 0, metadata.st_size <= 65536
            else { throw GuestProtocolError.invalidConfiguration }
            let data = try GuestDescriptor.read(descriptor, count: Int(metadata.st_size))
            guard !String(decoding: data, as: UTF8.self).uppercased().contains("NOPASSWD")
            else { throw GuestProtocolError.invalidConfiguration }
        }
    }
}
