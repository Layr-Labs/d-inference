// Copyright © 2026 Eigen Labs.

import Foundation
import Hummingbird
import Logging
import MLXLMCommon
import MLXLMServer
import NIOCore
import NIOEmbedded
import Testing

@testable import ProviderCore

/// LFM2.5-24B-A2B is reasoning-only (owner decision D2): any request control
/// asking to disable reasoning is refused with a client 400 before acceptance,
/// model load or template render. Effort hints and absence stay accepted.
/// Offline: no artifact, tokenizer or Metal device is needed.
@Suite("LFM2.5 thinking-disable controls are refused")
struct LFM2ReasoningDisableRejectionTests {
    static let lfmIDs = [
        EngineV2SupportedModels.lfm25_24bA2BModelID, EngineV2SupportedModels.lfm25_24bA2BRegistryModelID,
    ]

    /// Every disable form as it reaches the provider after coordinator
    /// forwarding (Chat bodies pass through; Responses bodies are lowered to
    /// this chat shape with these keys kept), plus shadowed conflicts.
    static var disableForms: [([String: Any], ThinkingDisableField)] { [
        (["enable_thinking": false], .enableThinking),
        (["chat_template_kwargs": ["enable_thinking": false]], .chatTemplateKwargsEnableThinking),
        (["reasoning": ["enabled": false]], .reasoningEnabled),
        (["reasoning": ["effort": "none"]], .reasoningEffort),
        (["reasoning_effort": "none"], .topLevelReasoningEffort),
        (["reasoning_effort": " OFF "], .topLevelReasoningEffort),
        (["reasoning": ["effort": "0"]], .reasoningEffort),
        (["enable_thinking": true, "chat_template_kwargs": ["enable_thinking": false]],
         .chatTemplateKwargsEnableThinking),
        (["reasoning": ["enabled": true], "reasoning_effort": "none"], .topLevelReasoningEffort),
        (["reasoning": ["enabled": false, "effort": "high"]], .reasoningEnabled),
    ] }

    static var acceptedForms: [[String: Any]] { [
        [:],
        ["reasoning": ["effort": "low"]], ["reasoning": ["effort": "medium"]], ["reasoning": ["effort": "high"]],
        ["reasoning_effort": "low"], ["reasoning_effort": "medium"], ["reasoning_effort": "high"],
        ["reasoning": ["enabled": true]], ["enable_thinking": true],
        ["chat_template_kwargs": ["enable_thinking": true]],
        // Wrong types are ignored by the permissive control decode, as before.
        ["enable_thinking": "false"], ["reasoning_effort": 0],
    ] }

    static func body(model: String, _ control: [String: Any]) throws -> Data {
        let base: [String: Any] = ["model": model, "messages": [["role": "user", "content": "hi"]]]
        return try JSONSerialization.data(withJSONObject: base.merging(control) { _, new in new })
    }

    @Test(arguments: lfmIDs)
    func everyDisableFormIsRejectedBeforeTemplateRender(model: String) throws {
        for (control, field) in Self.disableForms {
            let tokenizer = CountingTokenizer()
            #expect(throws: MultiModelBatchSchedulerEngineError.reasoningCannotBeDisabled(field), "\(control)") {
                try ProviderPromptContractPipeline.tokenizeProviderBody(
                    Self.body(model: model, control), tokenizer: tokenizer, modelType: "lfm2_moe")
            }
            #expect(tokenizer.calls == 0)
        }
    }

    @Test func rejectionMessageSaysReasoningCannotBeDisabledAndNamesTheField() {
        for field in ThinkingDisableField.allCases {
            let message = MultiModelBatchSchedulerEngineError.reasoningCannotBeDisabled(field).errorDescription ?? ""
            #expect(message.hasPrefix("Reasoning cannot be disabled for this model"))
            #expect(message.contains("offending field: \(field.rawValue))"))
        }
        #expect(ThinkingDisableField.allCases.map(\.rawValue) == [
            "enable_thinking", "chat_template_kwargs.enable_thinking", "reasoning.enabled",
            "reasoning.effort", "reasoning_effort",
        ])
    }

    @Test(arguments: lfmIDs)
    func effortHintsAndAbsenceReachTheTemplateUnchanged(model: String) throws {
        for control in Self.acceptedForms {
            let tokenizer = CountingTokenizer()
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
            for (control, _) in Self.disableForms {
                let tokenizer = CountingTokenizer()
                _ = try ProviderPromptContractPipeline.tokenizeProviderBody(
                    Self.body(model: model, control), tokenizer: tokenizer, modelType: modelType)
                #expect(tokenizer.calls == 1, "\(model) \(control)")
            }
        }
    }

    /// Typed Responses (local server) carries only `reasoning.effort`; the raw
    /// body evidence still sees `reasoning.enabled` and the other raw forms.
    @Test(arguments: lfmIDs)
    func localResponsesSurfaceIsCovered(model: String) throws {
        let typed = OpenAIResponseRequest(model: model, input: .text("hi"), reasoning: .init(effort: "none"))
        #expect(throws: MultiModelBatchSchedulerEngineError.reasoningCannotBeDisabled(.reasoningEffort)) {
            try LFM2ReasoningControlPolicy.validate(request: typed.chatCompletionRequest, controls: .init())
        }
        let raw: [([String: Any], ThinkingDisableField)] = [
            (["reasoning": ["enabled": false]], .reasoningEnabled),
            (["enable_thinking": false], .enableThinking),
            (["chat_template_kwargs": ["enable_thinking": false]], .chatTemplateKwargsEnableThinking),
            (["reasoning_effort": "none"], .topLevelReasoningEffort),
        ]
        for (control, field) in raw {
            var object: [String: Any] = ["model": model, "input": "hi"]
            object.merge(control) { _, new in new }
            let decoded = try JSONDecoder().decode(
                LocalResponseRequest.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(throws: MultiModelBatchSchedulerEngineError.reasoningCannotBeDisabled(field)) {
                try LFM2ReasoningControlPolicy.validate(
                    request: decoded.request.chatCompletionRequest, controls: decoded.templateControls)
            }
        }
        for effort in ["low", "medium", "high"] {
            let accepted = OpenAIResponseRequest(model: model, input: .text("hi"), reasoning: .init(effort: effort))
            try LFM2ReasoningControlPolicy.validate(request: accepted.chatCompletionRequest, controls: .init())
        }
    }

    @Test func promptDateResolutionKeepsDisableEvidence() throws {
        let controls = ProviderLoop.extractChatTemplateControls(from: try Self.body(model: Self.lfmIDs[1],
            ["enable_thinking": true, "chat_template_kwargs": ["enable_thinking": false]]))
        #expect(controls.resolvingPromptDate().thinkingDisableEvidence.fields == [.chatTemplateKwargsEnableThinking])
        #expect(controls.withPromptDate(.capture()).thinkingDisableEvidence == controls.thinkingDisableEvidence)
    }

    @Test func typedErrorIsAClosedClient400OnTheCoordinatorWire() throws {
        let error = MultiModelBatchSchedulerEngineError.reasoningCannotBeDisabled(.reasoningEnabled)
        #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 400)
        for phase: InferenceFailurePhase in [.request, .streamStart] {
            let failure = ProviderLoop.sanitizedInferenceFailure(from: error, phase: phase)
            #expect(failure.statusCode == 400)
            #expect(failure.code == .invalidRequest)
            #expect(failure.errorReason == .clientError)
        }
        #expect(classifyInferenceErrorReason(error) == nil)
        let failure = ProviderLoop.sanitizedInferenceFailure(from: error, phase: .request)
        let wire = try ProviderProtocolCodec.encodeProviderMessage(
            .inferenceError(.init(requestId: "lfm-disable-fixture", failure: failure)))
        let json = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        #expect(json["status_code"] as? Int == 400)
        #expect(json["error_reason"] as? String == "client_error")
        #expect(json["failure_code"] as? String == "invalid_request")
        #expect(json["error"] as? String == InferenceFailureCode.invalidRequest.message)
    }

    /// The local HTTP server can say why: the fixed message names only the
    /// closed field spelling.
    @Test func localHTTPServerReturnsTheFieldNamingMessage() async throws {
        let responder = CORSResponder(inner: ThrowingResponder(
            error: MultiModelBatchSchedulerEngineError.reasoningCannotBeDisabled(.chatTemplateKwargsEnableThinking)))
        let request = Request(
            head: .init(method: .post, scheme: "http", authority: "localhost", path: "/v1/chat/completions"),
            body: .init(buffer: ByteBuffer()))
        let context = BasicRequestContext(source: ApplicationRequestContextSource(
            channel: EmbeddedChannel(), logger: Logger(label: #function)))
        let response = try await responder.respond(to: request, context: context)
        #expect(response.status == .badRequest)
        #expect(response.headers[.accessControlAllowOrigin] == "*")
        let collector = BodyCollector()
        try await response.body.write(CollectingWriter(collector: collector))
        let json = try #require(JSONSerialization.jsonObject(
            with: Data(collector.buffer.readableBytesView)) as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["type"] as? String == "invalid_request_error")
        #expect(error["message"] as? String
            == LFM2ReasoningControlPolicy.rejectionMessage(for: .chatTemplateKwargsEnableThinking))
    }

    @Test(arguments: lfmIDs)
    func localEngineRefusesBeforeModelAcquisition(model: String) async throws {
        let probe = AcquisitionProbe()
        let engine = MultiModelBatchSchedulerEngine(
            acquire: { _ in
                await probe.record()
                throw UnexpectedWork.modelAcquisition
            },
            tokenizerProvider: { _ in throw UnexpectedWork.tokenization },
            availableModels: { [model] },
            templateControls: .init(enableThinking: false))
        await #expect(throws: MultiModelBatchSchedulerEngineError.reasoningCannotBeDisabled(.enableThinking)) {
            _ = try await engine.streamChatCompletion(
                request: .init(model: model, messages: [.init(role: .user, content: .text("hi"))]))
        }
        #expect(await probe.count == 0)
    }

    /// Coordinator path: the sealed body is refused before acceptance or a
    /// cold load, as one closed 400 frame (reasoning.enabled on prefix
    /// protocol 1, the kwargs alias on protocol 2).
    @Test(arguments: [1, 2])
    func encryptedIngressRefusesBeforeAcceptanceOrLoad(prefixProtocol: Int) async throws {
        let control: [String: Any] = prefixProtocol == 1
            ? ["reasoning": ["enabled": false]] : ["chat_template_kwargs": ["enable_thinking": false]]
        let hardware = HardwareInfo(
            machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
            memoryGb: 128, memoryAvailableGb: 124,
            cpuCores: .init(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546)
        let loop = try ProviderLoop(
            config: .init(
                coordinatorURL: "ws://127.0.0.1:0/unused", hardware: hardware, models: [],
                config: .init(
                    provider: .init(name: "lfm-reasoning-ingress-test", memoryReserveGB: 1),
                    backend: .init(idleTimeoutMins: 0, maxModelSlots: 1),
                    coordinator: .init(heartbeatIntervalSecs: 60))), attestationSigner: nil)
        let probe = HandlerProbe()
        await loop.setEngineV2SlotHooksForTesting(.init(makeEngine: { _, _ in
            probe.recordBuild()
            return InertStubEngine()
        }))
        let requestID = "lfm-disable-" + UUID().uuidString
        let reservationID = UUID().uuidString.lowercased()
        let sender = NodeKeyPair.generate()
        let encrypted = try sender.encrypt(
            recipientPublicKey: await loop.keyPair.publicKeyBytes,
            plaintext: Self.body(model: EngineV2SupportedModels.lfm25_24bA2BRegistryModelID, control))
        let profile = RequestProfileBuilder()
        await loop.handleInferenceRequest(
            requestId: requestID, ciphertext: encrypted,
            senderPublicKey: sender.publicKeyBytes, cacheReceiptNonce: "lfm-disable-nonce",
            authenticatedCacheScope: "lfm-disable-scope", prefixCacheProtocol: prefixProtocol,
            cacheReceiptBoundaryMode: "checkpoint", profile: profile,
            serviceReservationID: reservationID, send: SendHandle(probe.record))

        var kinds: [String] = []
        var failures: [InferenceFailure] = []
        for message in probe.snapshot {
            switch message {
            case .prefixCacheLookup: kinds.append("lookup")
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
        #expect(kinds == (prefixProtocol == 1 ? ["lookup", "error", "released"] : ["error", "released"]))
        let failure = try #require(failures.first)
        #expect(failure.statusCode == 400)
        #expect(failure.code == .invalidRequest)
        #expect(failure.errorReason == .clientError)
        let observed = profile.wireObject()
        #expect(observed.acceptedSentUs == nil && observed.loadWaitStartUs == nil)
        #expect(probe.buildCount == 0)
        #expect(await loop.modelSlots.isEmpty)
        #expect(await loop.modelsLoading.isEmpty)
        #expect(await loop.acceptedLifecycleRequests.isEmpty)
    }
}

private enum UnexpectedWork: Error { case modelAcquisition, tokenization }

private actor AcquisitionProbe {
    private(set) var count = 0
    func record() { count += 1 }
}

private final class HandlerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [OutboundMessage] = []
    private var builds = 0
    func record(_ message: OutboundMessage) { lock.withLock { messages.append(message) } }
    func recordBuild() { lock.withLock { builds += 1 } }
    var snapshot: [OutboundMessage] { lock.withLock { messages } }
    var buildCount: Int { lock.withLock { builds } }
}

private struct ThrowingResponder: HTTPResponder {
    typealias Context = BasicRequestContext
    let error: any Error
    func respond(to request: Request, context: Context) async throws -> Response { throw error }
}

private final class BodyCollector: @unchecked Sendable {
    var buffer = ByteBuffer()
}

private struct CollectingWriter: ResponseBodyWriter {
    let collector: BodyCollector
    mutating func write(_ chunk: ByteBuffer) async throws {
        var chunk = chunk
        collector.buffer.writeBuffer(&chunk)
    }
    consuming func finish(_ trailingHeaders: HTTPFields?) async throws {}
}

/// Records template invocations; renders a fixed token pair.
private final class CountingTokenizer: MLXLMCommon.Tokenizer, @unchecked Sendable {
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
