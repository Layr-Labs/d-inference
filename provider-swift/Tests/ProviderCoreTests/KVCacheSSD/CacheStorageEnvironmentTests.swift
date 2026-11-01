import CryptoKit
import Foundation
import Testing

@testable import ProviderCore

/// A dev and a production provider on one Mac must not share the encrypted KV
/// cache: the epoch binding includes the KEK fingerprint, so a shared model
/// root would let one environment wipe the other's blocks.
@Suite("Encrypted cache root per build environment")
struct CacheStorageEnvironmentTests {
    private func modelKey(_ modelId: String) -> String {
        String(SHA256.hash(data: Data(modelId.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    private func binding(keyFingerprint: String) -> SSDCacheEpochStore.Binding {
        SSDCacheEpochStore.Binding(
            modelId: "model",
            modelAggregateHash: String(repeating: "a", count: 64),
            promptContractId: String(repeating: "b", count: 64),
            blockHashVersion: "dbk3",
            blockSize: 256,
            layoutEpoch: "layout",
            keyFingerprint: keyFingerprint)
    }

    private func writeBlock(root: URL, tag: Character) throws -> URL {
        let block = SSDBlockStore.fileURL(root: root, tag16Hex: String(repeating: tag, count: 32))
        try FileManager.default.createDirectory(
            at: block.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("block-\(tag)".utf8).write(to: block)
        return block
    }

    @Test("production keeps its payload root byte for byte")
    func productionRootIsUnchanged() {
        #expect(CacheStorage.rootDirectoryName == "darkbloom/kv3")
        #expect(CacheStorage.defaultRoot == CacheStorage.defaultRoot(for: .prod))
        #expect(CacheStorage.defaultRoot.path.hasSuffix("/Library/Caches/darkbloom/kv3"))
        let settings = CacheSettings(directory: "/Volumes/Cache/models", volumeUUID: "uuid")
        #expect(CacheStorage.root(for: settings).path == "/Volumes/Cache/models/darkbloom/kv3")
    }

    @Test("prod and dev resolve different payload and model roots")
    func environmentsResolveDifferentRoots() {
        let configured = CacheSettings(directory: "/Volumes/Cache/models", volumeUUID: "uuid")
        for settings in [CacheSettings(), configured] {
            let prod = CacheStorage.root(for: settings, environment: .prod)
            let dev = CacheStorage.root(for: settings, environment: .dev)
            #expect(prod != dev)
            #expect(!dev.path.hasPrefix(prod.path + "/"))
            #expect(!prod.path.hasPrefix(dev.path + "/"))
            #expect(prod.deletingLastPathComponent().deletingLastPathComponent()
                == dev.deletingLastPathComponent().deletingLastPathComponent())
            let key = modelKey("mlx-community/Qwen3-8B-4bit")
            #expect(prod.appendingPathComponent(key) != dev.appendingPathComponent(key))
        }
        #expect(CacheStorage.root(for: configured, environment: .dev).path
            == "/Volumes/Cache/models/" + BuildEnvironment.dev.encryptedCacheNamespace + "/kv3")
    }

    @Test("a different KEK in the other environment leaves blocks and epoch untouched")
    func environmentsDoNotWipeEachOther() throws {
        let parent = try SSDTestDirectory.parent()
            .appendingPathComponent("cache-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let settings = CacheSettings(directory: parent.path, volumeUUID: "uuid")
        let key = modelKey("model")
        let prodRoot = CacheStorage.root(for: settings, environment: .prod).appendingPathComponent(key)
        let devRoot = CacheStorage.root(for: settings, environment: .dev).appendingPathComponent(key)
        for root in [prodRoot, devRoot] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        let prodBinding = binding(keyFingerprint: String(repeating: "1", count: 64))
        let devBinding = binding(keyFingerprint: String(repeating: "2", count: 64))

        let prod = try SSDCacheEpochStore(root: prodRoot, binding: prodBinding)
        let prodEpoch = try #require(prod.current)
        let prodBlock = try writeBlock(root: prodRoot, tag: "c")

        let dev = try SSDCacheEpochStore(root: devRoot, binding: devBinding)
        let devEpoch = try #require(dev.current)
        let devBlock = try writeBlock(root: devRoot, tag: "d")

        #expect(FileManager.default.fileExists(atPath: prodBlock.path))
        #expect(try SSDCacheEpochStore(root: prodRoot, binding: prodBinding).current == prodEpoch)
        #expect(try SSDCacheEpochStore(root: devRoot, binding: devBinding).current == devEpoch)
        #expect(FileManager.default.fileExists(atPath: prodBlock.path))
        #expect(FileManager.default.fileExists(atPath: devBlock.path))

        // Negative control: the same root with the other KEK wipes the blocks.
        // The namespace above is what prevents this between environments.
        _ = try SSDCacheEpochStore(root: prodRoot, binding: devBinding)
        #expect(!FileManager.default.fileExists(atPath: prodBlock.path))
        #expect(FileManager.default.fileExists(atPath: devBlock.path))
    }

    @Test("the namespaced root stays inside the selected volume checks")
    func namespacedRootKeepsVolumeChecks() {
        let settings = CacheSettings(directory: "/Volumes/Cache/models", volumeUUID: "uuid")
        let dev = CacheStorage.root(for: settings, environment: .dev)
        // Creating the namespace below the operator-owned directory is allowed;
        // recreating the directory itself or a parent still is not.
        #expect(throws: Never.self) {
            try CacheStorage.validateCreation(
                at: dev.deletingLastPathComponent(), configuration: settings)
        }
        #expect(throws: CacheStorageError.self) {
            try CacheStorage.validateCreation(
                at: URL(fileURLWithPath: "/Volumes/Cache/models"), configuration: settings)
        }
    }
}
