// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLXLMCommon

/// This module's lossless JSON tree (`Protocol/Types.swift`), not MLXLMCommon's.
private typealias ManifestJSON = JSONValue

/// DBK3's public header describes opaque byte segments only. Tenant scope,
/// exact checkpoint position and tensor layout stay in encrypted chunk 0.
///
/// No token ID is stored (format 2). Chunk 0 holds the manifest with its
/// prefix tokens (`prefixTokens`, or the diffusion layout's
/// `packedPrefixTokens`) replaced by `prefixDigest`, a keyed digest of the
/// prefix (`SSDLookupKeys.checkpointPrefixDigest`). An `assistantTokens`
/// tensor, which holds the prefix's last tokens, is stored as zeros. A reader
/// rebuilds both from the request's own prompt once the digest matches it.
struct SSDHybridCheckpointEnvelope {
    enum EncodingError: Error { case sizeExceeded }
    struct Segment: Sendable {
        let tensor: Int
        let offset: Int
        let bytes: Int
    }

    /// The exact file a delta extends.
    struct Parent {
        let tag16: Data
        let manifest: CBv2CompleteCheckpointManifest
        let commitment: String
    }

    let manifestBytes: Data
    let segments: [Segment]
    let plaintextBytes: Int
    let parent: Parent?
    /// Nil for a complete file; otherwise segments address stored bytes.
    let delta: SSDCheckpointDeltaLayout?

    init(
        manifest: CBv2CompleteCheckpointManifest, lookupKeys: SSDLookupKeys,
        maximumPlaintextBytes: Int, parent: Parent? = nil
    ) throws {
        let tensorBytes = try manifest.validateStructure()
        manifestBytes = try Self.storedManifestBytes(manifest, lookupKeys: lookupKeys)
        guard manifestBytes.count <= CBv2CompleteCheckpointManifest.maximumEncodedBytes else {
            throw EncodingError.sizeExceeded
        }
        self.parent = parent
        delta = parent.flatMap { SSDCheckpointDeltaLayout(parent: $0.manifest, child: manifest) }
        guard (parent == nil) == (delta == nil) else { throw CBv2CompleteCheckpointError.incompatibleCheckpoint }
        let storedBytes = delta?.tensors.reduce(0) { $0 + $1.storedBytes } ?? tensorBytes
        let (total, overflow) = storedBytes.addingReportingOverflow(manifestBytes.count)
        guard !overflow, total <= maximumPlaintextBytes else {
            throw EncodingError.sizeExceeded
        }
        plaintextBytes = total
        if let delta { segments = delta.segments(maximumBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes); return }
        var result: [Segment] = []
        for (index, tensor) in manifest.tensors.enumerated() {
            var offset = 0
            while offset < tensor.byteCount {
                let count = min(CBv2CompleteCheckpointManifest.maximumSegmentBytes, tensor.byteCount - offset)
                result.append(Segment(tensor: index, offset: offset, bytes: count))
                offset += count
            }
        }
        segments = result
    }

    func completeOffset(of segment: Segment) -> Int { delta?.completeOffset(of: segment) ?? segment.offset }

    func metadata(
        tag: Data, identity: CBv2CompleteCheckpointIdentity, createdAt: Int64,
        backendLayout: String = CBv2CompleteCheckpointManifest.layout
    ) -> SSDBlockMetadata {
        let sizes = [manifestBytes.count] + segments.map(\.bytes)
        return SSDBlockMetadata(
            lookupTag: tag.hexString, weightHash: identity.modelAggregateHash,
            layoutEpoch: Self.layoutEpoch(identity: identity, backendLayout: backendLayout), blockSize: PrefixCachePolicy.blockSize,
            layerCount: 1,
            chunks: sizes.enumerated().map {
                .init(layerIndex: 0, tensor: $0.offset, shape: [$0.element], dtype: "uint8")
            }, chunkPlaintextSizes: sizes, createdAt: createdAt, parentCommitment: parent?.commitment)
    }

    func matches(
        _ metadata: SSDBlockMetadata, tag: Data, identity: CBv2CompleteCheckpointIdentity,
        backendLayout: String = CBv2CompleteCheckpointManifest.layout
    ) -> Bool {
        metadata == self.metadata(
            tag: tag, identity: identity, createdAt: metadata.createdAt, backendLayout: backendLayout)
    }

    // MARK: - Chunk 0

    private static let tokenMembers: Set<String> = ["prefixTokens", "packedPrefixTokens"]
    private static let digestMember = "prefixDigest"

    private static func encoded(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    /// The manifest's canonical JSON with its token member replaced by the
    /// prefix digest.
    static func storedManifestBytes(
        _ manifest: CBv2CompleteCheckpointManifest, lookupKeys: SSDLookupKeys
    ) throws -> Data {
        guard case .object(var members) = try JSONDecoder().decode(
            ManifestJSON.self, from: try encoded(manifest))
        else { throw CBv2CompleteCheckpointError.invalidManifest }
        members.removeAll { tokenMembers.contains($0.0) }
        let digest = lookupKeys.checkpointPrefixDigest(tokens: manifest.prefixTokens[...])
        members.append((digestMember, .string(digest.hexString)))
        return try encoded(ManifestJSON.object(members))
    }

    /// The manifest stored in `bytes`, its prefix taken from `promptTokens`
    /// once the stored digest matches it. A chunk 0 that still holds token
    /// IDs (format 1), or that has no digest, is refused.
    static func decodeManifest(
        _ bytes: Data, promptTokens: [Int], lookupKeys: SSDLookupKeys
    ) throws -> CBv2CompleteCheckpointManifest {
        let stored = try StoredManifest(bytes)
        guard stored.position > 1, stored.position <= promptTokens.count
        else { throw CBv2CompleteCheckpointError.invalidManifest }
        let prefix = promptTokens.prefix(stored.position)
        let expected = Data(lookupKeys.checkpointPrefixDigest(tokens: prefix).hexString.utf8)
        // Another prompt that reached this file by a lookup-tag collision.
        guard expected.count == stored.digest.utf8.count,
            zip(expected, stored.digest.utf8).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0
        else { throw CBv2CompleteCheckpointError.incompatibleCheckpoint }
        return try stored.manifest(prefix: Array(prefix))
    }

    #if DEBUG
    /// Tests that inspect a stored file without its prompt: every field but
    /// the prefix, which reads as zeros. Nothing is verified.
    static func inspectStoredManifestForTesting(_ bytes: Data) throws -> CBv2CompleteCheckpointManifest {
        let stored = try StoredManifest(bytes)
        return try stored.manifest(prefix: Array(repeating: 0, count: stored.position))
    }
    #endif

    /// Chunk 0's members without the digest, and the fields a rebuild reads.
    private struct StoredManifest {
        let members: [(String, ManifestJSON)]
        let digest: String
        let layout: String
        let position: Int

        init(_ bytes: Data) throws {
            guard !bytes.isEmpty, bytes.count <= CBv2CompleteCheckpointManifest.maximumEncodedBytes,
                case .object(var members) = try JSONDecoder().decode(ManifestJSON.self, from: bytes),
                !members.contains(where: { tokenMembers.contains($0.0) }),
                let digestIndex = members.firstIndex(where: { $0.0 == digestMember }),
                case .string(let digest) = members[digestIndex].1,
                case .string(let layout)? = members.first(where: { $0.0 == "backendLayout" })?.1,
                case .int(let position)? = members.first(where: { $0.0 == "position" })?.1
            else { throw CBv2CompleteCheckpointError.invalidManifest }
            members.remove(at: digestIndex)
            self.members = members
            self.digest = digest
            self.layout = layout
            self.position = Int(position)
        }

        /// The manifest with `prefix` in the layout's token member.
        func manifest(prefix: [Int]) throws -> CBv2CompleteCheckpointManifest {
            var members = self.members
            if layout == CBv2CompleteCheckpointManifest.diffusionBlockLayout {
                members.append(("packedPrefixTokens", try PackedTokens.json(prefix)))
            } else {
                members.append(("prefixTokens", .array(prefix.map { .int(Int64($0)) })))
            }
            let manifest = try JSONDecoder().decode(
                CBv2CompleteCheckpointManifest.self, from: try encoded(ManifestJSON.object(members)))
            _ = try manifest.validateStructure()
            return manifest
        }
    }

    // MARK: - Token tensors

    /// The bytes an `assistantTokens` tensor holds at `offset`: its `n`
    /// elements are the prefix's last `n` tokens as int32 LE (every MTP
    /// assistant's prefix codec checks exactly that). Nil for other tensors.
    static func tokenTensorBytes(
        manifest: CBv2CompleteCheckpointManifest, tensor index: Int, offset: Int, count: Int
    ) throws -> Data? {
        let tensor = manifest.tensors[index]
        guard tensor.role == .assistantTokens else { return nil }
        let elements = tensor.byteCount / 4
        guard tensor.dtype == .int32, tensor.byteCount == elements * 4, elements <= manifest.position,
            offset >= 0, count >= 0, offset + count <= tensor.byteCount
        else { throw CBv2CompleteCheckpointError.invalidSegment }
        var full = Data(capacity: tensor.byteCount)
        for token in manifest.prefixTokens.suffix(elements) {
            withUnsafeBytes(of: Int32(truncatingIfNeeded: token).littleEndian) { full.append(contentsOf: $0) }
        }
        return full.subdata(in: offset..<offset + count)
    }

    /// What a writer stores for one segment of `data`: zeros in place of
    /// token IDs. A token tensor that is not the prefix's last tokens is
    /// refused rather than stored.
    static func storedSegment(
        _ data: Data, manifest: CBv2CompleteCheckpointManifest, tensor: Int, offset: Int
    ) throws -> Data {
        guard let expected = try tokenTensorBytes(manifest: manifest, tensor: tensor, offset: offset, count: data.count)
        else { return data }
        guard expected == data else { throw CBv2CompleteCheckpointError.invalidSegment }
        return data
    }

    // MARK: - Layout epoch

    /// Format 2 names a different epoch than format 1 in each file's header
    /// and in the model's epoch record, but `directoryEpoch` keeps the model
    /// directory: the epoch store finds the other format's binding in that
    /// directory's record and removes its files when the store opens, after
    /// an update and after a rollback alike.
    static let storedFormatDomain = "darkbloom-complete-checkpoint-envelope-v2"
    private static let directoryDomain = "darkbloom-complete-checkpoint-envelope-v1"

    static func layoutEpoch(
        identity: CBv2CompleteCheckpointIdentity,
        backendLayout: String = CBv2CompleteCheckpointManifest.layout
    ) -> String {
        epoch(domain: storedFormatDomain, identity: identity, backendLayout: backendLayout)
    }

    /// The epoch the model directory's name is derived from
    /// (`SSDHybridCheckpointStoreFactory.namespace`), unchanged since format 1.
    static func directoryEpoch(
        identity: CBv2CompleteCheckpointIdentity,
        backendLayout: String = CBv2CompleteCheckpointManifest.layout
    ) -> String {
        epoch(domain: directoryDomain, identity: identity, backendLayout: backendLayout)
    }

    private static func epoch(
        domain: String, identity: CBv2CompleteCheckpointIdentity, backendLayout: String
    ) -> String {
        // Canonical fixed-order, length-delimited identity; no request-derived
        // material appears here or in the public header.
        var data = Data(domain.utf8)
        for value in [identity.modelAggregateHash, identity.promptContractID,
                      identity.buildID, identity.numericsFingerprint,
                      backendLayout] {
            var count = UInt64(value.utf8.count).littleEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            data.append(contentsOf: value.utf8)
        }
        return Data(SHA256.hash(data: data)).hexString
    }

    /// The diffusion layout's canonical little-endian bit packing of the
    /// prefix: the narrowest width that holds the largest token. A copy of
    /// MLXLMCommon's internal `CBv2NativeBlockPackedTokens` encoder, whose
    /// decoder refuses any other packing.
    private enum PackedTokens {
        static func json(_ tokens: [Int]) throws -> ManifestJSON {
            guard let largest = tokens.max(), tokens.allSatisfy({ $0 >= 0 && $0 <= Int(Int32.max) })
            else { throw CBv2CompleteCheckpointError.invalidManifest }
            let bitWidth = max(1, Int.bitWidth - largest.leadingZeroBitCount)
            var bytes = Data(capacity: (tokens.count * bitWidth + 7) / 8)
            var buffer: UInt64 = 0
            var available = 0
            for token in tokens {
                buffer |= UInt64(token) << available
                available += bitWidth
                while available >= 8 {
                    bytes.append(UInt8(truncatingIfNeeded: buffer))
                    buffer >>= 8
                    available -= 8
                }
            }
            if available > 0 { bytes.append(UInt8(truncatingIfNeeded: buffer)) }
            return .object([("bitWidth", .int(Int64(bitWidth))), ("bytes", .string(bytes.base64EncodedString()))])
        }
    }
}
