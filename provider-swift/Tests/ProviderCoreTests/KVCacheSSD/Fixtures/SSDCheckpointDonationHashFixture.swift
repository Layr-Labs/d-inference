import CryptoKit
import Foundation
import MLXLMCommon
@testable import ProviderCore

/// A real, empty SSD store for CPU-only hash preparation. No model, native
/// profile, arrays, read/write job or cache-hit qualification is constructed.
final class SSDCheckpointDonationHashFixture {
    let root: URL
    let store: SSDHybridCheckpointStore

    init(layout: String = CBv2CompleteCheckpointManifest.pagedLayout,
         identity: CBv2CompleteCheckpointIdentity = .init(
            modelAggregateHash: "hash-fixture-weights", promptContractID: String(repeating: "a", count: 64),
            buildID: "hash-fixture-build", numericsFingerprint: "hash-fixture-numerics"),
         key: SymmetricKey = .init(data: Data(repeating: 7, count: 32))) throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("checkpoint-donation-hash-\(UUID().uuidString)")
        let modelRoot = root.appendingPathComponent("0123456789ab")
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: modelRoot)
        store = SSDHybridCheckpointStore(config: .init(
            modelId: "hash-fixture-model", identity: identity, backendLayout: layout,
            root: modelRoot, dedicatedRoot: root, epochStore: nil,
            maxReadBytes: 16 << 20, maxStageMillis: 1_000, minEffectiveTokens: 1_024,
            ttlSeconds: 1_800, strictFsync: false, nowSeconds: { 100 },
            diskBudgetBytes: { 1 << 30 }, maintainWholeRoot: {}),
            kekKey: key, kvBudget: nil, diskBudget: SSDDiskBudget(),
            maxWriteBytesPerDay: 1 << 30)
    }

    func remove() {
        // The fixture enqueues no jobs and owns no stage, so close has no
        // asynchronous file owner to retire before removing its empty root.
        store.close()
        try? FileManager.default.removeItem(at: root)
    }

    static func tokens(_ count: Int) -> [Int] { (0..<count).map { ($0 * 17 + 11) % 65_521 } }
}
