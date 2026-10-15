import CryptoKit
import Foundation
import MLX
import Testing

@testable import MLXLMCommon
@testable import ProviderCore

/// Requires the actual target/engine/row integration. Fixture-key reopening is
/// intentionally distinct from real Keychain, native MTP and full-model gates.
@Suite("GLM5Next real encrypted target checkpoints", .serialized)
struct GLM5NextEncryptedCheckpointTests {
    private func withFixture(
        _ body: (GLM5NextCheckpointFixture) async throws -> Void
    ) async throws {
        let fixture = try GLM5NextCheckpointFixture()
        do { try await body(fixture) }
        catch {
            await fixture.close()
            fixture.remove()
            throw error
        }
        await fixture.close()
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
        fixture.remove()
    }

    private func requireCodec(_ engine: EngineV2) throws {
        let codec = try #require(engine.completeCheckpointCodec,
            "real GLM model/engine complete-prefix registration is required")
        #expect(codec.backendLayout == CBv2CompleteCheckpointManifest.glm5NextPagedLayout)
        #expect(codec.glm5NextLayout != nil)
        #expect(codec.assistant == nil, "this is the target-only encrypted-store component gate")
    }

    @Test("real 1024-token prefill survives encrypted fresh-store reopen with equal frontier logits")
    func encryptedFreshStoreRestoration() async throws {
        try await withFixture { fixture in
            let writer = try fixture.makeStore()
            let producer = try fixture.makeEngine(store: writer)
            try requireCodec(producer)
            #expect(writer.config.minEffectiveTokens == 1024)
            #expect(GLM5NextCheckpointFixture.boundary.isMultiple(of: PrefixCachePolicy.blockSize))
            #expect(!writer.acceptsCheckpoint(position: 768, packedBytes: 1024))
            #expect(!writer.acceptsCheckpoint(position: 1023, packedBytes: 1024))
            #expect(!writer.acceptsCheckpoint(position: 1025, packedBytes: 1024))
            #expect(writer.acceptsCheckpoint(position: 1024, packedBytes: 1024))

            let request = fixture.request(id: 501)
            let expected = try await fixture.run(engine: producer, request: request)
            await writer.waitForWritesForTesting()
            #expect(writer.stats().filesWritten == 1)
            #expect(writer.stats().maximumSegmentBytes <= CBv2CompleteCheckpointManifest.maximumSegmentBytes)
            let file = try fixture.file(store: writer)
            let ciphertext = try Data(contentsOf: file)
            #expect(Array(ciphertext.prefix(4)) == SSDBlockStore.magic)
            #expect(throws: (any Error).self) {
                try SSDBlockStore.readStreaming(from: file, kekKey: SymmetricKey(size: .bits256),
                    maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes,
                    maximumPlaintextBytes: writer.config.maxReadBytes, requireEOF: true,
                    validateMetadata: { _ in }, consumeChunk: { _, _ in
                        Issue.record("a foreign fixture key exposed plaintext")
                    })
            }
            var manifestBytes: Data?
            var manifest: CBv2CompleteCheckpointManifest?
            var chunkCount = 0
            try SSDBlockStore.readStreaming(from: file, kekKey: fixture.key,
                maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes,
                maximumPlaintextBytes: writer.config.maxReadBytes, requireEOF: true,
                validateMetadata: { metadata in
                    #expect(metadata.layoutEpoch == SSDHybridCheckpointEnvelope.layoutEpoch(
                        identity: fixture.identity, backendLayout: CBv2CompleteCheckpointManifest.glm5NextPagedLayout))
                }, consumeChunk: { index, bytes in
                    chunkCount += 1
                    if index == 0 {
                        manifestBytes = bytes
                        manifest = try SSDHybridCheckpointEnvelope.decodeManifest(bytes)
                    }
                })
            let saved = try #require(manifest)
            #expect(saved.position == 1024 && saved.prefixTokens == Array(fixture.tokens.prefix(1024)))
            #expect(saved.glm5NextState?.physicalPosition == 1024)
            #expect(saved.glm5NextState?.acceptedFrontier == 1024)
            #expect(saved.tensors.filter { $0.role == .convolution }.count == 3)
            #expect(saved.tensors.filter { $0.role == .recurrent }.count == 3)
            #expect(saved.tensors.allSatisfy { $0.dtype == .float32 })
            #expect(saved.assistantCodecID == nil)
            #expect(chunkCount > 1)
            let plaintextManifest = try #require(manifestBytes)
            #expect(ciphertext.range(of: plaintextManifest) == nil)
            let originalEpoch = writer.config.epochStore?.current
            await producer.shutdown()
            await writer.closeAndWait()

            let reader = try fixture.makeStore() // same fixture key, NEW store and native engine
            #expect(reader !== writer && reader.stats().entries == 1)
            #expect(reader.config.epochStore?.current == originalEpoch)
            let consumer = try fixture.makeEngine(store: reader)
            try requireCodec(consumer)
            let foreign = fixture.request(id: 502, scope: "tenant-b")
            let miss = await fixture.stage(store: reader, engine: consumer, request: foreign)
            #expect(miss.disposition == .missAbsent && reader.stats().filesRead == 0)
            let resumed = fixture.request(id: 503)
            let staged = await fixture.stage(store: reader, engine: consumer, request: resumed)
            try #require(staged.staged)
            #expect(staged.deviceBytes > 0 && reader.stats().filesRead >= 2)
            let position = reader.lock.withLock { reader.stages[resumed.prefixCacheReceiptID!]?.manifest.position }
            #expect(position == 1024)
            let actual = try await fixture.run(engine: consumer, request: resumed)
            #expect(actual.tokens == expected.tokens)
            #expect(actual.logits.count == expected.logits.count && !actual.logits.isEmpty)
            #expect(zip(actual.logits, expected.logits).allSatisfy { abs($0.0 - $0.1) < 0.00001 })
            #expect(actual.usage.prefixCachePrefillTokensSaved == 1024)
            #expect(actual.usage.prefixCacheReplayTokens == 0)
            #expect(reader.stats().stageConsumptions == 1)
            #expect(reader.stats().maximumSegmentBytes > 0
                && reader.stats().maximumSegmentBytes <= CBv2CompleteCheckpointManifest.maximumSegmentBytes)
            #expect(try Data(contentsOf: file) == ciphertext, "authenticated reuse must not rewrite ciphertext")
        }
    }

    @Test("authenticated identity changes and malformed ciphertext never expose a stage")
    func rejectsIdentityAndCiphertextChanges() async throws {
        try await withFixture { fixture in
            let writer = try fixture.makeStore()
            let producer = try fixture.makeEngine(store: writer)
            try requireCodec(producer)
            _ = try await fixture.run(engine: producer, request: fixture.request(id: 601))
            await writer.waitForWritesForTesting()
            #expect(writer.stats().filesWritten == 1)
            let file = try fixture.file(store: writer)
            let pristine = try Data(contentsOf: file)
            await producer.shutdown()
            await writer.closeAndWait()

            for (offset, fault) in Fault.allCases.enumerated() {
                try pristine.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                let reader = try fixture.makeStore()
                let consumer = try fixture.makeEngine(store: reader)
                try requireCodec(consumer)
                let originalEpoch = reader.config.epochStore?.current
                try corrupt(fault, file: file, fixture: fixture, store: reader)
                let request = fixture.request(id: UInt64(610 + offset))
                let result = await fixture.stage(store: reader, engine: consumer, request: request)
                #expect(result.disposition == .missCorrupt)
                #expect(reader.takeStaged(requestID: request.prefixCacheReceiptID!, tokens: request.promptTokens,
                    cacheSalt: request.cacheSalt, maximumSequenceLength: request.promptTokens.count + request.maxTokens) == nil)
                #expect(reader.stats().stageConsumptions == 0 && reader.stats().corruptDropped == 1)
                #expect(reader.config.epochStore?.current == originalEpoch,
                    "a corrupt file does not rotate the entire model epoch")
                await consumer.shutdown()
                await reader.closeAndWait()
                #expect(reader.stats().stagedBytesInUse == 0)
            }
        }
    }

    private enum Fault: String, CaseIterable {
        case modelAggregateHash, promptContractID, buildID, numericsFingerprint
        case missingRecurrentState, lateCiphertext, truncatedCiphertext
    }

    private func corrupt(_ fault: Fault, file: URL, fixture: GLM5NextCheckpointFixture,
                         store: SSDHybridCheckpointStore) throws {
        if fault == .lateCiphertext || fault == .truncatedCiphertext {
            var bytes = try Data(contentsOf: file)
            if fault == .lateCiphertext { bytes[bytes.count - 1] ^= 1 }
            else { bytes.removeLast() }
            try bytes.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return
        }
        // Keep the ACTUAL target payload, re-sealed by the existing DBK3 writer.
        // Only authenticated metadata is altered, so rejection tests the loaded
        // identity/full-state contract rather than relying solely on GCM failure.
        var chunks: [Data] = []
        var metadata: SSDBlockMetadata?
        try SSDBlockStore.readStreaming(from: file, kekKey: fixture.key,
            maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes,
            maximumPlaintextBytes: store.config.maxReadBytes, requireEOF: true,
            validateMetadata: { metadata = $0 }, consumeChunk: { _, bytes in chunks.append(bytes) })
        var object = try #require(JSONSerialization.jsonObject(with: chunks[0]) as? [String: Any])
        if fault == .missingRecurrentState {
            var tensors = try #require(object["tensors"] as? [[String: Any]])
            tensors.removeLast()
            object["tensors"] = tensors
        } else {
            var identity = try #require(object["identity"] as? [String: Any])
            identity[fault.rawValue] = "different-verified-identity"
            object["identity"] = identity
        }
        chunks[0] = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        let previous = try #require(metadata)
        let rewritten = SSDBlockMetadata(lookupTag: previous.lookupTag, weightHash: previous.weightHash,
            layoutEpoch: previous.layoutEpoch, blockSize: previous.blockSize, layerCount: previous.layerCount,
            chunks: chunks.enumerated().map {
                .init(layerIndex: 0, tensor: $0.offset, shape: [$0.element.count], dtype: "uint8")
            }, chunkPlaintextSizes: chunks.map(\.count), createdAt: previous.createdAt)
        _ = try SSDBlockStore.writeStreaming(to: file, metadata: rewritten, kekKey: fixture.key,
            maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes) { chunks[$0] }
    }
}
