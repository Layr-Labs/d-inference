import CryptoKit
import Foundation
import MLX
@testable import MLXLMCommon
import Testing

@testable import ProviderCore

/// Complete checkpoints store a keyed digest of their prefix instead of its
/// token IDs, and an MTP assistant's token tensor as zeros; a restore rebuilds
/// both from the request's own prompt.
@Suite("Complete checkpoints hold no token IDs", .serialized)
struct CheckpointTokenFreeStorageTests {
    private static let position = 512

    /// The fixture's manifest at `position` with an MTP assistant's history
    /// (hidden rows, the prefix's tokens `[1, position)`, the frontier row).
    private func source(
        _ fixture: SSDHybridCheckpointTestFixture, assistantTokens: [Int32]? = nil
    ) throws -> CBv2CompleteCheckpointExport {
        let position = Self.position
        let target = try fixture.codec.tensorDescriptors(position: position)
        let assistant: [CBv2CheckpointTensorDescriptor] = [
            try .init(role: .assistantHidden, shape: [1, position - 1, 4], dtype: .float32),
            try .init(role: .assistantTokens, shape: [1, position - 1], dtype: .int32),
            try .init(role: .assistantFrontier, shape: [1, 1, 4], dtype: .float32),
        ]
        let manifest = CBv2CompleteCheckpointManifest(
            identity: fixture.identity, position: position, chunkSize: 256,
            prefixTokens: Array(fixture.tokens.prefix(position)), cacheSalt: "tenant-a",
            assistantCodecID: "fixture-assistant", tensors: target + assistant,
            backendLayout: fixture.backendLayout)
        let tokens = assistantTokens ?? fixture.tokens[1..<position].map(Int32.init)
        let arrays = target.enumerated().map { index, tensor in
            MLXArray(Array(repeating: Float(index + 1), count: tensor.byteCount / 4)).reshaped(tensor.shape)
        } + [
            MLXArray(Array(repeating: Float(0.5), count: (position - 1) * 4)).reshaped([1, position - 1, 4]),
            MLXArray(tokens).reshaped([1, position - 1]),
            MLXArray(Array(repeating: Float(0.25), count: 4)).reshaped([1, 1, 4]),
        ]
        eval(arrays)
        return .init(manifest: manifest, arrays: arrays)
    }

    /// Every chunk's plaintext, authenticated, in file order.
    private func plaintext(_ file: URL, key: SymmetricKey) throws -> [Data] {
        var chunks: [Data] = []
        try SSDBlockStore.readStreaming(from: file, kekKey: key,
            maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes,
            maximumPlaintextBytes: 16 << 20, requireEOF: true,
            validateMetadata: { _ in }, consumeChunk: { _, data in chunks.append(data) })
        return chunks
    }

    /// A run of the prefix's tokens in every encoding the code could store:
    /// JSON decimal text, 16, 32 and 64-bit integers in either byte order.
    private func encodings(of run: [Int]) -> [(String, Data)] {
        func bytes<T: FixedWidthInteger>(_ type: T.Type, bigEndian: Bool) -> Data {
            var out = Data()
            for value in run {
                let integer = T(truncatingIfNeeded: value)
                withUnsafeBytes(of: bigEndian ? integer.bigEndian : integer.littleEndian) { out.append(contentsOf: $0) }
            }
            return out
        }
        return [
            ("json", Data(run.map(String.init).joined(separator: ",").utf8)),
            ("u16le", bytes(UInt16.self, bigEndian: false)), ("u16be", bytes(UInt16.self, bigEndian: true)),
            ("i32le", bytes(Int32.self, bigEndian: false)), ("i32be", bytes(Int32.self, bigEndian: true)),
            ("i64le", bytes(Int64.self, bigEndian: false)), ("i64be", bytes(Int64.self, bigEndian: true)),
        ]
    }

    @Test("a written file holds no token ID, in any integer width, in its header, manifest or tensors")
    func aWrittenFileHoldsNoTokenIDs() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(paged: true)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        defer { store.close() }
        let written = try source(fixture)
        #expect(await fixture.donate(store, written, receipt: 21) == [Self.position])
        let file = fixture.file(store, position: Self.position)
        let chunks = try plaintext(file, key: fixture.key)
        let raw = try Data(contentsOf: file)
        // The fixture's prompt cycles 0...30: a run of 16 of them anywhere is token IDs.
        let run = Array(fixture.tokens[1...16])
        for (name, encoding) in encodings(of: run) {
            #expect(raw.range(of: encoding) == nil, "file bytes hold the prefix as \(name)")
            for (index, chunk) in chunks.enumerated() {
                #expect(chunk.range(of: encoding) == nil, "chunk \(index) holds the prefix as \(name)")
            }
        }
        let manifest = try #require(String(data: chunks[0], encoding: .utf8))
        #expect(manifest.contains("\"prefixDigest\"") && !manifest.contains("prefixTokens"))
        // The token tensor's segment is stored as zeros, with its full size.
        let envelope = try SSDHybridCheckpointEnvelope(
            manifest: written.manifest, lookupKeys: store.lookupKeys, maximumPlaintextBytes: 16 << 20)
        let tokensIndex = try #require(envelope.segments.firstIndex {
            written.manifest.tensors[$0.tensor].role == .assistantTokens
        })
        #expect(chunks[tokensIndex + 1] == Data(count: (Self.position - 1) * 4))
    }

    @Test("a restore proves the prefix by its digest and rebuilds the token tensor from the prompt")
    func aRestoreRebuildsTheTokens() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(paged: true)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        defer { store.close() }
        let original = try source(fixture)
        #expect(await fixture.donate(store, original, receipt: 21) == [Self.position])
        let tag = store.lookupKeys.checkpointTag(
            chainHash: store.hashes(tokens: fixture.tokens, scope: "tenant-a")[Self.position / 256 - 1],
            cacheSalt: "tenant-a")
        let chain = try #require(store.index.chain(tag16: Data(tag.prefix(16)))?.tags)
        let candidate = SSDHybridCheckpointStore.ReadCandidate(
            position: Self.position, tag: tag, chain: chain, fileBytes: 0)
        var files = try store.openChain(candidate, promptTokens: fixture.tokens, tracksIdentity: true,
            check: {}, beforeRead: { _ in }, countRead: { _ in }, blame: { _ in })
        let manifest = try #require(files.last?.link.manifest)
        #expect(manifest == original.manifest, "the prefix comes back from the request's prompt")
        var received = manifest.tensors.map { _ in Data() }
        #expect(try store.streamChain(&files, parallel: false, check: {}, blame: { _ in }) {
            received[$0].append($2)
        } != nil)
        // The donation closed its source; an identical one supplies the expected bytes.
        let expected = try source(fixture)
        for (index, tensor) in manifest.tensors.enumerated() {
            #expect(received[index] == (try expected.readSegment(
                tensorIndex: index, byteOffset: 0, maximumBytes: tensor.byteCount)), "tensor \(index)")
        }

        // Another prompt that reached the same file is refused by its digest.
        var other = fixture.tokens
        other[100] += 1
        #expect(throws: CBv2CompleteCheckpointError.incompatibleCheckpoint) {
            _ = try store.openChain(candidate, promptTokens: other, tracksIdentity: false,
                check: {}, beforeRead: { _ in }, countRead: { _ in }, blame: { _ in })
        }
    }

    @Test("a token tensor that is not the prefix's last tokens is never written")
    func aMismatchedTokenTensorIsRefused() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(paged: true)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        defer { store.close() }
        let wrong = (1..<Self.position).map { Int32(1_000 + $0) }
        #expect(try await fixture.donate(store, source(fixture, assistantTokens: wrong), receipt: 21).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.file(store, position: Self.position).path))
    }

    @Test("format 1 chunk 0, which held token IDs, is refused")
    func formatOneIsRefused() throws {
        let fixture = try SSDHybridCheckpointTestFixture(paged: true)
        defer { fixture.remove() }
        let manifest = try fixture.manifest(position: 256)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let formatOne = try encoder.encode(manifest)
        let keys = SSDLookupKeys(kek: fixture.key)
        #expect(throws: CBv2CompleteCheckpointError.invalidManifest) {
            _ = try SSDHybridCheckpointEnvelope.decodeManifest(formatOne, promptTokens: fixture.tokens, lookupKeys: keys)
        }
        // The same manifest stored today round-trips.
        let stored = try SSDHybridCheckpointEnvelope.storedManifestBytes(manifest, lookupKeys: keys)
        #expect(try SSDHybridCheckpointEnvelope.decodeManifest(stored, promptTokens: fixture.tokens, lookupKeys: keys)
                == manifest)
        // Under another install's key the digest does not match.
        #expect(throws: CBv2CompleteCheckpointError.incompatibleCheckpoint) {
            _ = try SSDHybridCheckpointEnvelope.decodeManifest(
                stored, promptTokens: fixture.tokens, lookupKeys: SSDLookupKeys(kek: SymmetricKey(size: .bits256)))
        }
    }

    @Test("the model directory keeps its name, and each format's epoch record removes the other's files",
          arguments: [true, false])
    func theEpochRecordRemovesTheOtherFormatsFiles(update: Bool) throws {
        let fixture = try SSDHybridCheckpointTestFixture(paged: true)
        defer { fixture.remove() }
        let identity = fixture.identity, layout = fixture.backendLayout
        // Format 1's epoch, as builds before this change compute it.
        var formatOne = Data("darkbloom-complete-checkpoint-envelope-v1".utf8)
        for value in [identity.modelAggregateHash, identity.promptContractID, identity.buildID,
                      identity.numericsFingerprint, layout] {
            withUnsafeBytes(of: UInt64(value.utf8.count).littleEndian) { formatOne.append(contentsOf: $0) }
            formatOne.append(contentsOf: value.utf8)
        }
        let formatOneEpoch = Data(SHA256.hash(data: formatOne)).hexString
        #expect(SSDHybridCheckpointEnvelope.directoryEpoch(identity: identity, backendLayout: layout) == formatOneEpoch)
        #expect(SSDHybridCheckpointEnvelope.layoutEpoch(identity: identity, backendLayout: layout) != formatOneEpoch)
        func binding(_ layoutEpoch: String) -> SSDCacheEpochStore.Binding {
            .init(modelId: "fixture-model", modelAggregateHash: identity.modelAggregateHash,
                  promptContractId: identity.promptContractID, blockHashVersion: CBv2BlockHasher.version,
                  blockSize: PrefixCachePolicy.blockSize, layoutEpoch: layoutEpoch, keyFingerprint: "fixture-key")
        }
        let current = SSDHybridCheckpointEnvelope.layoutEpoch(identity: identity, backendLayout: layout)
        // An update finds format 1's record; a rollback finds today's.
        let (written, reader) = update ? (formatOneEpoch, current) : (current, formatOneEpoch)
        let first = try SSDCacheEpochStore(root: fixture.modelRoot, binding: binding(written))
        let file = SSDBlockStore.fileURL(root: fixture.modelRoot, tag16Hex: String(repeating: "ab", count: 16))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64).write(to: file)
        let second = try SSDCacheEpochStore(root: fixture.modelRoot, binding: binding(reader))
        #expect(!FileManager.default.fileExists(atPath: file.path), "the other format's file is gone at open")
        #expect(second.current != nil && second.current != first.current)
    }

    @Test("a fixed TTL leaves a restored checkpoint's last use at its write", arguments: [false, true])
    func fixedTTLKeepsTheWriteTime(fixed: Bool) async throws {
        let fixture = try SSDHybridCheckpointTestFixture(paged: true)
        defer { fixture.remove() }
        let store = try fixture.makeStore(ttlMode: fixed ? .fixed : .sliding)
        defer { store.close() }
        #expect(try await fixture.donate(store, receipt: 10, position: 256) == [256])
        let tag16 = Data(store.lookupKeys.checkpointTag(
            chainHash: store.hashes(tokens: fixture.tokens, scope: "tenant-a")[0], cacheSalt: "tenant-a").prefix(16))
        let written = try #require(store.index.lastAccess(tag16: tag16))
        try await Task.sleep(for: .milliseconds(1_100))
        var request = fixture.request()
        request.prefixCacheReceiptID = .init(12)
        let staged = await store.stage(requestID: .init(12), request: request,
                                       reserveReadScratch: fixture.reserveReadScratch, makeImportPlan: fixture.plan)
        #expect(staged.staged)
        store.completeStaging(requestID: .init(12))
        let used = try #require(store.index.lastAccess(tag16: tag16))
        #expect(fixed ? used == written : used > written)
    }
}
