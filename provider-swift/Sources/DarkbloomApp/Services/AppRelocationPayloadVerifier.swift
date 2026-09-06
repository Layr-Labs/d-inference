import Darwin
import Foundation

/// Structural verification for the executable payload that the canonical bin
/// links expose after publication. Code-signature verification authenticates
/// the bundle, while this check guarantees every required signed member is
/// present as a non-empty regular file before the journal can commit it.
enum AppRelocationPayloadVerifier {
    static func verify(
        appURL: URL,
        mainExecutable: String,
        fileManager: FileManager
    ) throws {
        let macOS = appURL.appendingPathComponent(
            "Contents/MacOS",
            isDirectory: true
        )
        let required: [(name: String, executable: Bool)] = [
            (mainExecutable, true),
            ("darkbloom", true),
            ("darkbloom-enclave", true),
            ("mlx.metallib", false),
        ]
        for item in required {
            let url = macOS.appendingPathComponent(item.name)
            var status = stat()
            guard lstat(url.path, &status) == 0,
                  status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  status.st_size > 0
            else {
                throw AppInstallCoordinatorError.copiedPayloadUnavailable(
                    path: url.path,
                    reason: "the required payload is missing, empty, or not a regular file"
                )
            }
            if item.executable,
               !fileManager.isExecutableFile(atPath: url.path) {
                throw AppInstallCoordinatorError.copiedPayloadUnavailable(
                    path: url.path,
                    reason: "the required executable is not runnable"
                )
            }
        }
    }
}
