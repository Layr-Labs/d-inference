import CryptoKit
import Foundation
import Testing

@Test func qualificationBuildIdentityMatchesExecutingImage() throws {
    let identity = try ServingQualificationBuildIdentity.capture()
    #expect(identity.version == 1)
    #if DEBUG
    #expect(identity.debugCompilationCondition)
    #else
    #expect(!identity.debugCompilationCondition)
    #endif
    #expect(identity.debugAssertionsEnabled == _isDebugAssertConfiguration())
    // This is the image supervisor provenance hashes, not CommandLine's
    // xctest host process. SwiftPM stages mlx.metallib beside this same file.
    let bundle = Bundle(for: BuildIdentityTestBundleMarker.self)
    let executable = try #require(bundle.executableURL)
    #expect(bundle.bundleURL.pathExtension == "xctest")
    #expect(executable.deletingLastPathComponent().lastPathComponent == "MacOS")
    let bytes = try Data(contentsOf: executable, options: .mappedIfSafe)
    #expect(bytes.count > 4)
    #expect(Array(bytes.prefix(4)) == [0xcf, 0xfa, 0xed, 0xfe]) // arm64 Mach-O 64
    let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    #expect(identity.binarySHA256.count == 64)
    #expect(identity.binarySHA256 == expected)
}

private final class BuildIdentityTestBundleMarker: NSObject {}
