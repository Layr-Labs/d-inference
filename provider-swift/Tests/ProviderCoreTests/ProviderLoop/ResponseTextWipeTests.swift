import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

#if DEBUG
/// The response text the inference handler gathers while it streams (for the
/// response hash, the billing floor and the reasoning count) is zeroed when the
/// request ends: a text that exists whole only in that gathered response is
/// gone from memory once the request has finished.
@Suite(.serialized) struct ResponseTextWipeTests {
    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks = 0
        private var completed = false
        func record(_ message: OutboundMessage) {
            lock.withLock {
                switch message {
                case .inferenceChunk: chunks += 1
                case .inferenceComplete: completed = true
                default: break
                }
            }
        }
        var chunkCount: Int { lock.withLock { chunks } }
        var isCompleted: Bool { lock.withLock { completed } }
    }

    @Test func gatheredResponseTextIsZeroedWhenTheRequestEnds() async throws {
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
        }
        let hardware = HardwareInfo(machineModel: "Mac16,5", chipName: "Apple M4 Max",
            chipFamily: .m4, chipTier: .max, memoryGb: 64, memoryAvailableGb: 64,
            cpuCores: .init(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546)
        let loop = try ProviderLoop(config: .init(coordinatorURL: "ws://127.0.0.1:0/unused",
            hardware: hardware, models: [], config: .init(provider: .init(name: "response-text"),
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

        let request = try JSONSerialization.data(withJSONObject: [
            "model": "fixture-model", "messages": [["role": "user", "content": "fixture"]],
            "max_tokens": 4096, "stream": true, "reasoning_parser": "none",
        ])
        let sender = NodeKeyPair.generate()
        let encrypted = try sender.encrypt(
            recipientPublicKey: await loop.keyPair.publicKeyBytes, plaintext: request)
        let sent = Sent()
        await loop.handleInferenceRequest(requestId: "response-text-request", ciphertext: encrypted,
            senderPublicKey: sender.publicKeyBytes, cacheReceiptNonce: nil,
            authenticatedCacheScope: "test-tenant", send: SendHandle(sent.record))
        let admittedUntil = ContinuousClock.now + .seconds(3)
        while engine.continuations.isEmpty, ContinuousClock.now < admittedUntil {
            try await Task.sleep(for: .milliseconds(1))
        }
        let continuation = try #require(engine.continuations.first)

        // The response repeats `text` in quarter pieces, one frame each, so
        // only the gathered response ever holds it whole.
        let text = UnheldText.random(count: 2048)
        let quarter = text.count / 4
        var frames = 0
        for _ in 0 ..< 32 {
            for part in 0 ..< 4 {
                let chunksBefore = sent.chunkCount
                continuation.yield(.delta(
                    text: text.piece(part * quarter ..< (part + 1) * quarter), tokens: [5], logprobs: nil))
                frames += 1
                let sentUntil = ContinuousClock.now + .seconds(5)
                while sent.chunkCount == chunksBefore, ContinuousClock.now < sentUntil {
                    try await Task.sleep(for: .milliseconds(1))
                }
            }
        }
        #expect(!ProcessMemoryScan.copies(of: text).isEmpty, "the scan finds the response while it is gathered")

        continuation.yield(.finished(reason: .length, usage: .init(promptTokens: 3, completionTokens: frames)))
        continuation.finish()
        let completedUntil = ContinuousClock.now + .seconds(10)
        while !sent.isCompleted, ContinuousClock.now < completedUntil {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(sent.isCompleted)

        // The request's task ends right after its terminal message.
        var left: [ProcessMemoryScan.Copy] = []
        for _ in 0 ..< 5 {
            try await Task.sleep(for: .milliseconds(200))
            left = ProcessMemoryScan.copies(of: text)
            if left.isEmpty { break }
        }
        if let first = left.first {
            Issue.record("\(left.count) copies of the response in memory after the request ended, first at \(first)")
        }
        await bridge.shutdown()
        _ = await runtime.unregister(modelId: "fixture-model")
    }
}
#endif
