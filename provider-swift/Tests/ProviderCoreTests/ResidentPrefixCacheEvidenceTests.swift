import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("Resident prefix routing evidence")
struct ResidentPrefixCacheEvidenceTests {
    private final class Messages: @unchecked Sendable {
        let lock = NSLock()
        var values: [OutboundMessage] = []
        func append(_ message: OutboundMessage) { lock.withLock { values.append(message) } }
        var snapshot: [OutboundMessage] { lock.withLock { values } }
    }

    private final class Publications: @unchecked Sendable {
        let lock = NSLock()
        var values: [PrefixCacheReadyResult] = []
        func append(_ value: PrefixCacheReadyResult) { lock.withLock { values.append(value) } }
        var snapshot: [PrefixCacheReadyResult] { lock.withLock { values } }
    }

    private func evidence() throws -> ResidentPrefixCacheEvidence {
        try #require(ResidentPrefixCacheEvidence(
            modelId: "model",
            modelAggregateHash: String(repeating: "a", count: 64),
            promptContractID: String(repeating: "b", count: 64)))
    }

    @Test("Only published input checkpoints produce 256-token routing anchors")
    func checkpointBoundaries() throws {
        let source = try evidence()
        let tokens = Array(repeating: 7, count: 4353)
        let proof = try #require(source.promptProof(tokens: tokens, scope: "tenant-a"))
        #expect(proof.anchors.count == 17)
        #expect(proof.anchors.last?.tokenCount == 4352)
        let ready = try #require(proof.publication(checkpointTokens: [16, 4096, 4097, 8192]))
        #expect(ready.readyAnchors.map(\.tokenCount) == [4096])
        #expect(ready.finalAnchor?.tokenCount == 4096)
        #expect(ready.expectedPrefillTokensSaved == 4096)
        #expect(ready.tier == .memory)
        #expect(ready.stageMs == 0)
        #expect(proof.publication(checkpointTokens: [16, 4097, 8192]) == nil)

        let physicalHasher = CBv2BlockHasher(
            blockSize: 16, promptContractID: String(repeating: "b", count: 64), scopeID: "tenant-a")
        let physicalHash = try #require(physicalHasher.chainHashes(tokens: tokens).first)
        #expect(proof.anchors.first?.chainHash != physicalHash.map { String(format: "%02x", $0) }.joined())
        let anotherTenant = try #require(source.promptProof(tokens: tokens, scope: "tenant-b"))
        #expect(anotherTenant.anchors[15] != proof.anchors[15])

        let exactBlock = try #require(source.promptProof(tokens: Array(tokens.prefix(4096)), scope: "tenant-a"))
        #expect(exactBlock.anchors.last?.tokenCount == 3840)
        #expect(exactBlock.publication(checkpointTokens: [4096]) == nil)
    }

    @Test("Resolved resident lookup reports actual adoption with conservative replay cost")
    func actualLookup() throws {
        let source = try evidence()
        let proof = try #require(source.promptProof(tokens: Array(repeating: 7, count: 4353), scope: "tenant"))
        let signal = EngineV2RequestUsageSignal()
        signal.recordResidentPrompt(proof)
        signal.record(usage: CBv2Usage(
            promptTokens: 4353,
            completionTokens: 1,
            prefixCacheOutcome: .hit,
            prefixCacheTier: .resident,
            prefixCacheMatchedTokens: 4096,
            prefixCachePrefillTokensSaved: 3840))
        let lookup = try #require(signal.lookupResult)
        #expect(lookup.tier == .memory)
        #expect(lookup.promptAnchor?.tokenCount == 4352)
        #expect(lookup.matchedAnchor?.tokenCount == 4096)
        #expect(lookup.requiredRecomputeTokens == 256)
        #expect(lookup.prefillTokensSaved == 3840)
    }

    @Test("Ready before lookup publishes the actual checkpoint, then one terminal")
    func sequencerOrdering() async throws {
        let source = try evidence()
        let sequencer = PrefixCacheEvidenceSequencer(tier: .memory) { source.capability() }
        defer { sequencer.shutdown() }
        let messages = Messages()
        let callbacks = try #require(sequencer.callbacks(
            requestID: "request", nonce: "nonce", send: SendHandle { messages.append($0) }))
        let proof = try #require(source.promptProof(tokens: Array(repeating: 7, count: 4353), scope: "tenant"))
        // Unicode digits are not lowercase SHA-256 hex and must not consume
        // a receipt sequence or become a prompt proof.
        callbacks.lookup(PrefixCacheLookupResult(
            outcome: .missAbsent, tier: .memory,
            promptAnchor: PrefixCacheAnchor(chainHash: String(repeating: "١", count: 64), tokenCount: 4352)))
        callbacks.ready(try #require(proof.publication(checkpointTokens: [4096])))
        callbacks.lookup(proof.resolve(PrefixCacheLookupResult(outcome: .missAbsent, tier: .memory)))
        callbacks.terminal(.inferenceError(
            requestId: "request", failure: InferenceFailure(code: .internalFailure, statusCode: 500)))
        for _ in 0..<100 where messages.snapshot.count < 3 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let values = messages.snapshot
        #expect(values.count == 3)
        guard values.count == 3,
            case .prefixCacheLookupV2(let lookup) = values[0],
            case .prefixCacheReadyV2(let ready) = values[1],
            case .inferenceError = values[2]
        else { Issue.record("Resident lookup/publication/terminal order changed"); return }
        #expect(lookup.tier == .memory)
        #expect(lookup.promptAnchor.tokenCount == 4352)
        #expect(lookup.cacheSeq == 1)
        #expect(ready.tier == .memory)
        #expect(ready.cacheSeq == 2)
        #expect(ready.readyAnchors.map(\.tokenCount) == [4096])
    }

    @Test("Delayed prior submission callback cannot publish for the next seeded request")
    func submissionIdentityAndClose() throws {
        let source = try evidence()
        let proof = try #require(source.promptProof(tokens: Array(repeating: 7, count: 4353), scope: "tenant"))
        let oldResults = Publications()
        let newResults = Publications()
        let oldSignal = EngineV2RequestUsageSignal(onCacheReady: { oldResults.append($0) })
        let newSignal = EngineV2RequestUsageSignal(onCacheReady: { newResults.append($0) })
        oldSignal.recordResidentPrompt(proof)
        newSignal.recordResidentPrompt(proof)
        let oldReceipt = CBv2RequestID(100)
        let newReceipt = CBv2RequestID(101)
        source.register(receiptID: oldReceipt, signal: oldSignal)
        source.discard(receiptID: oldReceipt)
        source.register(receiptID: newReceipt, signal: newSignal)
        source.publish(receiptID: oldReceipt, checkpointTokens: [4096])
        #expect(oldResults.snapshot.isEmpty)
        #expect(newResults.snapshot.isEmpty)
        source.publish(receiptID: newReceipt, checkpointTokens: [4096])
        source.publish(receiptID: newReceipt, checkpointTokens: [4096])
        #expect(newResults.snapshot.count == 1)

        let previousEpoch = try #require(source.capability()).cacheEpoch
        #expect(try #require(evidence().capability()).cacheEpoch != previousEpoch)
        source.register(receiptID: CBv2RequestID(102), signal: newSignal)
        source.close()
        source.publish(receiptID: CBv2RequestID(102), checkpointTokens: [4096])
        #expect(newResults.snapshot.count == 1)
        #expect(source.capability() == nil)
    }

    @Test("Resident capability has its own wire snapshot including attested registration")
    func advertisementWire() throws {
        let source = try evidence()
        let state = ProviderState()
        state.setPrefixCacheSnapshot(
            sources: [:], memorySources: ["model": source], statuses: [], runtimeIdentityAvailable: true)
        let advertisement = state.prefixCacheV2Advertisement()
        #expect(advertisement.protocolVersion == 2)
        #expect(advertisement.models.isEmpty)
        #expect(advertisement.memoryModels.count == 1)

        let message = ProviderMessage.Heartbeat(
            status: .idle, activeModel: nil, warmModels: [], stats: ProviderStats(),
            systemMetrics: SystemMetrics(memoryPressure: 0, cpuUsage: 0, thermalState: .nominal), prefixCacheProtocol: 2,
            prefixCacheV2Models: [], prefixCacheMemoryModels: advertisement.memoryModels)
        let encoded = try ProviderProtocolCodec.encodeProviderMessage(.heartbeat(message))
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect((json["prefix_cache_memory_models"] as? [[String: Any]])?.count == 1)
        let decoded = try JSONDecoder().decode(ProviderMessage.self, from: encoded)
        guard case .heartbeat(let heartbeat) = decoded else { Issue.record("Wrong message kind"); return }
        #expect(heartbeat.prefixCacheMemoryModels == advertisement.memoryModels)

        let registration = ProviderMessage.Register(
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                memoryGb: 128, memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546),
            models: [], backend: "mlx_swift_lm",
            attestation: RawJSON(rawBytes: Data(#"{"signature":"test"}"#.utf8)),
            prefixCacheProtocol: 2, prefixCacheMemoryModels: advertisement.memoryModels)
        let rawEncoded = try ProviderProtocolCodec.encodeProviderMessage(.register(registration))
        let rawJSON = try #require(JSONSerialization.jsonObject(with: rawEncoded) as? [String: Any])
        #expect((rawJSON["prefix_cache_memory_models"] as? [[String: Any]])?.count == 1)
        #expect(rawJSON["prefix_cache_v2_models"] == nil)

        state.setPrefixCacheSnapshot(sources: [:], memorySources: [:], statuses: [], runtimeIdentityAvailable: true)
        #expect(state.prefixCacheV2Advertisement().memoryModels.isEmpty)
        source.close()
        #expect(state.prefixCacheV2Advertisement().memoryModels.isEmpty)
        state.setPrefixCacheSnapshot(
            sources: [:], memorySources: ["model": try evidence()], statuses: [], runtimeIdentityAvailable: false)
        #expect(state.prefixCacheV2Advertisement().memoryModels.isEmpty)
        #expect(state.prefixCacheV2Advertisement().protocolVersion == 1)
    }

    @Test("Resident wire preserves 16 verified checkpoints without widening the SSD limit")
    func tierSpecificWireLimit() throws {
        let source = try evidence()
        let proof = try #require(source.promptProof(tokens: Array(repeating: 7, count: 20 * 4096 + 1), scope: "tenant"))
        let publication = try #require(proof.publication(checkpointTokens: (1...20).map { $0 * 4096 }))
        #expect(publication.readyAnchors.count == 16)
        #expect(publication.readyAnchors.first?.tokenCount == 4096)
        #expect(publication.readyAnchors.last?.tokenCount == 20 * 4096)
        let capability = try #require(source.capability())
        func ready(tier: PrefixCacheTier) -> ProviderMessage.PrefixCacheReadyV2 {
            ProviderMessage.PrefixCacheReadyV2(
                requestId: "request", cacheReceiptNonce: "nonce", modelId: "model",
                modelAggregateHash: capability.modelAggregateHash, promptContractId: capability.promptContractId,
                cacheEpoch: capability.cacheEpoch, cacheSeq: 2, tier: tier,
                readyAnchors: publication.readyAnchors, requiredRecomputeTokens: 0,
                expectedPrefillTokensSaved: UInt64(publication.expectedPrefillTokensSaved), stageMs: 0)
        }
        let data = try ProviderProtocolCodec.encodeProviderMessage(.prefixCacheReadyV2(ready(tier: .memory)))
        let decoded = try ProviderProtocolCodec.decodeProviderMessage(from: data)
        guard case .prefixCacheReadyV2(let message) = decoded else { Issue.record("Wrong message kind"); return }
        #expect(message.readyAnchors == publication.readyAnchors)
        #expect(ready(tier: .ssd).readyAnchors.count == 2)
    }
}
