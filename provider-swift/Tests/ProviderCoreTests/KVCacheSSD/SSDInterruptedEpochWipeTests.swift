import Foundation
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

/// A model's epoch wipe that stops early (the process quits, or one entry
/// can't be removed) leaves its invalidating record in place. Unloaded
/// whole-root maintenance still removes that model's due files, and the next
/// initialization finishes the wipe.
@Suite("Interrupted epoch wipe", .serialized)
struct SSDInterruptedEpochWipeTests {
    private func binding(_ f: SSDHybridCheckpointTestFixture, keyFingerprint: String) -> SSDCacheEpochStore.Binding {
        .init(modelId: "fixture-model", modelAggregateHash: f.identity.modelAggregateHash,
              promptContractId: f.identity.promptContractID, blockHashVersion: CBv2BlockHasher.version,
              blockSize: PrefixCachePolicy.blockSize, layoutEpoch: SSDHybridCheckpointEnvelope.layoutEpoch(
                identity: f.identity, backendLayout: f.backendLayout),
              keyFingerprint: keyFingerprint)
    }

    private func recordText(_ f: SSDHybridCheckpointTestFixture) throws -> String {
        try String(contentsOf: f.modelRoot.appendingPathComponent("cache-epoch.json"), encoding: .utf8)
    }

    @Test("after a wipe that failed, unloaded maintenance still removes the model's due files")
    func failedWipeKeepsTTLCleanup() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        // A private disk budget: once closed, no store is registered for the root.
        let store = try f.makeStore()
        #expect(try await f.donate(store) == [256])
        let file = f.file(store)
        let checkpoint = try Data(contentsOf: file)
        await store.closeAndWait()

        // A directory named like a block file can't be removed, so the wipe a
        // binding change starts fails and leaves its invalidating record.
        let blocker = file.deletingLastPathComponent()
            .appendingPathComponent(String(repeating: "0", count: 32) + ".dbk3", isDirectory: true)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            _ = try SSDCacheEpochStore(root: f.modelRoot, binding: binding(f, keyFingerprint: "rotated-key"))
        }
        #expect(try recordText(f).contains("invalidating"))

        // Whichever entry the wipe reached first, a due checkpoint stays.
        if !FileManager.default.fileExists(atPath: file.path) { try checkpoint.write(to: file) }
        let result = SSDWholeRootMaintainer().maintain(
            root: f.root, ttlSeconds: 1,
            nowSeconds: Int64(Date().timeIntervalSince1970) + 7_200, budgetBytes: Int.max)
        #expect(result.ttlExpired == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        // Once the entry can go, the next initialization finishes the wipe.
        try FileManager.default.removeItem(at: blocker)
        let successor = try SSDCacheEpochStore(root: f.modelRoot, binding: binding(f, keyFingerprint: "rotated-key"))
        #expect(successor.current != nil)
        let record = try recordText(f)
        #expect(!record.contains("invalidating"))
    }

    @Test("budget eviction also runs under an invalidating record")
    func failedWipeKeepsBudgetCleanup() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let store = try f.makeStore()
        #expect(try await f.donate(store) == [256])
        let file = f.file(store)
        let checkpoint = try Data(contentsOf: file)
        await store.closeAndWait()

        let blocker = file.deletingLastPathComponent()
            .appendingPathComponent(String(repeating: "f", count: 32) + ".dbk3", isDirectory: true)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            _ = try SSDCacheEpochStore(root: f.modelRoot, binding: binding(f, keyFingerprint: "rotated-key"))
        }
        if !FileManager.default.fileExists(atPath: file.path) { try checkpoint.write(to: file) }
        // Fresh, so only the budget of 0 can remove it.
        let result = SSDWholeRootMaintainer().maintain(
            root: f.root, ttlSeconds: 3_600,
            nowSeconds: Int64(Date().timeIntervalSince1970), budgetBytes: 0)
        #expect(result.budgetEvicted == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
