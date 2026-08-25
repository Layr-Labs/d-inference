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

    private func runRemoteRequest(
        authenticatedScope: String?
    ) async throws -> (request: CBv2Request, receiptCount: Int) {
        let loop = try makeLoop()
        let tokenizer = RemoteExactTokenizer()
        let engine = RemoteExactCaptureEngine()
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
            exactPrefixCacheReason: "ready")
        #expect(bridge.exactPrefixCache != nil)
        #expect(bridge.ssdPrefixCache == nil)
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

        let request = try #require(engine.submitted.first)
        let receiptCount = recorder.receiptCount
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
}
