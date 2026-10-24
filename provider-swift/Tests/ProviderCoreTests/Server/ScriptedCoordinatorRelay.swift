#if DEBUG
import Foundation
import MLX
import MLXLMCommon
import MLXNN

@testable import ProviderCore

/// One sealed request through the production coordinator handler, served by a
/// scripted CBv2 engine through the real bridge, scheduler engine, SDK framing
/// and frames loop. Scripted engine output is not a model-quality assertion.
enum ScriptedCoordinatorRelay {
    /// The request's decrypted SSE chunks, in order, and its terminal messages.
    struct Output {
        var frames: [String] = []
        var terminals: [OutboundMessage] = []
    }

    /// Lets a script wait for the chunks its earlier deltas produced.
    struct Progress: Sendable {
        let frames: @Sendable () throws -> [String]

        func wait(until condition: ([String]) -> Bool) async throws {
            let until = ContinuousClock.now + .seconds(5)
            while try !condition(frames()), ContinuousClock.now < until {
                try await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    static func run(
        modelID: String, modelType: String, tokenizer: TokenizerHandle,
        containerTokenizer: any MLXLMCommon.Tokenizer, eosTokenIds: Set<Int>, requestID: String,
        fields: [String], deadline: FirstContentDeadline? = nil,
        script: (AsyncStream<CBv2Event>.Continuation, Progress) async throws -> Void
    ) async throws -> Output {
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
        }
        let hardware = HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max",
            chipFamily: .m4, chipTier: .max, memoryGb: 64, memoryAvailableGb: 64,
            cpuCores: .init(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546)
        let loop = try ProviderLoop(config: .init(coordinatorURL: "ws://127.0.0.1:0/unused",
            hardware: hardware, models: [], config: .init(provider: .init(name: "scripted-relay"),
                backend: .init(), coordinator: .init(heartbeatIntervalSecs: 60))),
            attestationSigner: nil, kvBudgetForTesting: budget)
        let engine = PrefillScriptEngine()
        let bridge = EngineV2Bridge(engine: engine, modelId: modelID, tokenizer: tokenizer,
            eosTokenIds: eosTokenIds, kvBytesPerToken: 4_000, kvBudget: budget)
        let runtime = EngineV2Runtime()
        await runtime.register(modelId: modelID, bridge: bridge)
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.installModelSlotForTesting(modelId: modelID,
            container: ModelContainer(context: .init(configuration: .init(id: modelID),
                model: ScriptedRelayContainerModel(), processor: ScriptedRelayProcessor(),
                tokenizer: containerTokenizer)),
            tokenizer: tokenizer, engineV2: bridge,
            sizing: .init(weightsBytes: 0, fp16KVBytesPerToken: 4_000,
                maxContextLength: 8192, defaultMaxTokens: 4096),
            modelType: modelType)
        let sender = NodeKeyPair.generate()
        let encrypted = try sender.encrypt(recipientPublicKey: await loop.keyPair.publicKeyBytes,
            plaintext: Data(("{" + fields.joined(separator: ",") + "}").utf8))
        let recorder = ScriptedRelayRecorder()
        @Sendable func frames() throws -> [String] {
            try recorder.snapshot.compactMap { message in
                guard case .inferenceChunk(_, _, let encrypted?) = message else { return nil }
                return String(decoding: try sender.decryptPayload(encrypted), as: UTF8.self)
            }
        }
        await loop.handleInferenceRequest(requestId: requestID, ciphertext: encrypted,
            senderPublicKey: sender.publicKeyBytes, cacheReceiptNonce: nil,
            authenticatedCacheScope: "test-tenant", firstContentDeadline: deadline,
            send: SendHandle(recorder.record))
        let admittedUntil = ContinuousClock.now + .seconds(5)
        while engine.continuations.isEmpty, recorder.terminals.isEmpty, ContinuousClock.now < admittedUntil {
            try await Task.sleep(for: .milliseconds(1))
        }
        if let continuation = engine.continuations.first {
            try await script(continuation, Progress(frames: frames))
        }
        let settledUntil = ContinuousClock.now + .seconds(10)
        while recorder.terminals.isEmpty, ContinuousClock.now < settledUntil {
            try await Task.sleep(for: .milliseconds(1))
        }
        await bridge.shutdown()
        _ = await runtime.unregister(modelId: modelID)
        return Output(frames: try frames(), terminals: recorder.terminals)
    }
}

private final class ScriptedRelayRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [OutboundMessage] = []
    func record(_ message: OutboundMessage) { lock.withLock { messages.append(message) } }
    var snapshot: [OutboundMessage] { lock.withLock { messages } }
    var terminals: [OutboundMessage] {
        snapshot.filter {
            switch $0 {
            case .inferenceComplete, .inferenceError: true
            default: false
            }
        }
    }
}

private final class ScriptedRelayContainerModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], state: LMOutput.State?, prefill: PrefillParameters) throws
        -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

private struct ScriptedRelayProcessor: UserInputProcessor {
    private struct Unused: Error {}
    func prepare(input: UserInput) async throws -> LMInput { throw Unused() }
}
#endif
