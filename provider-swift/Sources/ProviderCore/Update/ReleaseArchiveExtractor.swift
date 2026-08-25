import Foundation

enum ReleaseArchiveExtractor {
    static let executable = URL(fileURLWithPath: "/usr/bin/tar")

    static func arguments(
        archive: URL,
        destination: URL
    ) -> [String] {
        [
            "-xzp",
            "-f",
            archive.path,
            "-C",
            destination.path,
        ]
    }

    static func extract(
        archive: URL,
        destination: URL,
        timeout: TimeInterval
    ) throws {
        try BoundedProcess.run(
            executable,
            arguments: arguments(
                archive: archive,
                destination: destination
            ),
            timeout: timeout
        )
    }
}
