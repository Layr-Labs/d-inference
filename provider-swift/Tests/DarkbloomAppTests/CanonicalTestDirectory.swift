import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Creates a temporary directory and returns its lexical path with every
/// pre-existing ancestor resolved. macOS exposes `temporaryDirectory` through
/// `/var`, which is itself a symlink; security tests that reject symlinked
/// ancestors must start below the canonical `/private/var` path.
func canonicalTestDirectory(prefix: String) throws -> URL {
    let unresolved = FileManager.default.temporaryDirectory.appendingPathComponent(
        "\(prefix)-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: unresolved,
        withIntermediateDirectories: true
    )

    guard let resolved = unresolved.path.withCString({ realpath($0, nil) }) else {
        throw CocoaError(.fileNoSuchFile)
    }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}
