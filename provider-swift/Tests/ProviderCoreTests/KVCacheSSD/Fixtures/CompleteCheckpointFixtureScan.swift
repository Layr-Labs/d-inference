import CryptoKit
import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// Reads back every encrypted complete-checkpoint file under a fixture's root,
/// authenticating each file whole and keeping only its manifest.
final class CompleteCheckpointFixtureScan: @unchecked Sendable {
    let root: URL
    let key: SymmetricKey
    let defaultReadBytes: Int
    private let lock = NSLock()
    private var largestStoreReadBytes: Int

    init(root: URL, key: SymmetricKey,
         defaultReadBytes: Int = SSDPrefixCachePolicy.maxStageBytes(environment: [:])) {
        self.root = root
        self.key = key
        self.defaultReadBytes = defaultReadBytes
        largestStoreReadBytes = defaultReadBytes
    }

    /// Records the `maxReadBytes` of a store the fixture made under `root`.
    func storeMade(maxReadBytes: Int) {
        lock.withLock { largestStoreReadBytes = max(largestStoreReadBytes, maxReadBytes) }
    }

    /// Every file under `root`, with its manifest.
    func files() throws -> [(url: URL, manifest: CBv2CompleteCheckpointManifest)] {
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        return try enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "dbk3" }.map { file in
            var manifestBytes: Data?
            try SSDBlockStore.readStreaming(from: file, kekKey: key,
                maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes,
                maximumPlaintextBytes: defaultReadBytes,
                requireEOF: true, validateMetadata: { _ in },
                consumeChunk: { index, data in if index == 0 { manifestBytes = data } })
            return (file, try SSDHybridCheckpointEnvelope.decodeManifest(try #require(manifestBytes)))
        }
    }
}
