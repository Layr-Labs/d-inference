import Foundation
import Testing
@testable import ProviderCore

@Test func authTokenLoadMigratesLegacyTokenToCanonicalPath() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("darkbloom-device-auth-")
        .appendingPathComponent(UUID().uuidString)
    let canonical = tempDir.appendingPathComponent("darkbloom").appendingPathComponent("auth_token")
    let legacy = tempDir.appendingPathComponent("eigeninference").appendingPathComponent("auth_token")
    try FileManager.default.createDirectory(
        at: legacy.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try "legacy-token\n".write(to: legacy, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let token = AuthTokenStore.load(canonicalPath: canonical, legacyPaths: [legacy])

    #expect(token == "legacy-token")
    #expect(try String(contentsOf: canonical, encoding: .utf8) == "legacy-token")
}

@Test func authTokenLoadPrefersCanonicalTokenOverLegacyToken() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("darkbloom-device-auth-")
        .appendingPathComponent(UUID().uuidString)
    let canonical = tempDir.appendingPathComponent("darkbloom").appendingPathComponent("auth_token")
    let legacy = tempDir.appendingPathComponent("eigeninference").appendingPathComponent("auth_token")
    try FileManager.default.createDirectory(
        at: canonical.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: legacy.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try "canonical-token\n".write(to: canonical, atomically: true, encoding: .utf8)
    try "legacy-token\n".write(to: legacy, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let token = AuthTokenStore.load(canonicalPath: canonical, legacyPaths: [legacy])

    #expect(token == "canonical-token")
}

@Test func authTokenDeleteRemovesCanonicalAndLegacyTokens() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("darkbloom-device-auth-")
        .appendingPathComponent(UUID().uuidString)
    let canonical = tempDir.appendingPathComponent("darkbloom").appendingPathComponent("auth_token")
    let legacy = tempDir.appendingPathComponent("eigeninference").appendingPathComponent("auth_token")
    try FileManager.default.createDirectory(
        at: canonical.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: legacy.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try "canonical-token\n".write(to: canonical, atomically: true, encoding: .utf8)
    try "legacy-token\n".write(to: legacy, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try AuthTokenStore.delete(canonicalPath: canonical, legacyPaths: [legacy])

    #expect(!FileManager.default.fileExists(atPath: canonical.path))
    #expect(!FileManager.default.fileExists(atPath: legacy.path))
}
