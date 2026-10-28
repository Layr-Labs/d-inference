import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Bonsai 9B artifact context admission")
struct Bonsai9BContextTests {
    private func cap(_ size: Int, modelID: String) -> Int? {
        Bonsai9BModelPolicy.contextLimit(modelId: modelID,
            modelType: "prism_hadamard_qwen35", nativeContextTokens: size)
    }

    @Test(arguments: [Bonsai9BModelPolicy.modelID, Bonsai9BModelPolicy.eigenModelID])
    func contextPolicyRequiresExactIdentityAndPositiveArtifactLimit(id: String) {
        #expect(cap(262144, modelID: id) == 262144)
        #expect(cap(4096, modelID: id) == 4096)
        #expect(cap(0, modelID: id) == nil)
        #expect(cap(-1, modelID: id) == nil)
        #expect(Bonsai9BModelPolicy.contextLimit(modelId: id,
            modelType: " PRISM_HADAMARD_QWEN35 ", nativeContextTokens: 262144) == 262144)
        for (model, type) in [(id.uppercased(), "prism_hadamard_qwen35"),
            ("prism-ml/bonsai-27b", "prism_hadamard_qwen35"),
            ("prism-ml/Ternary-Bonsai-2-4B-mlx-2bit", "prism_hadamard_qwen35"), (id, "qwen3_5")] {
            #expect(Bonsai9BModelPolicy.contextLimit(modelId: model,
                modelType: type, nativeContextTokens: 262144) == nil)
        }
    }

    @Test(arguments: [Bonsai9BModelPolicy.modelID, Bonsai9BModelPolicy.eigenModelID])
    func actualEnvelopeRejectsBeforeEngineWithNoPerformanceProfile(id: String) async throws {
        for (limit, output, admitted) in [(262144, 262143, true),
            (262144, 262144, false), (262144, 262145, false),
            (262144, Int.max, false), (2, 2, false)] {
            let engine = BonsaiContextSentinelEngine()
            let budget = GlobalKVCacheBudget(memorySnapshot: {
                .init(total: 256 << 30, active: 0, cache: 0, systemAvailable: 256 << 30)
            })
            let bridge = EngineV2Bridge(engine: engine, modelId: id,
                tokenizer: TokenizerHandle(BonsaiContextTokenizer()), eosTokenIds: [],
                maxConcurrentRequests: 1, kvBudget: budget, advertisedContextTokens: cap(limit, modelID: id))
            do {
                let stream = try await bridge.submitTokenized(promptTokens: [1],
                    request: .init(model: id, messages: [], max_tokens: output),
                    requestId: "context-envelope", firstContentDeadline: nil)
                for await _ in stream {}
                #expect(admitted, "out-of-context request reached engine")
            } catch let error as MultiModelBatchSchedulerEngineError {
                #expect(!admitted && error == .advertisedContextExceeded)
            }
            #expect(engine.submissions == (admitted ? 1 : 0))
            #expect(await bridge._testPendingSubmissionCount() == 0)
            await bridge.shutdown()
            #expect(budget.serviceBudget.count == 0)
        }
    }

    @Test(arguments: [Bonsai9BModelPolicy.modelID, Bonsai9BModelPolicy.eigenModelID])
    func defaultOutputAndNonthrowingStreamPreserveRejection(id: String) async throws {
        let engine = BonsaiContextSentinelEngine()
        let bridge = EngineV2Bridge(engine: engine, modelId: id,
            tokenizer: TokenizerHandle(BonsaiContextTokenizer()), eosTokenIds: [],
            defaultMaxTokens: 8, maxConcurrentRequests: 1, advertisedContextTokens: cap(8, modelID: id))
        let stream = await bridge.submitTokenized(promptTokens: [1],
            request: .init(model: id, messages: []), requestId: "default-output")
        var errors: [String] = []
        for await event in stream { if case .error(let message) = event { errors.append(message) } }
        #expect(errors == [Qwen4SupportPolicy.contextRejectionMessage])
        #expect(engine.submissions == 0)
        #expect(await bridge._testPendingSubmissionCount() == 0)
        await bridge.shutdown()
    }
}

/// No tensors or token generation: observe the real bridge admission boundary.
private final class BonsaiContextSentinelEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var submitted = 0
    var submissions: Int { lock.withLock { submitted } }
    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        lock.withLock { submitted += 1 }
        return AsyncStream { $0.finish() }
    }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }
    func shutdown() async {}
}
private struct BonsaiContextTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "test" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }; var eosToken: String? { nil }; var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] { [1] }
}
