import CryptoKit
import Foundation

/// Facts reported by the executing test image, independent of supervisor CLI
/// labels. The binary digest binds these compile-time facts to provenance.
struct ServingQualificationBuildIdentity: Codable, Sendable {
    let version: Int
    let debugCompilationCondition: Bool
    let debugAssertionsEnabled: Bool
    let binarySHA256: String

    static func capture() throws -> Self {
        guard let executable = Bundle(for: ServingQualificationBuildMarker.self).executableURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let input = try FileHandle(forReadingFrom: executable)
        defer { try? input.close() }
        var hash = SHA256()
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        return Self(version: 1, debugCompilationCondition: debug,
            debugAssertionsEnabled: _isDebugAssertConfiguration(),
            binarySHA256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

private final class ServingQualificationBuildMarker: NSObject {}
