import CryptoKit
import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// Wire/encryption component gates, not normal-slot SSD restore qualification.
@Suite("Native diffusion encrypted checkpoint envelope")
struct DiffusionCheckpointEnvelopeTests {
    private func manifest(position: Int = 512) throws -> CBv2CompleteCheckpointManifest {
        let identity = CBv2CompleteCheckpointIdentity(modelAggregateHash: String(repeating: "a", count: 64),
            promptContractID: String(repeating: "b", count: 64), buildID: String(repeating: "c", count: 64),
            numericsFingerprint: String(repeating: "d", count: 64))
        let tensors = try [position, 16].enumerated().flatMap { layer, rows in
            try [CBv2CheckpointTensorRole.keys, .values].map {
                try CBv2CheckpointTensorDescriptor(role: $0, layer: layer, shape: [1, 1, rows, 8], dtype: .bfloat16)
            }
        }
        return .init(identity: identity, position: position, chunkSize: 512,
            prefixTokens: Array(repeating: 262207, count: position), cacheSalt: "tenant-secret-fixture-scope",
            assistantCodecID: nil, tensors: tensors,
            backendLayout: CBv2CompleteCheckpointManifest.diffusionBlockLayout,
            nativeBlockState: .init(windowPhysicalLength: 16, windowCursor: 16))
    }

    @Test func fullNativeTokenCountFitsWithoutRaisingCryptoBufferLimits() throws {
        let source = try manifest(position: 262144)
        let envelope = try SSDHybridCheckpointEnvelope(manifest: source, maximumPlaintextBytes: 16 << 20)
        #expect(envelope.manifestBytes.count < CBv2CompleteCheckpointManifest.maximumEncodedBytes)
        #expect(envelope.segments.allSatisfy { $0.bytes <= CBv2CompleteCheckpointManifest.maximumSegmentBytes })
        #expect(try SSDHybridCheckpointEnvelope.decodeManifest(envelope.manifestBytes) == source)
    }

    @Test func encryptedRoundTripHidesNativeStateAndRejectsWrongKeyIdentityAndLateTampering() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("native-checkpoint-envelope-" + UUID().uuidString)
        let modelRoot = root.appendingPathComponent("0123456789ab")
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: modelRoot)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = SSDBlockStore.fileURL(root: modelRoot, tag16Hex: String(repeating: "e", count: 32))
        let source = try manifest()
        let envelope = try SSDHybridCheckpointEnvelope(manifest: source, maximumPlaintextBytes: 1 << 20)
        let tag = Data(repeating: 0xee, count: 32)
        let metadata = envelope.metadata(tag: tag, identity: source.identity, createdAt: 1, backendLayout: source.backendLayout)
        let publicMetadata = try JSONEncoder().encode(metadata)
        for field in ["tenant-secret-fixture-scope", "windowCursor", "packedPrefixTokens", "bfloat16"] {
            #expect(publicMetadata.range(of: Data(field.utf8)) == nil)
        }
        let key = SymmetricKey(size: .bits256) // ephemeral fixture only; not an account/release key
        let chunks = [envelope.manifestBytes] + envelope.segments.enumerated().map {
            Data(repeating: UInt8($0.offset + 1), count: $0.element.bytes)
        }
        _ = try SSDBlockStore.writeStreaming(to: file, metadata: metadata, kekKey: key,
            maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes, chunk: { chunks[$0] })
        let ciphertext = try Data(contentsOf: file)
        #expect(ciphertext.range(of: Data("tenant-secret-fixture-scope".utf8)) == nil)
        #expect(ciphertext.range(of: envelope.manifestBytes) == nil)
        var observed = [Data]()
        try SSDBlockStore.readStreaming(from: file, kekKey: key,
            maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes,
            maximumPlaintextBytes: 1 << 20, requireEOF: true,
            validateMetadata: { try #require(envelope.matches($0, tag: tag, identity: source.identity, backendLayout: source.backendLayout)) },
            consumeChunk: { index, data in
                if index == 0 { try #require(SSDHybridCheckpointEnvelope.decodeManifest(data) == source) }
                observed.append(data)
            })
        #expect(observed == chunks)
        var consumed = 0
        var headerValidated = false
        #expect(throws: (any Error).self) {
            try SSDBlockStore.readStreaming(from: file, kekKey: SymmetricKey(size: .bits256),
                maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes, maximumPlaintextBytes: 1 << 20,
                validateMetadata: { _ in headerValidated = true }, consumeChunk: { _, _ in consumed += 1 })
        }
        #expect(!headerValidated && consumed == 0)
        #expect(throws: CBv2CompleteCheckpointError.incompatibleCheckpoint) {
            try SSDBlockStore.readStreaming(from: file, kekKey: key,
                maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes, maximumPlaintextBytes: 1 << 20,
                validateMetadata: { value in
                    guard envelope.matches(value, tag: tag, identity: source.identity,
                        backendLayout: CBv2CompleteCheckpointManifest.layout) else { throw CBv2CompleteCheckpointError.incompatibleCheckpoint }
                }, consumeChunk: { _, _ in consumed += 1 })
        }
        #expect(consumed == 0)
        var altered = ciphertext
        altered[altered.count - 1] ^= 1
        try altered.write(to: file)
        var fullyAuthenticated = false
        #expect(throws: (any Error).self) {
            try SSDBlockStore.readStreaming(from: file, kekKey: key,
                maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes, maximumPlaintextBytes: 1 << 20,
                requireEOF: true, validateMetadata: { _ in }, consumeChunk: { _, _ in consumed += 1 })
            fullyAuthenticated = true
        }
        #expect(!fullyAuthenticated && consumed == chunks.count - 1)
        // A native importer must remain unpublished until this final full-file
        // authentication succeeds, and discard partial destinations on failure.
    }
}
