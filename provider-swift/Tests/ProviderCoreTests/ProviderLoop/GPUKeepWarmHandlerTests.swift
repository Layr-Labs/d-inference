import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

#if DEBUG
/// The coordinator handler wakes the GPU once for an accepted request that
/// finds the Mac idle, and only when wake-on-accept is opted in.
@Suite("GPU keep-warm in the coordinator handler")
struct GPUKeepWarmHandlerTests {
    private final class CountingSubmitter: GPUWakeSubmitting, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var submissions: Int { lock.withLock { count } }
        func submit(completed: @escaping @Sendable () -> Void) -> Bool {
            lock.withLock { count += 1 }
            completed()
            return true
        }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [OutboundMessage] = []
        func record(_ message: OutboundMessage) { lock.withLock { messages.append(message) } }
        var accepted: Bool {
            lock.withLock { messages.contains { if case .inferenceAccepted = $0 { true } else { false } } }
        }
        var completed: Bool {
            lock.withLock { messages.contains { if case .inferenceComplete = $0 { true } else { false } } }
        }
    }

    @Test(arguments: [false, true])
    func acceptedRequestWakesTheGPUOnlyWhenOptedIn(wakeOnAccept: Bool) async throws {
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
        }
        let hardware = HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max",
            chipFamily: .m4, chipTier: .max, memoryGb: 64, memoryAvailableGb: 64,
            cpuCores: .init(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546)
        let loop = try ProviderLoop(config: .init(coordinatorURL: "ws://127.0.0.1:0/unused",
            hardware: hardware, models: [], config: .init(provider: .init(name: "gpu-keep-warm"),
                backend: .init(), coordinator: .init(heartbeatIntervalSecs: 60))),
            attestationSigner: nil, kvBudgetForTesting: budget)
        let engine = PrefillScriptEngine()
        let tokenizer = CancelledPrefixTokenizer(prompt: [1, 2, 3])
        let bridge = EngineV2Bridge(engine: engine, modelId: "fixture-model",
            tokenizer: TokenizerHandle(tokenizer), eosTokenIds: [],
            kvBytesPerToken: 4_000, kvBudget: budget)
        let runtime = EngineV2Runtime()
        await runtime.register(modelId: "fixture-model", bridge: bridge)
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.installModelSlotForTesting(modelId: "fixture-model",
            container: cancelledPrefixContainer(tokenizer: tokenizer),
            tokenizer: TokenizerHandle(tokenizer), engineV2: bridge,
            sizing: .init(weightsBytes: 0, fp16KVBytesPerToken: 4_000,
                maxContextLength: 8192, defaultMaxTokens: 4096))

        let submitter = CountingSubmitter()
        await loop.startGPUKeepWarm(policy: .init(wakeOnAccept: wakeOnAccept), submitter: submitter)
        #expect((await loop.gpuKeepWarm != nil) == wakeOnAccept)

        let sender = NodeKeyPair.generate()
        let request = try JSONSerialization.data(withJSONObject: [
            "model": "fixture-model", "messages": [["role": "user", "content": "fixture"]],
            "max_tokens": 1, "stream": true, "reasoning_parser": "none",
        ])
        let encrypted = try sender.encrypt(
            recipientPublicKey: await loop.keyPair.publicKeyBytes, plaintext: request)
        let recorder = Recorder()
        await loop.handleInferenceRequest(requestId: "keep-warm-request", ciphertext: encrypted,
            senderPublicKey: sender.publicKeyBytes, cacheReceiptNonce: nil,
            authenticatedCacheScope: "test-tenant", send: SendHandle(recorder.record))
        let admittedUntil = ContinuousClock.now + .seconds(3)
        while engine.continuations.isEmpty, ContinuousClock.now < admittedUntil {
            try await Task.sleep(for: .milliseconds(1))
        }
        let continuation = try #require(engine.continuations.first)
        #expect(recorder.accepted)
        #expect(submitter.submissions == (wakeOnAccept ? 1 : 0))

        continuation.yield(.delta(text: "a", tokens: [5], logprobs: nil))
        continuation.yield(.finished(reason: .length, usage: .init(promptTokens: 3, completionTokens: 1)))
        continuation.finish()
        let settledUntil = ContinuousClock.now + .seconds(3)
        while !recorder.completed, ContinuousClock.now < settledUntil {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(recorder.completed)
        #expect(submitter.submissions == (wakeOnAccept ? 1 : 0))

        await loop.stopGPUKeepWarm()
        #expect(await loop.gpuKeepWarm == nil)
        await bridge.shutdown()
        _ = await runtime.unregister(modelId: "fixture-model")
    }
}
#endif
