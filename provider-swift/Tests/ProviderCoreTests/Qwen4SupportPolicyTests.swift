// Copyright © 2026 Eigen Labs.
import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("Qwen4 private artifact and context policy")
struct Qwen4SupportPolicyTests {
    @Test(arguments: [Qwen4SupportPolicy.ownedModelID, Qwen4SupportPolicy.registryModelID])
    func onlyQualifiedArtifactsReceiveAutomaticDefaults(owned: String) {
        #expect(EngineV2SupportedModels.isQwen4ExpListingModelID(owned))
        #expect(EngineV2KVBackendPolicy.preferredBackend(
            selection: .auto, modelID: owned) == .paged)
        #expect(PrefixCachePolicy.isEnabled(modelId: owned, environment: [:]))
        #expect(!PrefixCachePolicy.isMemoryEnabled(environment: [:]))
        #expect(!PrefixCachePolicy.isEnabled(
            modelId: owned, environment: [PrefixCachePolicy.environmentFlag: "0"]))

        for other in [
            "", "qwen4_exp", "qwen4_exp_text", "org/qwen4_exp-copy",
            "Qwen/Qwen3.8-Flash-Next", "Jundot/Qwen3.8-Flash-Next-oQ4e-mtp",
            "QWEN3.8-FLASH-NEXT", Qwen4SupportPolicy.ownedModelID.lowercased(),
            "\(owned)-other", "other/\(owned)", " \(owned)",
        ] {
            #expect(!EngineV2SupportedModels.isQwen4ExpListingModelID(other))
            #expect(EngineV2KVBackendPolicy.preferredBackend(
                selection: .auto, modelID: other) == .contiguous)
            #expect(!PrefixCachePolicy.isEnabled(modelId: other, environment: [:]))
            // Explicit test/qualification controls retain the existing loaded
            // capability and identity gates; they do not widen the default list.
            #expect(EngineV2KVBackendPolicy.preferredBackend(
                selection: .paged, modelID: other) == .paged)
            #expect(PrefixCachePolicy.isEnabled(
                modelId: other, environment: [PrefixCachePolicy.environmentFlag: "1"]))
        }
        #expect(!EngineV2SupportedModels.isQwen4ExpListingModelID(nil))
        for model in ["gpt-oss-20b", "gemma-4-26b-qat-4bit"] {
            #expect(PrefixCachePolicy.isEnabled(modelId: model, environment: [:]))
            #expect(EngineV2KVBackendPolicy.preferredBackend(
                selection: .auto, modelID: model) == .paged)
        }
    }

    @Test func architectureRecognitionDoesNotGrantArtifactDefaults() {
        for type in ["qwen4_exp", "qwen4_exp_text", " QWEN4_EXP_TEXT\n"] {
            #expect(Qwen4SupportPolicy.isQwen4ModelType(type))
            #expect(EngineV2SupportedModels.isSupported(modelType: type))
            #expect(Qwen4SupportPolicy.contextLimit(
                modelID: "private/unnamed", modelType: type, environment: [:]) == nil)
            #expect(Qwen4SupportPolicy.contextLimit(modelID: "private/unnamed",
                modelType: type, nativeContextTokens: 524_288, environment: [:]) == 524_288)
        }
        for type in [nil, "qwen3_5", "qwen4_exp_other", "other_qwen4_exp"] as [String?] {
            #expect(!Qwen4SupportPolicy.isQwen4ModelType(type))
            #expect(Qwen4SupportPolicy.contextLimit(
                modelID: "private/unnamed", modelType: type, environment: [:]) == nil)
        }
    }

    @Test func contextOverrideCanOnlyLowerTheLimit() {
        let key = Qwen4SupportPolicy.contextEnvironmentKey
        #expect(Qwen4SupportPolicy.configuredContextTokens(environment: [:]) == 262_144)
        for value in ["", " ", "0", "-1", "false", "invalid", "1.5", "262144", String(Int.max),
                      "99999999999999999999999999999"] {
            #expect(Qwen4SupportPolicy.configuredContextTokens(environment: [key: value]) == 262_144)
        }
        for (value, expected) in [("1", 1), ("8192", 8192), (" 4096\n", 4096), ("82000", 82_000)] {
            #expect(Qwen4SupportPolicy.configuredContextTokens(environment: [key: value]) == expected)
        }
        #expect(Qwen4SupportPolicy.contextLimit(
            modelID: Qwen4SupportPolicy.ownedModelID,
            nativeContextTokens: 4096, environment: [:]) == 4096)
        #expect(Qwen4SupportPolicy.configuredContextTokens(nativeContextTokens: 524_288,
            environment: [:]) == 524_288)
        #expect(Qwen4SupportPolicy.configuredContextTokens(nativeContextTokens: 524_288,
            environment: [key: "600000"]) == 524_288)
        #expect(Qwen4SupportPolicy.validatedContextTokens(524_288) == 524_288)
        #expect(Qwen4SupportPolicy.validatedContextTokens(0) == nil)
        #expect(Qwen4SupportPolicy.validatedContextTokens(-1) == nil)
        #expect(Qwen4SupportPolicy.validatedContextTokens(nil) == nil)
    }

    @Test(arguments: [Qwen4SupportPolicy.ownedModelID, Qwen4SupportPolicy.registryModelID])
    func listedKnownArtifactUsesNativeCapacityBeforeLoading(owned: String) async throws {
        let engine = MultiModelBatchSchedulerEngine(
            acquire: { id in throw MultiModelBatchSchedulerEngineError.modelNotLoaded(id) },
            tokenizerProvider: { _ in
                throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization
            },
            availableModels: { [owned, "unrelated/\(owned)"] })
        let models = try await engine.availableModels()
        let known = try #require(models.first { $0.id == owned })
        #expect(known.contextLength == Qwen4SupportPolicy.contextLimit(modelID: owned))
        #expect(known.contextLength == 262_144)
        #expect(models.first { $0.id != owned }?.contextLength == nil)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(known))
            as? [String: Any])
        #expect(json["context_length"] as? Int == known.contextLength)
        #expect(json["max_model_len"] as? Int == known.contextLength)
    }

    @Test func loadedListingUsesTheImmutableBridgeLimit() async throws {
        let native = Qwen4PolicyEngine()
        let bridge = makePolicyBridge(native, cap: 8)
        let engine = MultiModelBatchSchedulerEngine(registryProvider: {
            [Qwen4SupportPolicy.ownedModelID: .init(
                tokenizer: TokenizerHandle(Qwen4PolicyTokenizer()),
                modelType: "qwen4_exp", engineV2Bridge: bridge)]
        })
        #expect(try await engine.availableModels().first?.contextLength == 8)
        await bridge.shutdown()
    }

    @Test func requestEnvelopeIncludesReservedAndDefaultOutput() async throws {
        // An engine-admission sentinel stops accepted cases before any model work.
        let cases: [(prompt: Int, output: Int?, accepted: Bool)] = [
            (8, 0, true), (7, 1, true), (6, nil, true),
            (8, 1, false), (9, 0, false), (7, nil, false),
            (1, Int.max, false), (1, -1, false),
        ]
        for testCase in cases {
            let native = Qwen4PolicyEngine()
            let bridge = makePolicyBridge(native, cap: 8, defaultOutput: 2)
            let usage = EngineV2RequestUsageSignal()
            do {
                let events = try await bridge.submitTokenized(
                    promptTokens: Array(repeating: 1, count: testCase.prompt),
                    request: policyRequest(output: testCase.output), requestId: "context-test",
                    usageSignal: usage, firstContentDeadline: nil)
                for await _ in events {}
                #expect(testCase.accepted)
            } catch let error as MultiModelBatchSchedulerEngineError {
                #expect(!testCase.accepted)
                #expect(error == .advertisedContextExceeded)
            }
            #expect(native.submittedOutputs == (testCase.accepted ? [testCase.output ?? 2] : []))
            if !testCase.accepted {
                #expect(native.prefixProbes == 0)
                #expect(usage.lookupResult?.outcome == .skippedPolicy)
            }
            #expect(await bridge._testPendingSubmissionCount() == 0)
            #expect(await bridge._testPendingProfileCount() == 0)
            await bridge.shutdown()
        }
    }

    @Test(arguments: [Qwen4SupportPolicy.ownedModelID, Qwen4SupportPolicy.registryModelID])
    func nativeWindowIncludesReservedOutputAndRejectsOverflow(modelID: String) async throws {
        let cases: [(Int, Int, Bool)] = [
            (82_001, 1, true), (229_376, 32_768, true), (229_377, 32_768, false),
            (262_143, 1, true), (262_144, 1, false), (1, Int.max, false),
        ]
        for (prompt, output, accepted) in cases {
            let native = Qwen4PolicyEngine()
            let bridge = makePolicyBridge(native, cap: 262_144, modelID: modelID)
            do {
                let stream = try await bridge.submitTokenized(
                    promptTokens: Array(repeating: 1, count: prompt),
                    request: policyRequest(output: output, modelID: modelID),
                    requestId: "native-context-boundary", firstContentDeadline: nil)
                for await _ in stream {}
                #expect(accepted)
            } catch let error as MultiModelBatchSchedulerEngineError {
                #expect(!accepted)
                #expect(error == .advertisedContextExceeded)
            }
            #expect(native.submittedOutputs == (accepted ? [output] : []))
            if !accepted { #expect(native.prefixProbes == 0) }
            #expect(await bridge._testPendingSubmissionCount() == 0)
            await bridge.shutdown()
        }
    }

    @Test func genericBridgeDoesNotApplyQwenCapacityToOtherModels() async {
        let native = Qwen4PolicyEngine()
        let bridge = makePolicyBridge(native, cap: 524_288, modelID: "foreign/native-model")
        #expect(bridge.advertisedContextTokens == 524_288)
        await bridge.shutdown()
    }

    @Test func nonthrowingBridgeRetainsBoundedContextRejection() async {
        let native = Qwen4PolicyEngine()
        let bridge = makePolicyBridge(native, cap: 8)
        let stream = await bridge.submitTokenized(
            promptTokens: [1], request: policyRequest(output: Int.max))
        var errors: [String] = []
        for await event in stream {
            if case .error(let message) = event { errors.append(message) }
        }
        #expect(errors == [Qwen4SupportPolicy.contextRejectionMessage])
        #expect(native.submittedOutputs.isEmpty)
        #expect(native.prefixProbes == 0)
        #expect(MultiModelBatchSchedulerEngineError.fromSchedulerMessage(errors.first ?? "")
            == .advertisedContextExceeded)
        await bridge.shutdown()
    }

    @Test func contextFailureIsAContentFreeClientError() {
        let error = MultiModelBatchSchedulerEngineError.advertisedContextExceeded
        let failure = ProviderLoop.sanitizedInferenceFailure(from: error, phase: .generation)
        #expect(failure.statusCode == 400)
        #expect(failure.code == .invalidRequest)
        #expect(failure.errorReason == .clientError)
        #expect(failure.message == "Invalid inference request.")
        #expect(MultiModelBatchSchedulerEngineError.fromSchedulerMessage(
            "token_budget_exhausted: request queue full") == .queueFull(
                "token_budget_exhausted: request queue full"))
    }

    @Test func inboundEnrichmentDeclinesAnOverflowingEnvelope() throws {
        let ordinaryData = Data(#"{"model":"private/model","messages":[{"role":"user","content":"hi"}],"max_tokens":2}"#.utf8)
        let ordinary = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: ordinaryData)
        #expect(ProviderLoop.admissionTokenEnvelope(
            request: ordinary, tokenizer: TokenizerHandle(Qwen4PolicyTokenizer()),
            modelType: "qwen4_exp", templateControls: .init()) == 5)
        let data = Data("{\"model\":\"private/model\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":\(Int.max)}".utf8)
        let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: data)
        #expect(ProviderLoop.admissionTokenEnvelope(
            request: request, tokenizer: TokenizerHandle(Qwen4PolicyTokenizer()),
            modelType: "qwen4_exp", templateControls: .init()) == nil)
    }
}

private func makePolicyBridge(
    _ engine: Qwen4PolicyEngine, cap: Int, defaultOutput: Int = 2,
    modelID: String = Qwen4SupportPolicy.ownedModelID
) -> EngineV2Bridge {
    EngineV2Bridge(
        engine: engine, modelId: modelID,
        tokenizer: TokenizerHandle(Qwen4PolicyTokenizer()), eosTokenIds: [],
        defaultMaxTokens: defaultOutput, advertisedContextTokens: cap)
}

private func policyRequest(output: Int?, modelID: String = Qwen4SupportPolicy.ownedModelID) -> ChatCompletionRequest {
    ChatCompletionRequest(
        model: modelID,
        messages: [ChatMessage(role: "user", content: "hi")], max_tokens: output)
}

private final class Qwen4PolicyEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [Int] = []
    private var probes = 0
    var submittedOutputs: [Int] { lock.withLock { outputs } }
    var prefixProbes: Int { lock.withLock { probes } }

    private struct AdmissionReached: Error {}

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        lock.withLock { outputs.append(request.maxTokens) }
        throw AdmissionReached()
    }
    func residentPrefixCandidate(for request: CBv2Request) -> CBv2ResidentPrefixCandidate? {
        lock.withLock { probes += 1 }
        return nil
    }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
              kvBytesCapacity: 0, activeTokens: 0)
    }
    func updateKVBytesCapacity(_ bytes: Int) {}
    func shutdown() async {}
}

private struct Qwen4PolicyTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1, 2, 3] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "test" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] { [1, 2, 3] }
}
