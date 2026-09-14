import Darwin
import Foundation
import SandboxRuntime

enum SandboxHostTokenFile {
    static func read(_ url: URL) throws -> String {
        let parent = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let parentDescriptor: Int32
        do {
            parentDescriptor = try SandboxAuthorityFileSystem
                .openPrivateDirectory(
                    at: parent,
                    createIfMissing: false
                )
        } catch {
            throw DaemonCLIError.invalidArguments("serve")
        }
        defer { close(parentDescriptor) }
        let descriptor = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw DaemonCLIError.invalidArguments("serve")
        }
        defer { close(descriptor) }
        let data: Data
        do {
            data = try SandboxAuthorityFileSystem.readStablePrivateFile(
                descriptor,
                maximumBytes: 512
            )
        } catch {
            throw DaemonCLIError.invalidArguments("serve")
        }
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw DaemonCLIError.invalidArguments("serve")
        }
        let token = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (32...256).contains(token.utf8.count),
              !token.contains(where: \.isWhitespace)
        else {
            throw DaemonCLIError.invalidArguments("serve")
        }
        return token
    }
}
