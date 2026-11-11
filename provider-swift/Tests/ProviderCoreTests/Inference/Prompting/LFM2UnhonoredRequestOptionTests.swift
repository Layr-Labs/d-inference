// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// Regression suite for request options LFM2.5-24B-A2B used to accept and then
/// ignore: the remaining thinking-disable spellings that reach the provider
/// unchanged through the coordinator (Anthropic `/v1/messages`
/// `thinking:{type:"disabled"}`, top-level `thinking:false`,
/// `chat_template_kwargs.thinking:false`) and a structured-output
/// `response_format` that nothing enforces (`json_schema`, `json_object`).
/// For the exact listing ids each is a closed client 400 before acceptance,
/// model load or template render; other families are unchanged.
/// Offline: no artifact, tokenizer or Metal device is needed.
@Suite("LFM2.5 refuses request options it would otherwise ignore")
struct LFM2UnhonoredRequestOptionTests {
    static let lfmIDs = [
        EngineV2SupportedModels.lfm25_24bA2BModelID, EngineV2SupportedModels.lfm25_24bA2BRegistryModelID,
    ]

    static var schema: [String: Any] { [
        "type": "json_schema",
        "json_schema": [
            "name": "x",
            "schema": ["type": "object", "properties": ["a": ["type": "integer"]], "required": ["a"]],
        ],
    ] }

    /// Shapes as the provider receives them after coordinator forwarding: Chat
    /// bodies pass through raw; `/v1/messages` and `/v1/responses` are lowered
    /// to the chat shape with `thinking` kept and `text.format` mapped to
    /// `response_format`.
    static var refusedForms: [[String: Any]] { [
        ["thinking": ["type": "disabled"]],
        ["thinking": ["type": " Disabled "]],
        ["thinking": false],
        ["chat_template_kwargs": ["thinking": false]],
        ["chat_template_kwargs": ["enable_thinking": true, "thinking": false]],
        ["response_format": schema],
        ["response_format": ["type": "json_object"]],
    ] }

    static var acceptedForms: [[String: Any]] { [
        ["thinking": ["type": "enabled", "budget_tokens": 1024]],
        ["thinking": true],
        ["chat_template_kwargs": ["thinking": true]],
        ["response_format": ["type": "text"]],
    ] }

    static func body(model: String, _ control: [String: Any]) throws -> Data {
        let base: [String: Any] = ["model": model, "messages": [["role": "user", "content": "hi"]]]
        return try JSONSerialization.data(withJSONObject: base.merging(control) { _, new in new })
    }

    /// The closed coordinator wire for a deterministic request refusal.
    static func expectClosedClient400(_ error: any Error, _ comment: Comment) {
        #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 400, comment)
        let failure = ProviderLoop.sanitizedInferenceFailure(from: error, phase: .request)
        #expect(failure.statusCode == 400, comment)
        #expect(failure.code == .invalidRequest, comment)
        #expect(failure.errorReason == .clientError, comment)
    }

    @Test(arguments: lfmIDs)
    func refusedBeforeTemplateRenderAsAClosedClient400(model: String) throws {
        for control in Self.refusedForms {
            let tokenizer = RenderCountingTokenizer()
            var thrown: (any Error)?
            do {
                _ = try ProviderPromptContractPipeline.tokenizeProviderBody(
                    Self.body(model: model, control), tokenizer: tokenizer, modelType: "lfm2_moe")
            } catch {
                thrown = error
            }
            let comment: Comment = "\(model) \(control)"
            guard let thrown else {
                Issue.record("accepted and ignored: \(comment)")
                continue
            }
            Self.expectClosedClient400(thrown, comment)
            #expect(tokenizer.calls == 0, comment)
        }
    }

    /// The typed refusal names the closed format spelling and the message
    /// says why, without echoing the caller's schema.
    @Test(arguments: lfmIDs)
    func structuredOutputRefusalIsTypedAndNamesTheFormat(model: String) throws {
        let cases: [([String: Any], UnenforcedResponseFormat)] = [
            (["response_format": Self.schema], .jsonSchema), (["response_format": ["type": "json_object"]], .jsonObject),
        ]
        for (control, format) in cases {
            #expect(throws: MultiModelBatchSchedulerEngineError.responseFormatNotEnforced(format)) {
                try ProviderPromptContractPipeline.tokenizeProviderBody(
                    Self.body(model: model, control), tokenizer: RenderCountingTokenizer(), modelType: "lfm2_moe")
            }
            let message = MultiModelBatchSchedulerEngineError.responseFormatNotEnforced(format).errorDescription ?? ""
            #expect(message.contains("response_format type \(format.rawValue) is not supported for this model"))
            #expect(message.contains("not enforced") && !message.contains("integer"))
        }
        // A disable control and a structured format together: reasoning first.
        #expect(throws: MultiModelBatchSchedulerEngineError.reasoningCannotBeDisabled(.thinkingType)) {
            try ProviderPromptContractPipeline.tokenizeProviderBody(
                Self.body(model: model, ["thinking": ["type": "disabled"], "response_format": Self.schema]),
                tokenizer: RenderCountingTokenizer(), modelType: "lfm2_moe")
        }
        #expect(UnenforcedResponseFormat.allCases.map(\.rawValue) == ["json_object", "json_schema"])
    }

    @Test(arguments: lfmIDs)
    func enabledThinkingAndTextFormatStayAccepted(model: String) throws {
        for control in Self.acceptedForms {
            let tokenizer = RenderCountingTokenizer()
            #expect(try ProviderPromptContractPipeline.tokenizeProviderBody(
                Self.body(model: model, control), tokenizer: tokenizer, modelType: "lfm2_moe") == [7, 8])
            #expect(tokenizer.calls == 1, "\(control)")
        }
    }

    @Test func otherFamiliesAndLookAlikeIDsAreUnaffected() throws {
        let others: [(String, String?)] = [
            ("LiquidAI/LFM2-8B-A1B-MLX-4bit", "lfm2_moe"), ("lfm2.5-24b-a2b-mtp", "lfm2_moe"),
            ("liquidai/lfm2.5-24b-a2b-mlx-4bit", "lfm2_moe"), ("qwen3.6-35b-a3b", "qwen3_5_moe"),
            ("nvidia-nemotron-3.5-lightning", "nemotron_h"), ("any-model", nil),
        ]
        for (model, modelType) in others {
            for control in Self.refusedForms {
                let tokenizer = RenderCountingTokenizer()
                _ = try ProviderPromptContractPipeline.tokenizeProviderBody(
                    Self.body(model: model, control), tokenizer: tokenizer, modelType: modelType)
                #expect(tokenizer.calls == 1, "\(model) \(control)")
            }
        }
    }

    /// Local engine (standalone server and the coordinator path's service):
    /// refused before any model lookup or acquisition.
    @Test(arguments: lfmIDs)
    func localEngineRefusesStructuredOutputBeforeAcquisition(model: String) async throws {
        let formats: [OpenAIResponseFormat] = [
            .jsonObject(), .jsonSchema(.init(name: "x", schema: .object(["type": .string("object")]))),
        ]
        for format in formats {
            let probe = AcquireCounter()
            let engine = MultiModelBatchSchedulerEngine(
                acquire: { _ in
                    await probe.record()
                    throw UnexpectedLoad.acquisition
                },
                tokenizerProvider: { _ in throw UnexpectedLoad.tokenization },
                availableModels: { [model] })
            var request = OpenAIChatCompletionRequest(model: model, messages: [.init(role: .user, content: .text("hi"))])
            request.responseFormat = format
            do {
                _ = try await engine.streamChatCompletion(request: request)
                Issue.record("accepted \(format.type)")
            } catch {
                Self.expectClosedClient400(error, "\(model) \(format.type)")
            }
            #expect(await probe.count == 0, "\(format.type)")
        }
    }

    /// Coordinator path: the sealed body is refused before acceptance or a
    /// cold load as one closed 400 frame.
    @Test(arguments: [0, 1, 2, 3])
    func encryptedIngressRefusesBeforeAcceptanceOrLoad(form: Int) async throws {
        let control: [String: Any] = [
            ["thinking": ["type": "disabled"]], ["thinking": false],
            ["chat_template_kwargs": ["thinking": false]], ["response_format": Self.schema],
        ][form]
        let hardware = HardwareInfo(
            machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
            memoryGb: 128, memoryAvailableGb: 124,
            cpuCores: .init(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546)
        let loop = try ProviderLoop(
            config: .init(
                coordinatorURL: "ws://127.0.0.1:0/unused", hardware: hardware, models: [],
                config: .init(
                    provider: .init(name: "lfm-unhonored-ingress-test", memoryReserveGB: 1),
                    backend: .init(idleTimeoutMins: 0, maxModelSlots: 1),
                    coordinator: .init(heartbeatIntervalSecs: 60))), attestationSigner: nil)
        let probe = IngressProbe()
        await loop.setEngineV2SlotHooksForTesting(.init(makeEngine: { _, _ in
            probe.recordBuild()
            return InertStubEngine()
        }))
        let requestID = "lfm-unhonored-" + UUID().uuidString
        let reservationID = UUID().uuidString.lowercased()
        let sender = NodeKeyPair.generate()
        let encrypted = try sender.encrypt(
            recipientPublicKey: await loop.keyPair.publicKeyBytes,
            plaintext: Self.body(model: EngineV2SupportedModels.lfm25_24bA2BRegistryModelID, control))
        let profile = RequestProfileBuilder()
        await loop.handleInferenceRequest(
            requestId: requestID, ciphertext: encrypted,
            senderPublicKey: sender.publicKeyBytes, cacheReceiptNonce: "lfm-unhonored-nonce",
            authenticatedCacheScope: "lfm-unhonored-scope", prefixCacheProtocol: 2,
            cacheReceiptBoundaryMode: "checkpoint", profile: profile,
            serviceReservationID: reservationID, send: SendHandle(probe.record))

        var kinds: [String] = []
        var failures: [InferenceFailure] = []
        for message in probe.snapshot {
            switch message {
            case .inferenceError(let id, let failure, _):
                #expect(id == requestID)
                kinds.append("error")
                failures.append(failure)
            case .serviceReservationReleased(let id):
                #expect(id == reservationID)
                kinds.append("released")
            default: kinds.append("unexpected")
            }
        }
        #expect(kinds == ["error", "released"], "\(control)")
        let failure = try #require(failures.first)
        #expect(failure.statusCode == 400)
        #expect(failure.code == .invalidRequest)
        #expect(failure.errorReason == .clientError)
        let observed = profile.wireObject()
        #expect(observed.acceptedSentUs == nil && observed.loadWaitStartUs == nil)
        #expect(probe.buildCount == 0)
        #expect(await loop.modelSlots.isEmpty)
        #expect(await loop.acceptedLifecycleRequests.isEmpty)
    }
}

private enum UnexpectedLoad: Error { case acquisition, tokenization }

private actor AcquireCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

private final class IngressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [OutboundMessage] = []
    private var builds = 0
    func record(_ message: OutboundMessage) { lock.withLock { messages.append(message) } }
    func recordBuild() { lock.withLock { builds += 1 } }
    var snapshot: [OutboundMessage] { lock.withLock { messages } }
    var buildCount: Int { lock.withLock { builds } }
}

/// Records template invocations; renders a fixed token pair.
private final class RenderCountingTokenizer: MLXLMCommon.Tokenizer, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [7, 8] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "hi" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] {
        lock.withLock { count += 1 }
        return [7, 8]
    }
}
