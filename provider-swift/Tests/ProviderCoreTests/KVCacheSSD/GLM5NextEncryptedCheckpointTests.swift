import CryptoKit
import Foundation
import MLX
import Testing

@testable import MLXLMCommon
@testable import ProviderCore

/// Requires the actual target/engine/row integration. Fixture-key reopening is
/// intentionally distinct from real Keychain and full-model qualification.
@Suite("GLM5Next real encrypted target checkpoints", .serialized)
struct GLM5NextEncryptedCheckpointTests {
    private func withFixture(
        _ body: (GLM5NextCheckpointFixture) async throws -> Void
    ) async throws {
        let fixture = try GLM5NextCheckpointFixture()
        let outcome: Result<Void, any Error>
        do { try await body(fixture); outcome = .success(()) }
        catch { outcome = .failure(error) }
        do {
            try await fixture.close()
            #expect(await fixture.budget.outstandingReservedBytes() == 0)
            try fixture.remove()
        } catch {
            if case .failure(let bodyError) = outcome {
                Issue.record("Test body also failed before cleanup: \(bodyError)")
            }
            throw error
        }
        try outcome.get()
    }

    private func requireCodec(_ engine: EngineV2, withMTP: Bool = false) throws {
        let codec = try #require(engine.completeCheckpointCodec,
            "real GLM model/engine complete-prefix registration is required")
        #expect(codec.backendLayout == CBv2CompleteCheckpointManifest.glm5NextPagedLayout)
        #expect(codec.glm5NextLayout != nil)
        #expect((codec.assistant != nil) == withMTP)
        if withMTP { #expect(codec.isNativePagedGLM5Next) }
    }

    @Test("real 1024-token prefill survives encrypted fresh-store reopen with equal frontier logits", arguments: [false, true])
    func encryptedFreshStoreRestoration(withMTP: Bool) async throws {
        try await withFixture { fixture in
            let writer = try fixture.makeStore()
            let producer = try fixture.makeEngine(store: writer, withMTP: withMTP)
            try requireCodec(producer, withMTP: withMTP)
            #expect(writer.config.minEffectiveTokens == 1024)
            #expect(GLM5NextCheckpointFixture.boundary.isMultiple(of: PrefixCachePolicy.blockSize))
            #expect(!writer.acceptsCheckpoint(position: 768, packedBytes: 1024))
            #expect(!writer.acceptsCheckpoint(position: 1023, packedBytes: 1024))
            #expect(!writer.acceptsCheckpoint(position: 1025, packedBytes: 1024))
            #expect(writer.acceptsCheckpoint(position: 1024, packedBytes: 1024))

            // Leave room for a real draft/verification round after the seed token.
            let maxTokens = withMTP ? 4 : 2
            let request = fixture.request(id: 501, maxTokens: maxTokens)
            let expected = try await fixture.run(engine: producer, request: request, expectMTP: withMTP)
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
            #expect(saved.tensors.filter { [.keys, .values, .convolution, .recurrent].contains($0.role) }
                .allSatisfy { $0.dtype == .float32 })
            #expect((saved.assistantCodecID != nil) == withMTP)
            if withMTP {
                #expect(saved.assistantCodecID == "glm5next-mtp-contiguous-prefix-v1")
                #expect(saved.tensors.count == 14) // two DSA arrays + six KDA + six real MTP arrays
            }
            #expect(chunkCount > 1)
            let plaintextManifest = try #require(manifestBytes)
            #expect(ciphertext.range(of: plaintextManifest) == nil)
            let originalEpoch = writer.config.epochStore?.current
            try await fixture.retire(producer)
            await writer.closeAndWait()

            let reader = try fixture.makeStore() // same fixture key, NEW store and native engine
            #expect(reader !== writer && reader.stats().entries == 1)
            #expect(reader.config.epochStore?.current == originalEpoch)
            let consumer = try fixture.makeEngine(store: reader, withMTP: withMTP)
            try requireCodec(consumer, withMTP: withMTP)
            let foreign = fixture.request(id: 502, scope: "tenant-b", maxTokens: maxTokens)
            let miss = await fixture.stage(store: reader, engine: consumer, request: foreign)
            #expect(miss.disposition == .missAbsent && reader.stats().filesRead == 0)
            let resumed = fixture.request(id: 503, maxTokens: maxTokens)
            let staged = await fixture.stage(store: reader, engine: consumer, request: resumed)
            try #require(staged.staged)
            #expect(staged.deviceBytes > 0 && reader.stats().filesRead >= 2)
            let position = reader.lock.withLock { reader.stages[resumed.prefixCacheReceiptID!]?.manifest.position }
            #expect(position == 1024)
            let actual = try await fixture.run(engine: consumer, request: resumed, expectMTP: withMTP)
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

    @Test("authenticated identity changes and malformed ciphertext never expose a stage", arguments: [false, true])
    func rejectsIdentityAndCiphertextChanges(withMTP: Bool) async throws {
        try await withFixture { fixture in
            let writer = try fixture.makeStore()
            let producer = try fixture.makeEngine(store: writer, withMTP: withMTP)
            try requireCodec(producer, withMTP: withMTP)
            _ = try await fixture.run(engine: producer,
                request: fixture.request(id: 601, maxTokens: withMTP ? 4 : 2), expectMTP: withMTP)
            await writer.waitForWritesForTesting()
            #expect(writer.stats().filesWritten == 1)
            let file = try fixture.file(store: writer)
            let pristine = try Data(contentsOf: file)
            try await fixture.retire(producer)
            await writer.closeAndWait()

            for (offset, fault) in Fault.allCases.enumerated() {
                try pristine.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                let reader = try fixture.makeStore()
                let consumer = try fixture.makeEngine(store: reader, withMTP: withMTP)
                try requireCodec(consumer, withMTP: withMTP)
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
                try await fixture.retire(consumer)
                await reader.closeAndWait()
                #expect(reader.stats().stagedBytesInUse == 0)
            }
        }
    }

    private enum Fault: String, CaseIterable {
        case modelAggregateHash, promptContractID, buildID, numericsFingerprint
        case missingRecurrentState, lateCiphertext, truncatedCiphertext
    }

    @Test("cancel after protected MTP copy fence publishes no state and permits fresh-generation reuse")
    func protectedImportCancellationAndReuse() async throws {
        try await withFixture { fixture in
            let writer = try fixture.makeStore()
            let producer = try fixture.makeEngine(store: writer, withMTP: true)
            try requireCodec(producer, withMTP: true)
            let expected = try await fixture.run(engine: producer,
                request: fixture.request(id: 701, maxTokens: 4), expectMTP: true)
            await writer.waitForWritesForTesting()
            #expect(writer.stats().filesWritten == 1)
            try await fixture.retire(producer)
            await writer.closeAndWait()

            let reader = try fixture.makeStore()
            let consumer = try fixture.makeEngine(store: reader, withMTP: true)
            try requireCodec(consumer, withMTP: true)
            let loop = consumer.loopForTesting
            let baseline = loop.onEngineQueueSync { consumer.admissionForTesting.bytesReserved }
            let issuer = try loop.onEngineQueueSync { try #require(loop.mtp?.admittedMTPBindingIssuer) }
            var request = fixture.request(id: 702, maxTokens: 4)
            let requestID = request.id
            let initialStage = await fixture.stage(store: reader, engine: consumer, request: request)
            try #require(initialStage.staged)
            var preparedCount = 0
            var adoptedCount = 0
            var previousGeneration: UInt64?
            do {
                loop.onEngineQueueSync {
                    loop.nativePagedPrefixPreparedForTesting = { id, pages in
                        guard id == requestID else { return }
                        preparedCount += 1
                        previousGeneration = pages.streamGeneration
                        #expect(pages.scalarWitness.ready)
                        #expect(loop.recurrentStates[id] == nil)
                        #expect(loop.mtp?.assistantStateCountsForTesting(id) == nil)
                        #expect(throws: CBv2MTPBindingError.self) {
                            try pages.makeMTPImportProof(issuer: issuer)
                        }
                        consumer.cancel(id)
                    }
                    loop.nativePagedPrefixAdoptedForTesting = { id, _, _ in
                        if id == requestID { adoptedCount += 1 }
                    }
                }
                defer {
                    loop.onEngineQueueSync {
                        loop.nativePagedPrefixPreparedForTesting = nil
                        loop.nativePagedPrefixAdoptedForTesting = nil
                    }
                }
                do {
                    let outcome = try await consumer.submit(request, firstTokenDeadline: .init(
                        deadline: .now.advanced(by: .seconds(60)),
                        conservativePrefillTokensPerSecond: 1000, conservativeDecodeTokensPerSecond: 1000))
                    switch outcome {
                    case .admitted:
                        Issue.record("cancelled prepared GLM import was admitted")
                    case .deadlineUnreachable(let work):
                        Issue.record("GLM cancellation probe never reached preparation: \(work)")
                    }
                } catch { #expect(error is CancellationError) }
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline {
                if loop.onEngineQueueSync({
                    consumer.admissionForTesting.bytesReserved == baseline
                        && loop.registeredStreamGeneration(for: requestID) == nil
                }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(loop.onEngineQueueSync { preparedCount == 1 && adoptedCount == 0 })
            #expect(loop.onEngineQueueSync { consumer.admissionForTesting.bytesReserved == baseline })
            #expect(loop.onEngineQueueSync { loop.registeredStreamGeneration(for: requestID) == nil })
            #expect(loop.onEngineQueueSync { loop.recurrentStates[requestID] == nil })
            #expect(loop.onEngineQueueSync { loop.mtp?.assistantStateCountsForTesting(requestID) == nil })
            #expect(consumer.nativeCompletionFault == nil)
            let cancelledGeneration = try loop.onEngineQueueSync { try #require(previousGeneration) }

            request.prefixCacheReceiptID = .init(27_702)
            let retryStage = await fixture.stage(store: reader, engine: consumer, request: request)
            try #require(retryStage.staged)
            var retryGeneration: UInt64?
            let actual: GLM5NextCheckpointFixture.Output
            do {
                loop.onEngineQueueSync {
                    loop.nativePagedPrefixPreparedForTesting = { id, pages in
                        if id == requestID { retryGeneration = pages.streamGeneration }
                    }
                }
                defer { loop.onEngineQueueSync { loop.nativePagedPrefixPreparedForTesting = nil } }
                actual = try await fixture.run(engine: consumer, request: request, expectMTP: true)
            }
            #expect(actual.tokens == expected.tokens)
            #expect(actual.usage.prefixCachePrefillTokensSaved == 1024)
            #expect(loop.onEngineQueueSync { retryGeneration != nil && retryGeneration != cancelledGeneration })
        }
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
            let index = try #require(tensors.firstIndex { $0["role"] as? String == "recurrent" })
            tensors.remove(at: index)
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
