// Copyright © 2026 Eigen Labs.
import Foundation
import Hummingbird
import HummingbirdTesting
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMServer
import MLXNN
import NIOCore
import Testing
@testable import ProviderCore

/// Real slot assembly and request admission, with an engine sentinel instead
/// of inference. No checkpoint download, tensor evaluation or HTTP listener.
@Suite("Flint artifact context admission", .serialized)
struct FlintContextAdmissionTests {
    private let modelID = "test/flint-context"

    @Test(arguments: [8, 262_144, 524_288])
    func productionSlotUsesValidatedModelContextWithoutClamping(limit: Int) async throws {
        let native = FlintContextSentinelEngine()
        // A deliberately conflicting snapshot cannot widen or narrow Flint.
        let bridge = try await makeBridge(model: model(limit: limit), native: native,
            sizingContext: limit == 8 ? 524_288 : 4)
        #expect(bridge.advertisedContextTokens == limit)
        let engine = scheduler(bridge)
        #expect(try await engine.availableModels().first?.contextLength == limit)

        // After a 1-token prompt, an output that fits is kept, and one that would
        // pass the artifact context is cut to what the prompt leaves of it.
        for output in [limit - 1, limit, limit + 1, Int.max] {
            let stream = try await bridge.submitTokenized(promptTokens: [1],
                request: .init(model: modelID, messages: [], max_tokens: output),
                requestId: "context-\(output)", firstContentDeadline: nil)
            for await _ in stream {}
            #expect(native.submittedOutputs.last == limit - 1, "output \(output) after a 1-token prompt")
            #expect(await bridge._testPendingSubmissionCount() == 0)
            #expect(await bridge._testPendingProfileCount() == 0)
        }
        // A prompt that fills the artifact context is refused, naming it.
        let submitted = native.submittedOutputs.count, probesBefore = native.prefixProbes
        do {
            let stream = try await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: limit),
                request: .init(model: modelID, messages: [], max_tokens: 1),
                requestId: "context-full", firstContentDeadline: nil)
            for await _ in stream {}
            Issue.record("a prompt that fills the context returned a stream")
        } catch let error as MultiModelBatchSchedulerEngineError {
            #expect(error == windowRefusal(limit))
        }
        #expect(native.submittedOutputs.count == submitted)
        #expect(native.prefixProbes == probesBefore)
        #expect(await bridge._testPendingSubmissionCount() == 0)
        #expect(await bridge._testPendingProfileCount() == 0)
        await bridge.shutdown()
    }

    /// The test template renders every chat to one token, so a context of 1
    /// is one that chat's prompt fills.
    @Test func oversizedRequestThrowsBeforeSSEFramesOrEngineAdmission() async throws {
        let native = FlintContextSentinelEngine()
        let bridge = try await makeBridge(model: model(limit: 1), native: native,
            sizingContext: 0)
        let service = MLXOpenAIService(engine: scheduler(bridge))
        let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data("""
        {"model":"\(modelID)","messages":[{"role":"user","content":"hi"}],
         "max_tokens":262145,"stream":true}
        """.utf8))
        do {
            _ = try await service.streamChatCompletionFrames(request: request)
            Issue.record("context rejection must throw before the SSE stream is returned")
        } catch let error as MultiModelBatchSchedulerEngineError {
            #expect(error == windowRefusal(1))
            let failure = ProviderLoop.sanitizedInferenceFailure(from: error, phase: .generation)
            #expect(failure.statusCode == 400)
            #expect(failure.code == .invalidRequest)
        }
        #expect(native.submittedOutputs.isEmpty)
        #expect(native.prefixProbes == 0)
        #expect(await bridge._testPendingSubmissionCount() == 0)
        await bridge.shutdown()
    }

    @Test func defaultOutputAndPromptBothCountAgainstArtifactContext() async throws {
        let native = FlintContextSentinelEngine()
        let bridge = try await makeBridge(model: model(limit: 8), native: native,
            sizingContext: 0, defaultOutput: 2)
        // The default output is cut to the window the prompt leaves (7 + 1); a
        // prompt that fills the window alone is still refused, naming it.
        for (prompt, accepted) in [(6, true), (7, true), (8, false), (9, false)] {
            let before = native.submittedOutputs.count
            do {
                let stream = try await bridge.submitTokenized(
                    promptTokens: Array(repeating: 1, count: prompt),
                    request: .init(model: modelID, messages: []),
                    requestId: "default-\(prompt)", firstContentDeadline: nil)
                for await _ in stream {}
                #expect(accepted)
            } catch let error as MultiModelBatchSchedulerEngineError {
                #expect(!accepted && error == windowRefusal(8))
            }
            #expect(native.submittedOutputs.count == before + (accepted ? 1 : 0))
        }
        #expect(native.submittedOutputs == [2, 1])
        #expect(await bridge._testPendingSubmissionCount() == 0)
        await bridge.shutdown()
    }

    /// A prompt that fills the context (1, as above) gets a JSON 400 that names
    /// it before any success header, streamed or not.
    @Test(arguments: [true, false])
    func localHTTPRejectsBeforeSuccessHeaders(streaming: Bool) async throws {
        let native = FlintContextSentinelEngine()
        let bridge = try await makeBridge(model: model(limit: 1), native: native,
            sizingContext: 0)
        let router = Router<BasicRequestContext>()
        let upload = LocalChatUploadResponder(inner: router.buildResponder(),
            service: MLXOpenAIService(engine: scheduler(bridge)))
        let app = Application(responder: CORSResponder(inner: upload),
            configuration: .init(address: .hostname("127.0.0.1", port: 0)))
        let body = ByteBuffer(string: """
        {"model":"\(modelID)","messages":[{"role":"user","content":"hi"}],
         "max_tokens":262145,"stream":\(streaming)}
        """)
        // Router mode invokes the real responder without opening a socket.
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post,
                headers: [.contentType: "application/json"], body: body) { response in
                #expect(response.status == .badRequest)
                #expect(response.headers[.contentType] == "application/json")
                let json = try #require(JSONSerialization.jsonObject(
                    with: Data(String(buffer: response.body).utf8)) as? [String: Any])
                let error = try #require(json["error"] as? [String: Any])
                #expect(error["type"] as? String == "invalid_request_error")
                #expect(error["code"] as? String == "context_length_exceeded")
                #expect(error["message"] as? String == windowRefusalWords(1))
            }
        }
        #expect(native.submittedOutputs.isEmpty)
        #expect(native.prefixProbes == 0)
        #expect(await bridge._testPendingSubmissionCount() == 0)
        await bridge.shutdown()
    }

    @Test func unrelatedModelsRetainExistingContextPolicies() async throws {
        let cases: [(String, String, Int?)] = [
            ("test/unrelated", "other", nil),
            // A model_type label alone cannot manufacture Flint metadata.
            (modelID, "flint", nil),
            (Qwen4SupportPolicy.ownedModelID, "qwen4_exp", 4_096),
            (Bonsai9BModelPolicy.modelID, "prism_hadamard_qwen35", 4_096),
        ]
        for (id, type, expected) in cases {
            let bridge = try await makeBridge(model: FlintContextOtherModel(),
                native: FlintContextSentinelEngine(), sizingContext: 4_096,
                id: id, type: type)
            #expect(bridge.advertisedContextTokens == expected)
            await bridge.shutdown()
        }
    }

    /// A real slot build (no engine override) honors a per-model contiguous
    /// override for Flint only by refusing the load: Flint is paged-only.
    @Test func perModelContiguousOverrideRefusesTheFlintSlot() async throws {
        let tokenizer = FlintProtocolTestTokenizer()
        let container = ModelContainer(context: .init(configuration: .init(id: modelID,
                extraEOSTokens: ["<|user|>", "<|observation|>", "<|developer|>"]),
            model: try model(limit: 4_096), processor: FlintContextProcessor(), tokenizer: tokenizer))
        do {
            _ = try await EngineV2SlotFactory.makeProductionBundle(
                modelId: modelID, modelType: "flint", isVLM: false, modelDirectory: nil,
                container: container, tokenizer: TokenizerHandle(tokenizer),
                sizing: .init(weightsBytes: 0, fp16KVBytesPerToken: 0,
                    maxContextLength: 4_096, defaultMaxTokens: 2),
                kvBytesCapacity: 16 << 20, maxConcurrentRequests: 1, kvBudget: nil,
                kvBackendConfig: "auto", kvBackendConfigByModel: [modelID: "contiguous"],
                checkpointQuantizationConfig: "balanced",
                specDecPreparation: .init(artifact: nil, status: .disabled(.configDisabled, configured: false)),
                environment: [PrefixCachePolicy.environmentFlag: "0", KVBackendGuardStore.pathEnvKey: "/dev/null"],
                startServingTelemetry: false, emitTelemetry: { _ in })
            Issue.record("a per-model contiguous override built a Flint slot")
        } catch let error as EngineV2ProductionError {
            guard case .pagedUnavailable(let reason) = error else {
                Issue.record("unexpected refusal: \(error)")
                return
            }
            #expect(reason == "Flint requires the paged KV backend; resolved contiguous")
        }
    }

    @Test(arguments: [0, -1])
    func invalidArtifactContextCannotProduceFlintModel(limit: Int) {
        #expect(throws: DecodingError.self) { try model(limit: limit) }
    }

    private func scheduler(_ bridge: EngineV2Bridge) -> MultiModelBatchSchedulerEngine {
        let id = modelID
        return MultiModelBatchSchedulerEngine(registryProvider: {
            [id: .init(tokenizer: TokenizerHandle(FlintProtocolTestTokenizer()),
                modelType: "flint", engineV2Bridge: bridge)]
        })
    }

    private func makeBridge(model: any LanguageModel, native: FlintContextSentinelEngine,
        sizingContext: Int, defaultOutput: Int = 2, id: String? = nil,
        type: String = "flint") async throws -> EngineV2Bridge {
        let id = id ?? modelID
        let tokenizer = FlintProtocolTestTokenizer()
        let container = ModelContainer(context: .init(configuration: .init(id: id,
                extraEOSTokens: ["<|user|>", "<|observation|>", "<|developer|>"]),
            model: model, processor: FlintContextProcessor(), tokenizer: tokenizer))
        let bundle = try await EngineV2SlotFactory.makeProductionBundle(
            modelId: id, modelType: type, isVLM: false, modelDirectory: nil,
            container: container, tokenizer: TokenizerHandle(tokenizer),
            sizing: .init(weightsBytes: 0, fp16KVBytesPerToken: 0,
                maxContextLength: sizingContext, defaultMaxTokens: defaultOutput),
            kvBytesCapacity: 16 << 20, maxConcurrentRequests: 1, kvBudget: nil,
            kvBackendConfig: "paged", checkpointQuantizationConfig: "native",
            specDecPreparation: .init(artifact: nil, status: .disabled(.configDisabled, configured: false)),
            environment: [PrefixCachePolicy.environmentFlag: "0"],
            startServingTelemetry: false, emitTelemetry: { _ in },
            makeEngineOverride: { _, _ in native })
        return bundle.bridge
    }

    private func model(limit: Int) throws -> FlintModel {
        let configuration = try JSONDecoder().decode(FlintConfiguration.self, from: Data("""
        {"model_type":"flint","hidden_size":8,"intermediate_size":16,
         "num_hidden_layers":2,"num_attention_heads":2,"num_key_value_heads":1,
         "head_dim":4,"vocab_size":32,"rms_norm_eps":0.00001,
         "max_position_embeddings":\(limit),"rope_theta":10000,
         "layer_types":["full_attention","sliding_attention"],
         "no_rope_layer_indices":[0],"mlp_only_layers":[0],"sliding_window":4,
         "num_experts":4,"num_experts_per_tok":2,"moe_intermediate_size":8,
         "shared_expert_intermediate_size":8,"tie_word_embeddings":false,
         "hidden_act":"silu","router_score_function":"sigmoid","softmax_type":"learnable",
         "norm_topk_prob":true,"attention_bias":false,"use_sliding_window":true,
         "decoder_sparse_step":1}
        """.utf8))
        return FlintModel(configuration)
    }
}

private final class FlintContextSentinelEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [Int] = []
    private var probes = 0
    var submittedOutputs: [Int] { lock.withLock { outputs } }
    var prefixProbes: Int { lock.withLock { probes } }
    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        lock.withLock { outputs.append(request.maxTokens) }
        return AsyncStream { $0.finish() }
    }
    func residentPrefixCandidate(for request: CBv2Request) -> CBv2ResidentPrefixCandidate? {
        lock.withLock { probes += 1 }
        return nil
    }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
            kvBytesCapacity: 16 << 20, activeTokens: 0)
    }
    func shutdown() async {}
}

private struct FlintContextProcessor: UserInputProcessor {
    private struct UnusedInput: Error {}
    func prepare(input: UserInput) async throws -> LMInput { throw UnusedInput() }
}

private final class FlintContextOtherModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], state: LMOutput.State?, prefill: PrefillParameters) throws
        -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}
