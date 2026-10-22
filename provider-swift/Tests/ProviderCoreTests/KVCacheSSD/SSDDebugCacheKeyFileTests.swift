#if DEBUG
import CryptoKit
import Darwin
import Foundation
import MLXLMCommon
import Testing

@_spi(Benchmarking) @testable import ProviderCore

/// The DEBUG-only key file replaces the Keychain hierarchy entirely, so none
/// of these cases reaches Security/Keychain APIs.
@Suite("DEBUG SSD cache key file")
struct SSDDebugCacheKeyFileTests {
    private let key = SSDDebugCacheKeyFile.environmentKey

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ssd-debug-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }

    private func keyFile(in directory: URL, name: String = "cache.key", bytes: Int = 32,
                         mode: Int = 0o600) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data((0..<bytes).map { _ in UInt8.random(in: 0...255) }).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    private func fingerprint(_ key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("fingerprint".utf8), using: key))
    }

    @Test("a private 32-byte file yields one stable persistent key")
    func acceptsPrivateKeyFile() async throws {
        let owned = try directory()
        defer { try? FileManager.default.removeItem(at: owned) }
        let file = try keyFile(in: owned)
        let first = try SSDDebugCacheKeyFile.load(path: file.path)
        let again = try SSDDebugCacheKeyFile.load(path: file.path)
        #expect(first.bitCount == 256)
        #expect(fingerprint(first) == fingerprint(again))
        let material = try await SSDCacheKeyMaterial.load(environment: [key: file.path])
        #expect(!material.ephemeral)
        #expect(fingerprint(material.key) == fingerprint(first))
        let other = try SSDDebugCacheKeyFile.load(path: keyFile(in: owned, name: "other.key").path)
        #expect(fingerprint(other) != fingerprint(first))
    }

    @Test("wrong size is refused", arguments: [0, 31, 33, 64])
    func refusesWrongSize(bytes: Int) throws {
        let owned = try directory()
        defer { try? FileManager.default.removeItem(at: owned) }
        let file = try keyFile(in: owned, bytes: bytes)
        #expect(throws: SSDDebugCacheKeyFile.Failure.wrongSize(Int64(bytes))) {
            try SSDDebugCacheKeyFile.load(path: file.path)
        }
    }

    @Test("any mode other than 0600 is refused", arguments: [0o400, 0o640, 0o644, 0o660, 0o700, 0o666])
    func refusesWrongMode(mode: Int) throws {
        let owned = try directory()
        defer { try? FileManager.default.removeItem(at: owned) }
        let file = try keyFile(in: owned, mode: mode)
        #expect(throws: SSDDebugCacheKeyFile.Failure.wrongMode(mode_t(mode))) {
            try SSDDebugCacheKeyFile.load(path: file.path)
        }
    }

    @Test("a symlink to a valid key file is refused")
    func refusesSymlink() throws {
        let owned = try directory()
        defer { try? FileManager.default.removeItem(at: owned) }
        let target = try keyFile(in: owned)
        let link = owned.appendingPathComponent("link.key")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: SSDDebugCacheKeyFile.Failure.symbolicLink) {
            try SSDDebugCacheKeyFile.load(path: link.path)
        }
        let dangling = owned.appendingPathComponent("dangling.key")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: owned.appendingPathComponent("absent"))
        #expect(throws: SSDDebugCacheKeyFile.Failure.symbolicLink) {
            try SSDDebugCacheKeyFile.load(path: dangling.path)
        }
    }

    @Test("missing, relative, directory and hard-linked paths are refused")
    func refusesOtherUnsafePaths() throws {
        let owned = try directory()
        defer { try? FileManager.default.removeItem(at: owned) }
        #expect(throws: SSDDebugCacheKeyFile.Failure.missing) {
            try SSDDebugCacheKeyFile.load(path: owned.appendingPathComponent("absent.key").path)
        }
        #expect(throws: SSDDebugCacheKeyFile.Failure.relativePath) {
            try SSDDebugCacheKeyFile.load(path: "cache.key")
        }
        #expect(throws: SSDDebugCacheKeyFile.Failure.notRegularFile) {
            try SSDDebugCacheKeyFile.load(path: owned.path)
        }
        let file = try keyFile(in: owned)
        try FileManager.default.linkItem(at: file, to: owned.appendingPathComponent("second-name.key"))
        #expect(throws: SSDDebugCacheKeyFile.Failure.multipleLinks) {
            try SSDDebugCacheKeyFile.load(path: file.path)
        }
    }

    @Test("an unusable file fails closed instead of reaching the Keychain")
    func refusalSurfacesAsKeyFailure() async throws {
        let owned = try directory()
        defer { try? FileManager.default.removeItem(at: owned) }
        let file = try keyFile(in: owned, mode: 0o644)
        let error = await #expect(throws: SSDCacheKeyMaterial.Failure.self) {
            try await SSDCacheKeyMaterial.load(environment: [key: file.path])
        }
        #expect(error.map { String(describing: $0) }
            == "persistent key unavailable: DARKBLOOM_DEBUG_CACHE_KEY_FILE: mode is 644, not 600")
        // The existing explicit test opt-in still permits its ephemeral fallback.
        let fallback = try await SSDCacheKeyMaterial.load(
            environment: [key: file.path, "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1"])
        #expect(fallback.ephemeral)
    }

    @Test("a complete store built from the key file reports a persistent key and keeps its epoch")
    func storeKeepsEpochAcrossReconstruction() async throws {
        let owned = try directory()
        let root = owned.appendingPathComponent("payload", isDirectory: true)
        defer {
            SSDWholeRootMaintainer.shared.stopPeriodicMaintenance(root: root)
            try? FileManager.default.removeItem(at: owned)
        }
        let original = try keyFile(in: owned)
        let replacement = try keyFile(in: owned, name: "replacement.key")
        func environment(_ file: URL) -> [String: String] {
            ["DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1",
             "DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY": "1",
             SSDPrefixCacheFactory.testRootEnvironmentKey: root.path,
             key: file.path]
        }
        let identity = CBv2CompleteCheckpointIdentity(modelAggregateHash: "weights", promptContractID: "prompt",
            buildID: "build", numericsFingerprint: "numerics")
        func open(_ file: URL) async throws -> (persistent: Bool, epoch: String?) {
            let store = try #require(await SSDHybridCheckpointStoreFactory.make(
                modelId: "debug-key", identity: identity, kvBudget: nil, environment: environment(file)))
            let observed = (!store.usesEphemeralKey, store.config.epochStore?.current)
            await store.closeAndWait()
            return observed
        }
        let first = try await open(original)
        let restarted = try await open(original)
        let rekeyed = try await open(replacement)
        #expect(first.persistent && restarted.persistent && rekeyed.persistent)
        #expect(first.epoch != nil)
        #expect(restarted.epoch == first.epoch)
        #expect(rekeyed.epoch != first.epoch)
    }
}
#endif
