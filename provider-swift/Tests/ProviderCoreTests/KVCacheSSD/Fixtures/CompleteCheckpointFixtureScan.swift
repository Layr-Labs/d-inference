import CryptoKit
import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// Reads back every encrypted complete-checkpoint file under a fixture's root,
/// authenticating each file whole and keeping only its manifest.
///
/// A store writes a file up to its own `maxReadBytes` and restores it under the
/// same cap (`SSDHybridCheckpointEnvelope`, `SSDHybridCheckpointStore+ChainRead`),
/// so the scan reads under the largest cap of any store the fixture made. Under
/// a smaller cap it would refuse a file the store wrote and can restore, as a
/// 32K-token Qwen3.5-9B checkpoint (~1.31 GB, production's 7 GiB cap) was
/// refused under the general 1 GiB cap.
final class CompleteCheckpointFixtureScan: @unchecked Sendable {
    let root: URL
    let key: SymmetricKey
    private let lock = NSLock()
    private var largestStoreReadBytes: Int

    init(root: URL, key: SymmetricKey,
         defaultReadBytes: Int = SSDPrefixCachePolicy.maxStageBytes(environment: [:])) {
        self.root = root
        self.key = key
        largestStoreReadBytes = defaultReadBytes
    }

    /// Records the `maxReadBytes` of a store the fixture made under `root`.
    func storeMade(maxReadBytes: Int) {
        lock.withLock { largestStoreReadBytes = max(largestStoreReadBytes, maxReadBytes) }
    }

    /// Every file under `root`, with its manifest.
    func files() throws -> [(url: URL, manifest: CBv2CompleteCheckpointManifest)] {
        let readBytes = lock.withLock { largestStoreReadBytes }
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        return try enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "dbk3" }.map { file in
            var manifestBytes: Data?
            try SSDBlockStore.readStreaming(from: file, kekKey: key,
                maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes,
                maximumPlaintextBytes: readBytes,
                requireEOF: true, validateMetadata: { _ in },
                consumeChunk: { index, data in if index == 0 { manifestBytes = data } })
            return (file, try SSDHybridCheckpointEnvelope.decodeManifest(try #require(manifestBytes)))
        }
    }
}
