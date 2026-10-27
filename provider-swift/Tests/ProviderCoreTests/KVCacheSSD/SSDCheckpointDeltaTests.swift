import CryptoKit
import Foundation
import MLX
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Delta complete checkpoints", .serialized)
struct SSDCheckpointDeltaTests {
    /// K/V rows depend only on their row, as a causal prefix's do; whole
    /// tensors depend on the position, as recurrent state does.
    static func source(_ f: SSDHybridCheckpointTestFixture, _ position: Int) throws -> CBv2CompleteCheckpointExport {
        let manifest = try f.manifest(position: position)
        let arrays = manifest.tensors.enumerated().map { index, tensor in
            let width = tensor.shape.last!, rows = [.keys, .values].contains(tensor.role) ? tensor.shape[2] : 1
            return MLXArray((0..<tensor.byteCount / 4).map {
                rows == 1 ? Float(position + index) : Float(($0 / width) % rows * 10 + index) + Float($0 % width) / 100
            }).reshaped(tensor.shape)
        }
        eval(arrays)
        return .init(manifest: manifest, arrays: arrays, usesProcessMemoryOwner: false)
    }

    /// Stages request `id` (expecting `restores` tokens unless nil), lets the
    /// engine take the stage if `consume`, then donates `position`.
    @discardableResult
    static func turn(_ f: SSDHybridCheckpointTestFixture, _ store: SSDHybridCheckpointStore, id: Int,
                     restores: Int?, donates position: Int, consume: Bool = true) async throws -> [Int] {
        let request = CBv2RequestID(UInt64(id))
        if let restores {
            let result = await store.stage(requestID: request, request: f.request(),
                                           reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
            #expect(result.disposition == .staged(matchedTokens: restores, expectedPrefillTokensSaved: restores,
                                                  shortenedByCorruption: false))
            if consume {
                try #require(store.takeStaged(requestID: request, tokens: f.tokens, cacheSalt: "tenant-a",
                                              maximumSequenceLength: f.tokens.count + 8)).close()
            }
        }
        let source = try source(f, position)
        defer { store.completeStaging(requestID: request) }
        return await withCheckedContinuation { continuation in
            store.donate(source, requestID: request, tokens: f.tokens, cacheSalt: "tenant-a") { continuation.resume(returning: $0) }
        }
    }

    /// Streams `position` through its chain of `files` and compares every tensor with the complete export.
    static func expectExact(_ f: SSDHybridCheckpointTestFixture, _ store: SSDHybridCheckpointStore,
                            position: Int, files: Int) throws {
        let tag = store.lookupKeys.checkpointTag(
            chainHash: store.hashes(tokens: f.tokens, scope: "tenant-a")[position / 256 - 1], cacheSalt: "tenant-a")
        let chain = try #require(store.index.chain(tag16: Data(tag.prefix(16)))?.tags)
        #expect(chain.count == files)
        var opened = try store.openChain(.init(position: position, tag: tag, chain: chain, fileBytes: 0),
            tracksIdentity: true, check: {}, beforeRead: { _ in }, countRead: { _ in }, blame: { _ in })
        var received = opened[0].link.manifest.tensors.map { _ in Data() }
        #expect(try store.streamChain(&opened, check: {}, blame: { _ in }) { received[$0].append($2) } != nil)
        let expected = try source(f, position)
        for (index, tensor) in expected.manifest.tensors.enumerated() {
            #expect(received[index] == (try expected.readSegment(tensorIndex: index, byteOffset: 0, maximumBytes: tensor.byteCount)))
        }
        expected.close()
    }

    @Test("turns that consumed their restore write exact deltas; a full chain rebases onto its root",
          arguments: [true, false])
    func turnsWriteDeltas(paged: Bool) async throws {
        let f = try SSDHybridCheckpointTestFixture(paged: paged, tokenCount: 2305)
        defer { f.remove() }
        let store = try f.makeStore(incrementalCheckpoints: true)
        try await Self.turn(f, store, id: 1, restores: nil, donates: 256)
        let root = store.stats().bytesWritten
        for position in stride(from: 512, through: 2048, by: 256) {
            #expect(try await Self.turn(f, store, id: position, restores: position - 256, donates: position) == [position])
        }
        // Complete files would hold 2 + 3 + … + 8 roots of rows; deltas hold one each
        // (the contiguous fixture's rows are too small to outweigh its manifests).
        #expect(store.stats().deltaFilesWritten == 7)
        #expect(!paged || store.stats().bytesWritten - root < 8 * root)
        try Self.expectExact(f, store, position: 2048, files: 8)
        try await Self.turn(f, store, id: 2, restores: 2048, donates: 2304)
        try Self.expectExact(f, store, position: 2304, files: 2)
        // Another reader holding the shared root does not hold up this chain.
        let held = try #require(SSDCheckpointFileCoordinator.shared.tryAcquire(to: f.file(store, position: 256)))
        #expect(await store.stage(requestID: .init(4), request: f.request(), reserveReadScratch: f.reserveReadScratch,
                                  makeImportPlan: f.plan).staged)
        held.release()
        store.completeStaging(requestID: .init(4))
        await store.closeAndWait()
        let reopened = try f.makeStore(incrementalCheckpoints: true)
        try Self.expectExact(f, reopened, position: 2048, files: 8)
        #expect(try await Self.turn(f, reopened, id: 3, restores: nil, donates: 1024) == [1024])
        #expect(reopened.stats().filesWritten == 0 && reopened.stats().corruptDropped == 0)
        await reopened.closeAndWait()
        #expect(await f.budget.outstandingReservedBytes() == 0)
    }

    @Test("an untaken stage or the flag off writes complete files; a corrupt parent leaves its chain unusable")
    func completeAndCorrupt() async throws {
        for incremental in [true, false] {
            let f = try SSDHybridCheckpointTestFixture(paged: true, tokenCount: 1025)
            defer { f.remove() }
            let store = try f.makeStore(incrementalCheckpoints: incremental)
            try await Self.turn(f, store, id: 1, restores: nil, donates: 256)
            try await Self.turn(f, store, id: 2, restores: 256, donates: 512, consume: !incremental)
            try Self.expectExact(f, store, position: 512, files: 1)
            try await Self.turn(f, store, id: 3, restores: 512, donates: 768)
            #expect(store.stats().deltaFilesWritten == (incremental ? 1 : 0))
            // Flip the keys tag of the 512 file: every restore takes those rows.
            let file = f.file(store, position: 512)
            let sizes = try SSDBlockStore.readHeaderOnly(from: file).metadata.chunkPlaintextSizes
            var bytes = try Data(contentsOf: file)
            bytes[bytes.count - sizes.suffix(3).reduce(0) { $0 + 4 + $1 + 16 } - 1] ^= 1
            try bytes.write(to: file)
            let result = await store.stage(requestID: .init(4), request: f.request(),
                                           reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
            #expect(result.disposition == (incremental ? .missCorrupt : .staged(
                matchedTokens: 768, expectedPrefillTokensSaved: 768, shortenedByCorruption: false)))
            await store.closeAndWait()
            #expect(await f.budget.outstandingReservedBytes() == 0)
        }
    }

    @Test("a delta keeps only new rows of K/V and MTP history and commits to one exact parent file")
    func layout() throws {
        let identity = CBv2CompleteCheckpointIdentity(modelAggregateHash: "w", promptContractID: "t", buildID: "b", numericsFingerprint: "n")
        func manifest(_ position: Int, _ tokens: [Int] = Array(0..<1024)) throws -> CBv2CompleteCheckpointManifest {
            .init(identity: identity, position: position, chunkSize: 256, prefixTokens: Array(tokens.prefix(position)),
                  cacheSalt: "s", assistantCodecID: "mtp", tensors: [
                    try .init(role: .keys, layer: 0, shape: [1, 2, position, 4], dtype: .float16),
                    try .init(role: .recurrent, layer: 1, shape: [1, 2, 2, 2], dtype: .float32),
                    try .init(role: .assistantHidden, shape: [1, position - 1, 3], dtype: .bfloat16),
                  ], backendLayout: CBv2CompleteCheckpointManifest.pagedLayout)
        }
        let delta = try #require(SSDCheckpointDeltaLayout(parent: manifest(256), child: manifest(768)))
        #expect(delta.tensors.map(\.rows) == [.init(blocks: 2, start: 256, stored: 512, rowBytes: 8), nil,
                                              .init(blocks: 1, start: 255, stored: 512, rowBytes: 6)])
        #expect(try SSDCheckpointDeltaLayout(parent: manifest(256, Array(1..<1025)), child: manifest(768)) == nil)
        let chain = try [(256, 512), (512, 768)].map { try #require(SSDCheckpointDeltaLayout(parent: manifest($0), child: manifest($1))) }
        let steps = SSDCheckpointDeltaLayout.steps(root: try manifest(256), deltas: chain)
        #expect(steps[0].map(\.bytes) == Array(repeating: 256 * 8, count: 6) && steps[1].map(\.take) == [false, false, true])
        #expect(steps[2].map(\.bytes) == [255 * 6, 256 * 6, 256 * 6])

        let f = try SSDHybridCheckpointTestFixture(paged: true)
        defer { f.remove() }
        let tag = Data(repeating: 1, count: 32), iv = Data(repeating: 2, count: 12), keys = SSDLookupKeys(kek: f.key)
        let commitment = keys.checkpointParentCommitmentHex(parentTag: tag, parentFileIV: iv)
        #expect(commitment != keys.checkpointParentCommitmentHex(parentTag: tag, parentFileIV: Data(count: 12)))
        #expect(commitment != SSDLookupKeys(kek: SymmetricKey(size: .bits256)).checkpointParentCommitmentHex(parentTag: tag, parentFileIV: iv))
        let complete = try SSDHybridCheckpointEnvelope(manifest: f.manifest(position: 512), maximumPlaintextBytes: 1 << 24)
        let metadata = complete.metadata(tag: tag, identity: f.identity, createdAt: 1, backendLayout: f.backendLayout)
        #expect(!String(decoding: try SSDBlockStore.canonicalEncode(metadata), as: UTF8.self).contains("parent"))
    }
}
