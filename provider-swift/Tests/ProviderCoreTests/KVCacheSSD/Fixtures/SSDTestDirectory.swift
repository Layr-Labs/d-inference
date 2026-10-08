import Foundation

/// Test working-volume selection only; this does not configure the provider cache.
enum SSDTestDirectory {
    static let environmentKey = "DARKBLOOM_SSD_TEST_TMPDIR"

    enum SelectionError: Error { case invalidOverride }

    static func parent(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        guard let configured = environment[environmentKey] else {
            return FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        }
        guard !configured.isEmpty, !configured.contains("\0"),
              (configured as NSString).isAbsolutePath else {
            throw SelectionError.invalidOverride
        }
        let candidate = URL(fileURLWithPath: configured, isDirectory: true)
        let canonical = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard canonical.path == candidate.path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              FileManager.default.isWritableFile(atPath: candidate.path) else {
            throw SelectionError.invalidOverride
        }
        return canonical
    }
}
