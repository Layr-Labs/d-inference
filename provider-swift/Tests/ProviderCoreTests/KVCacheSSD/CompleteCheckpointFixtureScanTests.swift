import CryptoKit
import Foundation
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

/// A live Qwen cache validation once stopped on the test's own manifest scan, not a restore. Its 32K
/// card donor wrote a ~1.31 GB Qwen3.5-9B checkpoint through a store with production's complete-checkpoint cap
/// (7 GiB on a 48 GB+ Mac), and `Qwen35CheckpointRetentionFixture` authenticated the file under the general 1 GiB
/// stage cap: "size overflow: streamed plaintext exceeds budget". Here the same asymmetry runs at a CPU size: a
/// file larger than the scan's default cap, written for a store whose cap holds it.
@Suite("A fixture's checkpoint scan reads every file its stores wrote")
struct CompleteCheckpointFixtureScanTests {
    @Test("a file over the scan's default cap, within its store's cap, is read back")
    func scanReadsUnderTheLargestStoreCap() throws {
        let root = try SSDTestDirectory.parent().appendingPathComponent("fixture-scan-\(UUID().uuidString)")
        let modelRoot = root.appendingPathComponent("0123456789ab")
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: modelRoot)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let identity = CBv2CompleteCheckpointIdentity(
            modelAggregateHash: "scan-weights", promptContractID: "scan-template",
            buildID: "scan-build", numericsFingerprint: "scan-numerics")
        let manifest = CBv2CompleteCheckpointManifest(
            identity: identity, position: 512, chunkSize: 256, prefixTokens: (0 ..< 512).map { $0 % 31 },
            cacheSalt: "tenant-a", assistantCodecID: nil,
            tensors: [
                try .init(role: .keys, layer: 0, shape: [1, 1, 512, 64], dtype: .float32),
                try .init(role: .values, layer: 0, shape: [1, 1, 512, 64], dtype: .float32),
                try .init(role: .recurrent, layer: 1, shape: [1, 2, 2, 2], dtype: .float32),
            ],
            backendLayout: CBv2CompleteCheckpointManifest.pagedLayout)
        let storeReadBytes = 16 << 20
        let envelope = try SSDHybridCheckpointEnvelope(manifest: manifest, maximumPlaintextBytes: storeReadBytes)
        let tag = Data(SHA256.hash(data: Data("fixture-scan".utf8)))
        // The file the store writes for this manifest (`SSDHybridCheckpointStore+Write.swift`), its tensors zero.
        _ = try SSDBlockStore.writeStreaming(
            to: SSDBlockStore.fileURL(root: modelRoot, tag16Hex: Data(tag.prefix(16)).hexString),
            metadata: envelope.metadata(tag: tag, identity: identity, createdAt: 0,
                                        backendLayout: CBv2CompleteCheckpointManifest.pagedLayout),
            kekKey: key, maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes
        ) { index in index == 0 ? envelope.manifestBytes : Data(count: envelope.segments[index - 1].bytes) }

        // The scan's default cap sits one byte under the file, as 1 GiB sat under the 32K checkpoint.
        let defaultReadBytes = envelope.plaintextBytes - 1
        do {
            _ = try CompleteCheckpointFixtureScan(root: root, key: key, defaultReadBytes: defaultReadBytes).files()
            Issue.record("the default cap alone must refuse the file")
        } catch {
            #expect("\(error)" == "size overflow: streamed plaintext exceeds budget")
        }

        let scan = CompleteCheckpointFixtureScan(root: root, key: key, defaultReadBytes: defaultReadBytes)
        scan.storeMade(maxReadBytes: storeReadBytes)
        let files = try scan.files()
        #expect(files.map(\.manifest.position) == [512])
        #expect(files.first?.manifest == manifest)
    }
}
