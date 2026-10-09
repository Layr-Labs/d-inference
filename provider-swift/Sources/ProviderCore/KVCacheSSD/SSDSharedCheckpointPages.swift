import CryptoKit
import Foundation
import MLXLMCommon

/// The encrypted endpoint binds the entire native manifest and the ordered
/// immutable page graph. The graph has no parents: each endpoint owns every
/// referenced page through a hard link, including after a provider restart.
final class SSDSharedCheckpointPages: @unchecked Sendable {
    static let maximumManifestBytes = 2 << 20

    struct Reference: Codable, Sendable, Equatable {
        let id: String
        let hash: String
        let tensor: Int
        let offset: Int
        let bytes: Int
    }

    struct Envelope: Codable, Sendable {
        let schema: Int
        let manifest: CBv2CompleteCheckpointManifest
        let pages: [Reference]

        func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(self)
            guard data.count <= SSDSharedCheckpointPages.maximumManifestBytes else {
                throw CBv2CompleteCheckpointError.invalidManifest
            }
            return data
        }

        static func decode(_ data: Data) throws -> Self {
            guard !data.isEmpty, data.count <= SSDSharedCheckpointPages.maximumManifestBytes else {
                throw CBv2CompleteCheckpointError.invalidManifest
            }
            let envelope = try JSONDecoder().decode(Self.self, from: data)
            let geometry = try SSDCheckpointPageGeometry.pages(envelope.manifest)
            guard envelope.schema == 1, geometry.count == envelope.pages.count else {
                throw CBv2CompleteCheckpointError.invalidManifest
            }
            for (page, reference) in zip(geometry, envelope.pages) {
                guard page.tensor == reference.tensor, page.offset == reference.offset,
                    page.bytes == reference.bytes,
                    SSDBlockStore.isLowerHex(reference.id, count: 64),
                    SSDBlockStore.isLowerHex(reference.hash, count: 64) else {
                    throw CBv2CompleteCheckpointError.invalidManifest
                }
            }
            guard data == (try envelope.encoded()) else {
                throw CBv2CompleteCheckpointError.invalidManifest
            }
            return envelope
        }
    }

    struct Written {
        let logicalBytes: Int
        let physicalBytesWritten: Int
    }

    private let executionNamespace = UUID().uuidString
    private let lock = NSLock()
    // Only recently used links are held in RAM, never tensor bytes. Bounds
    // cover delayed terminal callbacks without allowing unbounded metadata.
    private var links: [String: URL] = [:]
    private var order: [String] = []
    private static let maximumRememberedPages = SSDCheckpointPageGeometry.maximumPages

    static func eligible(modelID: String, manifest: CBv2CompleteCheckpointManifest,
                         requestID: CBv2RequestID?, maximumPlaintextBytes: Int) -> Bool {
        guard requestID != nil, !modelID.lowercased().contains("mimo"),
            manifest.backendLayout == CBv2CompleteCheckpointManifest.historicalAttentionLayout,
            let geometry = try? SSDCheckpointPageGeometry.pages(manifest),
            let packed = try? manifest.validateStructure(), packed <= maximumPlaintextBytes else { return false }
        let placeholder = Envelope(schema: 1, manifest: manifest, pages: geometry.map {
            Reference(id: String(repeating: "0", count: 64), hash: String(repeating: "0", count: 64),
                tensor: $0.tensor, offset: $0.offset, bytes: $0.bytes)
        })
        guard let bytes = try? placeholder.encoded() else { return false }
        return bytes.count <= maximumPlaintextBytes - packed
    }

    static func manifestMetadata(bytes: Int, tag: Data, identity: CBv2CompleteCheckpointIdentity,
                                 layout: String, createdAt: Int64) -> SSDBlockMetadata {
        .init(lookupTag: tag.hexString, weightHash: identity.modelAggregateHash,
            layoutEpoch: SSDHybridCheckpointEnvelope.layoutEpoch(identity: identity, backendLayout: layout),
            blockSize: PrefixCachePolicy.blockSize, layerCount: 1,
            chunks: [.init(layerIndex: 0, tensor: 0, shape: [bytes], dtype: "uint8")],
            chunkPlaintextSizes: [bytes], createdAt: createdAt,
            windowKind: SSDCheckpointPageFiles.manifestKind)
    }

    private static func pageMetadata(reference: Reference, identity: CBv2CompleteCheckpointIdentity,
                                     layout: String) -> SSDBlockMetadata {
        // Page identity is a keyed, execution-scoped value. Tensor roles,
        // token positions, plaintext hash and cacheSalt stay in the endpoint.
        .init(lookupTag: reference.id, weightHash: identity.modelAggregateHash,
            layoutEpoch: SSDHybridCheckpointEnvelope.layoutEpoch(identity: identity, backendLayout: layout),
            blockSize: PrefixCachePolicy.blockSize, layerCount: 1,
            chunks: [.init(layerIndex: 0, tensor: 0, shape: [reference.bytes], dtype: "uint8")],
            chunkPlaintextSizes: [reference.bytes], createdAt: 0,
            windowKind: SSDCheckpointPageFiles.pageKind)
    }

    func write(source: CBv2CompleteCheckpointExport, requestID: CBv2RequestID,
               checkpoint: URL, tag: Data, key: SymmetricKey, strictFsync: Bool,
               createdAt: Int64, maximumPlaintextBytes: Int,
               check: () throws -> Void, charge: (Int) throws -> Void,
               countRead: (Int) -> Void) throws -> Written {
        let manifest = source.manifest
        let geometry = try SSDCheckpointPageGeometry.pages(manifest)
        let lookupKeys = SSDLookupKeys(kek: key)
        try SSDNoFollowIO.prepareDirectory(SSDCheckpointPageFiles.directory(for: checkpoint))
        var published = false
        defer {
            if !published {
                SSDCheckpointPageFiles.remove(for: checkpoint)
                _ = SSDBlockStore.removeItemIfSafe(at: checkpoint,
                    under: checkpoint.deletingLastPathComponent().deletingLastPathComponent())
            }
        }
        var references: [Reference] = []
        var authenticatedPages: [(URL, SSDAuthenticatedFileIdentity)] = []
        var physicalWritten = 0
        var logical = 0
        for page in geometry {
            try check()
            // Read and hash the bounded incoming bytes before sharing. A
            // repeated request ID or changed native data cannot mix executions.
            let bytes = try source.readSegment(tensorIndex: page.tensor,
                byteOffset: page.offset, maximumBytes: page.bytes)
            guard bytes.count == page.bytes else { throw CBv2CompleteCheckpointError.invalidSegment }
            let hash = Data(SHA256.hash(data: bytes)).hexString
            var address = Data("darkbloom-checkpoint-page-v1".utf8)
            for value in [executionNamespace, String(requestID.raw), manifest.cacheSalt ?? "",
                          manifest.identity.modelAggregateHash, manifest.identity.promptContractID,
                          manifest.identity.buildID, manifest.identity.numericsFingerprint,
                          manifest.backendLayout, page.coordinate, hash] {
                var count = UInt64(value.utf8.count).littleEndian
                withUnsafeBytes(of: &count) { address.append(contentsOf: $0) }
                address.append(contentsOf: value.utf8)
            }
            let id = lookupKeys.checkpointPageTag(address: address,
                cacheSalt: manifest.cacheSalt ?? "").hexString
            let reference = Reference(id: id, hash: hash, tensor: page.tensor,
                                      offset: page.offset, bytes: page.bytes)
            let target = SSDCheckpointPageFiles.pageURL(checkpoint: checkpoint, id: id)
            let metadata = Self.pageMetadata(reference: reference, identity: manifest.identity,
                                             layout: manifest.backendLayout)
            var linked = false
            var authenticated: SSDAuthenticatedFileIdentity?
            if let previous = lock.withLock({ links[id] }), previous != target {
                // READY never trusts a remembered path. Authenticate the
                // destination link, not a source that can change before linkat.
                do {
                    try SSDCheckpointPageFiles.link(from: previous, to: target,
                        strictFsync: strictFsync, authenticate: { url in
                            authenticated = try Self.readPage(at: url, reference: reference, key: key,
                                identity: manifest.identity, layout: manifest.backendLayout,
                                check: check, countRead: countRead, consume: { _ in })
                        })
                    linked = true
                } catch {
                    // A cancelled read must not become a fresh-page fallback.
                    if error is CancellationError { throw error }
                    try check()
                }
            }
            let written: Int
            if linked {
                guard let file = SSDCheckpointPageFiles.info(target) else {
                    throw CBv2CompleteCheckpointError.incompleteTransfer
                }
                written = file.bytes
            } else {
                let estimate = try SSDBlockStore.serializedByteCount(metadata: metadata)
                try charge(estimate)
                written = try SSDBlockStore.writeStreaming(to: target, metadata: metadata, kekKey: key,
                    maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes,
                    strictFsync: strictFsync, chunk: { _ in try check(); return bytes })
                authenticated = try Self.readPage(at: target, reference: reference, key: key,
                    identity: manifest.identity, layout: manifest.backendLayout,
                    check: check, countRead: countRead, consume: { _ in })
                physicalWritten = SSDCheckpointPageFiles.saturatingAdd(physicalWritten, written)
            }
            guard let authenticated else { throw CBv2CompleteCheckpointError.incompleteTransfer }
            authenticatedPages.append((target, authenticated))
            logical = SSDCheckpointPageFiles.saturatingAdd(logical, written)
            references.append(reference)
        }
        let envelope = Envelope(schema: 1, manifest: manifest, pages: references)
        let encoded = try envelope.encoded()
        let packed = try manifest.validateStructure()
        guard packed <= maximumPlaintextBytes, encoded.count <= maximumPlaintextBytes - packed else {
            throw CBv2CompleteCheckpointError.invalidManifest
        }
        let metadata = Self.manifestMetadata(bytes: encoded.count, tag: tag, identity: manifest.identity,
                                            layout: manifest.backendLayout, createdAt: createdAt)
        try charge(SSDBlockStore.serializedByteCount(metadata: metadata))
        if strictFsync { try SSDCheckpointPageFiles.synchronizeDirectories(for: checkpoint) }
        try Self.requireUnchanged(authenticatedPages)
        let written = try SSDBlockStore.writeStreaming(to: checkpoint, metadata: metadata, kekKey: key,
            maximumChunkBytes: Self.maximumManifestBytes, strictFsync: strictFsync,
            chunk: { _ in try check(); return encoded })
        if strictFsync { try SSDCheckpointPageFiles.synchronize(checkpoint.deletingLastPathComponent()) }
        try Self.requireUnchanged(authenticatedPages)
        try check()
        published = true
        for reference in references {
            remember(id: reference.id,
                url: SSDCheckpointPageFiles.pageURL(checkpoint: checkpoint, id: reference.id))
        }
        return .init(logicalBytes: SSDCheckpointPageFiles.saturatingAdd(logical, written),
                     physicalBytesWritten: SSDCheckpointPageFiles.saturatingAdd(physicalWritten, written))
    }

    private func remember(id: String, url: URL) {
        lock.withLock {
            if links[id] == nil { order.append(id) }
            links[id] = url
            if order.count > Self.maximumRememberedPages {
                let count = Self.maximumRememberedPages / 4
                for removed in order.prefix(count) { links.removeValue(forKey: removed) }
                order.removeFirst(count)
            }
        }
    }

    @discardableResult
    static func readPage(at url: URL, reference: Reference, key: SymmetricKey,
                         identity: CBv2CompleteCheckpointIdentity, layout: String,
                         check: () throws -> Void, beforeRead: ((Int) throws -> Void)? = nil,
                         countRead: (Int) -> Void, consume: (Data) throws -> Void) throws -> SSDAuthenticatedFileIdentity {
        let expected = pageMetadata(reference: reference, identity: identity, layout: layout)
        var chunks = 0
        var authenticated: SSDAuthenticatedFileIdentity?
        try SSDBlockStore.readStreaming(from: url, kekKey: key,
            maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes,
            maximumPlaintextBytes: reference.bytes,
            maximumMetadataBytes: 1 << 20, maximumWrappedDEKBytes: 60, requireEOF: true,
            checkCancellation: check, beforeRead: beforeRead, onBytesRead: countRead,
            onAuthenticatedFile: { authenticated = $0 }, validateMetadata: { metadata in
                guard metadata == expected else { throw CBv2CompleteCheckpointError.incompatibleCheckpoint }
            }, consumeChunk: { index, bytes in
                guard index == 0, bytes.count == reference.bytes,
                    Data(SHA256.hash(data: bytes)).hexString == reference.hash else {
                    throw CBv2CompleteCheckpointError.invalidSegment
                }
                chunks += 1
                try consume(bytes)
            })
        guard chunks == 1, let authenticated, authenticated.matches(url: url) else {
            throw SSDAuthenticatedFileChange.changedDuringRead
        }
        return authenticated
    }

    static func read(envelope: Envelope, encoded: Data, checkpoint: URL, tag: Data,
                     key: SymmetricKey, maximumPlaintextBytes: Int, check: () throws -> Void,
                     beforeRead: ((Int) throws -> Void)? = nil, countRead: (Int) -> Void,
                     onAuthenticatedFile: ((SSDAuthenticatedFileIdentity) -> Void)? = nil,
                     consume: (Reference, Data) throws -> Void) throws {
        let packed = try envelope.manifest.validateStructure()
        guard packed <= maximumPlaintextBytes, encoded.count <= maximumPlaintextBytes - packed else {
            throw CBv2CompleteCheckpointError.invalidManifest
        }
        var mainAuthenticated = false
        var checkpointIdentity: SSDAuthenticatedFileIdentity?
        try SSDBlockStore.readStreaming(from: checkpoint, kekKey: key,
            maximumChunkBytes: Self.maximumManifestBytes, maximumPlaintextBytes: maximumPlaintextBytes,
            maximumMetadataBytes: 1 << 20, maximumWrappedDEKBytes: 60, requireEOF: true,
            checkCancellation: check, beforeRead: beforeRead, onBytesRead: countRead,
            onAuthenticatedFile: { file in
                checkpointIdentity = file
                onAuthenticatedFile?(file)
            },
            validateMetadata: { metadata in
                guard metadata == manifestMetadata(bytes: encoded.count, tag: tag,
                    identity: envelope.manifest.identity, layout: envelope.manifest.backendLayout,
                    createdAt: metadata.createdAt) else {
                    throw CBv2CompleteCheckpointError.incompatibleCheckpoint
                }
            }, consumeChunk: { index, bytes in
                guard index == 0, bytes == encoded else { throw CBv2CompleteCheckpointError.invalidManifest }
                mainAuthenticated = true
            })
        guard mainAuthenticated else { throw CBv2CompleteCheckpointError.incompleteTransfer }
        var pageIdentities: [(URL, SSDAuthenticatedFileIdentity)] = []
        for reference in envelope.pages {
            try check()
            let page = SSDCheckpointPageFiles.pageURL(checkpoint: checkpoint, id: reference.id)
            let authenticated = try readPage(at: page, reference: reference, key: key,
                identity: envelope.manifest.identity, layout: envelope.manifest.backendLayout,
                check: check, beforeRead: beforeRead, countRead: countRead,
                consume: { try consume(reference, $0) })
            pageIdentities.append((page, authenticated))
        }
        try requireUnchanged(pageIdentities)
        guard let checkpointIdentity, checkpointIdentity.matches(url: checkpoint) else {
            throw SSDAuthenticatedFileChange.changedDuringRead
        }
        try check()
    }

    private static func requireUnchanged(_ pages: [(URL, SSDAuthenticatedFileIdentity)]) throws {
        guard pages.allSatisfy({ $0.1.matches(url: $0.0) }) else {
            throw SSDAuthenticatedFileChange.changedDuringRead
        }
    }
}
