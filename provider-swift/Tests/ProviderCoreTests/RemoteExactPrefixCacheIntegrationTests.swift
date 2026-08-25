import CryptoKit
import Foundation
import MLXLMCommon
import MLXLMServer
import MLXNN
import Testing

@testable import ProviderCore

private enum RemoteExactPrefixCacheTestFailure: Error {
    case unexpectedMessage
}

private final class RemoteExactCaptureEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [CBv2Request] = []

    var submitted: [CBv2Request] { lock.withLock { requests } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        lock.withLock { requests.append(request) }
        return AsyncStream { continuation in
            continuation.yield(.finished(
                reason: .stop,
                usage: CBv2Usage(
                    promptTokens: request.promptTokens.count,
                    completionTokens: 0)))
            continuation.finish()
        }
    }

    func cancel(_ id: CBv2RequestID) {}

    func capacity() -> CBv2CapacitySnapshot {
        CBv2CapacitySnapshot(
            activeRequests: 0,
            waitingRequests: 0,
            kvBytesInUse: 0,
            kvBytesCapacity: 1 << 20,
            kvBytesBackendCapacity: 1 << 20,
            activeTokens: 0)
    }

    func updateKVBytesCapacity(_ bytes: Int) {}
    func shutdown() async {}
}

private struct RemoteExactTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1, 2, 3] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { token == "</s>" ? 2 : nil }
    func convertIdToToken(_ id: Int) -> String? { id == 2 ? "</s>" : nil }
    var bosToken: String? { nil }
    var eosToken: String? { "</s>" }
    var unknownToken: String? { nil }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        [11, 12, 13, 14]
    }
}

private final class RemoteExactLanguageModel: Module, LanguageModel {
    func prepare(
        _ input: LMInput,
        cache: [KVCache],
        windowSize: Int?
    ) throws -> PrepareResult {
        .tokens(input.text)
    }

    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

private struct RemoteExactProcessor: UserInputProcessor {
    struct Unused: Error {}
    func prepare(input: UserInput) async throws -> LMInput { throw Unused() }
}

private final class RemoteExactOutboundRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [OutboundMessage] = []
    private let continuation: AsyncStream<OutboundMessage>.Continuation
    let stream: AsyncStream<OutboundMessage>

    init() {
        let pair = AsyncStream<OutboundMessage>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func send(_ message: OutboundMessage) {
        lock.withLock { messages.append(message) }
        continuation.yield(message)
        switch message {
        case .inferenceComplete, .inferenceError:
            continuation.finish()
        default:
            break
        }
    }

    var receiptCount: Int {
        lock.withLock {
            messages.reduce(into: 0) { count, message in
                switch message {
                case .prefixCacheLookup, .prefixCacheReady:
                    count += 1
                default:
                    break
                }
            }
        }
    }
}

private extension ProviderLoop {
    func exactCacheAdvertisementForTesting() async -> (
        protocolVersion: Int,
        models: [PrefixCacheV2Capability],
        exactModels: [String],
        statuses: [PrefixCacheModelStatus],
        donationOutcomes: [PrefixCacheDonationOutcomeCount]
    ) {
        binaryHash = String(repeating: "a", count: 64)
        await updateAggregateCapacity()
        return state.prefixCacheV2Advertisement()
    }
}

@Suite("Remote exact prefix cache integration")
struct RemoteExactPrefixCacheIntegrationTests {
    private let modelID = "qwen-exact-test"

    private func makeLoop() throws -> ProviderLoop {
        try ProviderLoop(
            config: ProviderLoopConfig(
                coordinatorURL: "ws://127.0.0.1:0/ignored",
                hardware: HardwareInfo(
                    machineModel: "Mac16,5",
                    chipName: "Apple M4 Max",
                    chipFamily: .m4,
                    chipTier: .max,
                    memoryGb: 128,
                    memoryAvailableGb: 124,
                    cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                    gpuCores: 40,
                    memoryBandwidthGbs: 546),
                models: [ModelInfo(
                    id: modelID,
                    modelType: "qwen3_5_moe",
                    parameters: nil,
                    quantization: "4bit",
                    sizeBytes: 1,
                    estimatedMemoryGb: 1)],
                config: ProviderConfig(
                    provider: ProviderSettings(
                        name: "remote-exact-cache-test",
                        memoryReserveGB: 1),
                    backend: BackendSettings(
                        idleTimeoutMins: 0,
                        maxModelSlots: 1),
                    coordinator: CoordinatorSettings(
                        heartbeatIntervalSecs: 60))),
            purgeLegacyFiles: false,
            attestationSigner: nil)
    }

    private func makeContainer(tokenizer: RemoteExactTokenizer) -> ModelContainer {
        ModelContainer(context: ModelContext(
            configuration: ModelConfiguration(id: modelID),
            model: RemoteExactLanguageModel(),
            processor: RemoteExactProcessor(),
            tokenizer: tokenizer))
    }

    private func dispatchRemoteRequest(
        loop: ProviderLoop,
        authenticatedScope: String?,
        cacheReceiptNonce: String? = nil
    ) async throws -> Int {
        let body = try JSONEncoder().encode(ChatCompletionRequest(
            model: modelID,
            messages: [.init(role: "user", content: "repeatable prompt")],
            max_tokens: 1,
            stream: true))
        let consumer = NodeKeyPair.generate()
        let providerPublicKey = await loop.keyPair.publicKeyBytes
        let encrypted = try consumer.encryptPayload(
            recipientPublicKey: providerPublicKey,
            plaintext: body)
        let wire = try ProviderProtocolCodec.encodeCoordinatorMessage(.inferenceRequest(.init(
            requestId: "remote-\(UUID().uuidString)",
            encryptedBody: encrypted,
            cacheReceiptNonce: cacheReceiptNonce,
            cacheScope: authenticatedScope)))
        guard case .inferenceRequest(let inbound) =
            try ProviderProtocolCodec.decodeCoordinatorMessage(from: wire)
        else {
            throw RemoteExactPrefixCacheTestFailure.unexpectedMessage
        }
        let inboundEncrypted = try #require(inbound.encryptedBody)
        let ciphertext = try #require(Data(base64Encoded: inboundEncrypted.ciphertext))
        let senderPublicKey = try #require(
            Data(base64Encoded: inboundEncrypted.ephemeralPublicKey))
        let recorder = RemoteExactOutboundRecorder()
        await loop.handleInferenceRequest(
            requestId: inbound.requestId,
            ciphertext: ciphertext,
            senderPublicKey: senderPublicKey,
            cacheReceiptNonce: inbound.cacheReceiptNonce,
            authenticatedCacheScope: inbound.cacheScope,
            prefixCacheProtocol: inbound.prefixCacheProtocol,
            send: SendHandle(recorder.send))
        for await message in recorder.stream {
            switch message {
            case .inferenceComplete, .inferenceError:
                break
            default:
                continue
            }
            break
        }
        return recorder.receiptCount
    }

    private func makeSSDCache() throws -> (cache: SSDPrefixCache, root: URL) {
        let dedicatedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "remote-exact-mixed-\(UUID().uuidString)", isDirectory: true)
        let modelRoot = dedicatedRoot.appendingPathComponent(
            "mixed-model", isDirectory: true)
        try SSDBlockStore.prepareModelRoot(
            dedicatedRoot: dedicatedRoot, modelRoot: modelRoot)
        let layerKinds = [
            CBv2LayerKind(
                attention: .full, headDim: 4, kvHeads: 1, queryHeads: 1)
        ]
        return (
            SSDPrefixCache(
                config: .init(
                    modelId: modelID,
                    promptContractID: "mixed-prompt-contract",
                    weightHash: "mixed-weight-hash",
                    blockSize: 8,
                    adoptionBoundTokens: 0,
                    layoutEpoch: SSDBlockStore.layoutEpoch(
                        blockSize: 8, layerKinds: layerKinds),
                    root: modelRoot,
                    dedicatedRoot: dedicatedRoot,
                    ttlSeconds: 900,
                    minEffectiveTokens: 8,
                    maxStageBytes: 1 << 20,
                    maxStageMillis: 10_000,
                    nowSeconds: { 10_000 }),
                kekKey: SymmetricKey(size: .bits256),
                kvBudget: nil,
                diskBudget: SSDDiskBudget(),
                maxWriteBytesPerDay: 0,
                diskBudgetBytes: { 1 << 20 }),
            dedicatedRoot)
    }

    private func runRemoteRequest(
        authenticatedScope: String?,
        cacheReceiptNonce: String? = nil,
        includeSSD: Bool = false
    ) async throws -> (request: CBv2Request, receiptCount: Int) {
        let loop = try makeLoop()
        let tokenizer = RemoteExactTokenizer()
        let engine = RemoteExactCaptureEngine()
        let ssdFixture: (cache: SSDPrefixCache, root: URL)?
        if includeSSD {
            ssdFixture = try makeSSDCache()
        } else {
            ssdFixture = nil
        }
        defer {
            ssdFixture?.cache.close()
            if let root = ssdFixture?.root {
                try? FileManager.default.removeItem(at: root)
            }
        }
        let exactCache = ExactPrefixCacheV2(config: .init(
            modelIdentity: "verified-model",
            policyIdentity: "exact-policy",
            maxBytes: 1 << 20))
        let bridge = EngineV2Bridge(
            engine: engine,
            modelId: modelID,
            tokenizer: TokenizerHandle(tokenizer),
            eosTokenIds: [2],
            exactPrefixCache: exactCache,
            exactPrefixCacheConfigured: true,
            exactPrefixCacheReason: "ready",
            ssdPrefixCache: ssdFixture?.cache)
        #expect(bridge.exactPrefixCache != nil)
        #expect((bridge.ssdPrefixCache != nil) == includeSSD)
        await loop.installModelSlotForTesting(
            modelId: modelID,
            container: makeContainer(tokenizer: tokenizer),
            tokenizer: TokenizerHandle(tokenizer),
            engineV2: bridge,
            modelType: "qwen3_5_moe")
        let advertisement = await loop.exactCacheAdvertisementForTesting()
        #expect(advertisement.protocolVersion == 1)
        #expect(advertisement.models.isEmpty)
        #expect(advertisement.exactModels == [modelID])

        let receiptCount = try await dispatchRemoteRequest(
            loop: loop,
            authenticatedScope: authenticatedScope,
            cacheReceiptNonce: cacheReceiptNonce)
        let request = try #require(engine.submitted.first)
        await bridge.shutdown()
        return (request, receiptCount)
    }

    @Test("scope-only remote metadata gates exact lookup and donation")
    func authenticatedScopeIsRequired() async throws {
        let scoped = try await runRemoteRequest(
            authenticatedScope: "coordinator-authenticated-tenant")
        #expect(scoped.request.prefixCacheEnabled)
        #expect(scoped.request.cacheSalt == "coordinator-authenticated-tenant")
        #expect(scoped.receiptCount == 0)

        let absent = try await runRemoteRequest(authenticatedScope: nil)
        #expect(!absent.request.prefixCacheEnabled)
        #expect(absent.request.cacheSalt == nil)
        #expect(absent.receiptCount == 0)

        let blank = try await runRemoteRequest(authenticatedScope: " \n ")
        #expect(!blank.request.prefixCacheEnabled)
        #expect(blank.request.cacheSalt == nil)
        #expect(blank.receiptCount == 0)
    }

    @Test("repeated encrypted remote requests donate and hit the live exact cache")
    func liveRemoteDonationThenHit() async throws {
        let loop = try makeLoop()
        let tokenizer = RemoteExactTokenizer()
        let exactCache = ExactPrefixCacheV2(config: .init(
            modelIdentity: "verified-live-model",
            policyIdentity: "exact-live-policy",
            maxBytes: 1 << 20))
        let live = makeRemoteExactLiveEngine(cache: exactCache)
        let bridge = EngineV2Bridge(
            engine: live.engine,
            modelId: modelID,
            tokenizer: TokenizerHandle(tokenizer),
            eosTokenIds: [2],
            exactPrefixCache: exactCache,
            exactPrefixCacheConfigured: true,
            exactPrefixCacheReason: "ready")
        await loop.installModelSlotForTesting(
            modelId: modelID,
            container: makeContainer(tokenizer: tokenizer),
            tokenizer: TokenizerHandle(tokenizer),
            engineV2: bridge,
            modelType: "qwen3_5_moe")

        let scope = "coordinator-authenticated-live-tenant"
        let coldReceipts = try await dispatchRemoteRequest(
            loop: loop,
            authenticatedScope: scope)
        let afterCold = exactCache.stats()
        let prefillRowsAfterCold = live.model.prefillRows

        let warmReceipts = try await dispatchRemoteRequest(
            loop: loop,
            authenticatedScope: scope)
        let afterWarm = exactCache.stats()
        let prefillRowsAfterWarm = live.model.prefillRows
        await bridge.shutdown()

        #expect(coldReceipts == 0)
        #expect(warmReceipts == 0)
        #expect(afterCold.misses == 1)
        #expect(afterCold.donations == 1)
        #expect(prefillRowsAfterCold == 1)
        #expect(afterWarm.hits == 1)
        #expect(afterWarm.donations == 1)
        #expect(prefillRowsAfterWarm == prefillRowsAfterCold)
    }

    @Test("mixed exact and SSD cache keeps scope-only authorization on the engine")
    func mixedScopeOnlyAuthorizesExactWithoutStaging() async throws {
        let result = try await runRemoteRequest(
            authenticatedScope: "coordinator-authenticated-tenant",
            includeSSD: true)

        #expect(result.request.prefixCacheEnabled)
        #expect(result.request.cacheSalt == "coordinator-authenticated-tenant")
        #expect(result.request.prefixCacheReceiptID == nil)
        #expect(result.receiptCount == 0)
    }

    @Test("mixed exact and SSD cache stages only with complete receipt metadata")
    func mixedSSDStageRequiresReceiptMetadata() async throws {
        let authorized = try await runRemoteRequest(
            authenticatedScope: "coordinator-authenticated-tenant",
            cacheReceiptNonce: "coordinator-receipt",
            includeSSD: true)
        #expect(authorized.request.prefixCacheEnabled)
        #expect(authorized.request.cacheSalt == "coordinator-authenticated-tenant")
        #expect(authorized.request.prefixCacheReceiptID != nil)
        #expect(authorized.receiptCount == 1)

        let missingScope = try await runRemoteRequest(
            authenticatedScope: nil,
            cacheReceiptNonce: "coordinator-receipt",
            includeSSD: true)
        #expect(!missingScope.request.prefixCacheEnabled)
        #expect(missingScope.request.cacheSalt == nil)
        #expect(missingScope.request.prefixCacheReceiptID == nil)
        #expect(missingScope.receiptCount == 1)
    }
}
