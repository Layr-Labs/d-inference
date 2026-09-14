import Foundation
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Complete checkpoint duplicate validation", .serialized)
struct SSDHybridCheckpointDuplicateTests {
    @Test("different valid prefill geometries preserve the original checkpoint and epoch",
          arguments: [false, true], [512, 2048])
    func differentChunkSizes(paged: Bool, storedChunkSize: Int) async throws {
        let fixture = try SSDHybridCheckpointTestFixture(paged: paged, tokenCount: 4097)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        let position = 2048
        let incomingChunkSize = storedChunkSize == 512 ? 2048 : 512
        #expect(try await fixture.donate(store, position: position, chunkSize: storedChunkSize) == [position])
        let file = fixture.file(store, position: position)
        let before = try Data(contentsOf: file)
        let epoch = store.config.epochStore?.current

        // Neither submission has staged the file: the second donation must
        // authenticate the first execution's complete checkpoint from disk.
        #expect(try await fixture.donate(store, receipt: 11, position: position,
                                        chunkSize: incomingChunkSize) == [position])
        #expect(try Data(contentsOf: file) == before)
        #expect(store.config.epochStore?.current == epoch)
        #expect(store.stats().entries == 1)
        #expect(store.stats().filesWritten == 1)
        #expect(store.stats().filesRead == 1)
        #expect(store.stats().donationReadBytes > 0)
        #expect(store.stats().corruptDropped == 0)

        let request = fixture.request()
        let staged = await store.stage(requestID: .init(12), request: request,
                                       reserveReadScratch: fixture.reserveReadScratch) { manifest in
            try fixture.codec.plan(manifest: manifest, request: request,
                                   minimumChunkSize: 256, maximumChunkSize: 2048)
        }
        #expect(staged.staged)
        let checkpoint = try #require(store.takeStaged(
            requestID: .init(12), tokens: fixture.tokens, cacheSalt: "tenant-a",
            maximumSequenceLength: fixture.tokens.count + request.maxTokens))
        #expect(checkpoint.manifest.chunkSize == storedChunkSize)
        #expect(checkpoint.manifest.position == position)
        checkpoint.close()
        await store.closeAndWait()
        #expect(store.stats().stagedBytesInUse == 0)
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
    }

    enum InvalidStoredCheckpoint: String, CaseIterable, Sendable {
        case wrongScope, wrongPrefix, wrongRuntimeIdentity, wrongAssistantCodec
        case missingRecurrentState, wrongBoundary, missingFinalSegment
        case lateCorruption, truncatedPayload, trailingBytes
    }

    @Test("different geometry does not excuse invalid identity, missing state, or incomplete authentication",
          arguments: InvalidStoredCheckpoint.allCases)
    func invalidStoredCheckpoint(_ fault: InvalidStoredCheckpoint) async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 4097)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        let position = 2048
        #expect(try await fixture.donate(store, position: position, chunkSize: 512) == [position])
        let file = fixture.file(store, position: position)
        let epoch = store.config.epochStore?.current
        try replaceStoredCheckpoint(fault, fixture: fixture, store: store, position: position)

        #expect(try await fixture.donate(store, receipt: 21, position: position, chunkSize: 2048).isEmpty)
        #expect(store.config.epochStore?.current != epoch)
        #expect(store.stats().filesWritten == 1)
        #expect(store.stats().entries == 0)
        #expect(store.stats().corruptDropped == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        await store.closeAndWait()
        #expect(store.stats().stagedBytesInUse == 0)
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
    }

    private func replaceStoredCheckpoint(
        _ fault: InvalidStoredCheckpoint, fixture: SSDHybridCheckpointTestFixture,
        store: SSDHybridCheckpointStore, position: Int
    ) throws {
        let file = fixture.file(store, position: position)
        switch fault {
        case .lateCorruption, .truncatedPayload, .trailingBytes:
            var bytes = try Data(contentsOf: file)
            switch fault {
            case .lateCorruption: bytes[bytes.count - 1] ^= 1
            case .truncatedPayload: bytes.removeLast()
            case .trailingBytes: bytes.append(0)
            default: break
            }
            try bytes.write(to: file, options: .atomic)
        default:
            let storedPosition = fault == .wrongBoundary ? 1024 : position
            let original = try fixture.manifest(position: storedPosition, chunkSize: 512)
            var tokens = original.prefixTokens
            if fault == .wrongPrefix { tokens[0] += 1 }
            let identity = fault == .wrongRuntimeIdentity
                ? CBv2CompleteCheckpointIdentity(
                    modelAggregateHash: fixture.identity.modelAggregateHash,
                    promptContractID: fixture.identity.promptContractID,
                    buildID: fixture.identity.buildID, numericsFingerprint: "another-runtime")
                : fixture.identity
            let manifest = CBv2CompleteCheckpointManifest(
                identity: identity, position: storedPosition, chunkSize: original.chunkSize,
                prefixTokens: tokens, cacheSalt: fault == .wrongScope ? "tenant-b" : original.cacheSalt,
                assistantCodecID: fault == .wrongAssistantCodec ? "another-assistant" : nil,
                tensors: fault == .missingRecurrentState ? Array(original.tensors.dropLast()) : original.tensors,
                backendLayout: original.backendLayout)
            let envelope = try SSDHybridCheckpointEnvelope(manifest: manifest, maximumPlaintextBytes: 16 << 20)
            let chain = store.hashes(tokens: fixture.tokens, scope: "tenant-a")
            let tag = store.lookupKeys.checkpointTag(chainHash: chain[position / 256 - 1], cacheSalt: "tenant-a")
            let metadata = envelope.metadata(tag: tag, identity: fixture.identity,
                                             createdAt: store.config.nowSeconds(), backendLayout: fixture.backendLayout)
            let header: SSDBlockMetadata
            if fault == .missingFinalSegment {
                // Every declared chunk is authenticated, but the manifest's
                // final tensor segment is absent from the public envelope.
                header = SSDBlockMetadata(
                    lookupTag: metadata.lookupTag, weightHash: metadata.weightHash,
                    layoutEpoch: metadata.layoutEpoch, blockSize: metadata.blockSize,
                    layerCount: metadata.layerCount, chunks: Array(metadata.chunks.dropLast()),
                    chunkPlaintextSizes: Array(metadata.chunkPlaintextSizes.dropLast()),
                    createdAt: metadata.createdAt)
            } else {
                header = metadata
            }
            _ = try SSDBlockStore.writeStreaming(
                to: file, metadata: header, kekKey: fixture.key,
                maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes
            ) { index in
                index == 0 ? envelope.manifestBytes : Data(count: envelope.segments[index - 1].bytes)
            }
        }
    }
}
