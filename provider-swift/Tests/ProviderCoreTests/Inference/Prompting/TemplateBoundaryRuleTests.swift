// Copyright © 2026 Eigen Labs.
// The message-boundary rule read from a chat template through the request
// path: decode, normalization and the tokenizer's own render.

import Foundation
import MLXLLM
import Testing

@testable import MLXLMCommon
@testable import ProviderCore

/// One token per UTF-8 byte, plus the special tokens a ChatML template writes.
private struct ChatMLProbeTokenizer: MLXLMCommon.Tokenizer {
    static let specials = ["<|im_start|>", "<|im_end|>", "<tool_call>", "</tool_call>"]
    static let imStart = 256
    static let imEnd = 257

    /// Replies end in ordinary text instead of `<|im_end|>`.
    var textOnlyTurns = false

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        var ids: [Int] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            if let special = Self.specials.firstIndex(where: { rest.hasPrefix($0) }) {
                ids.append(256 + special)
                rest = rest.dropFirst(Self.specials[special].count)
            } else {
                ids += rest.prefix(1).utf8.map(Int.init)
                rest = rest.dropFirst()
            }
        }
        return ids
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        var bytes: [UInt8] = []
        for id in tokenIds {
            if id < 256 {
                bytes.append(UInt8(id))
            } else if !skipSpecialTokens {
                bytes += Array(Self.specials[id - 256].utf8)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        let open = textOnlyTurns ? "" : "<|im_start|>"
        let close = textOnlyTurns ? "\n" : "<|im_end|>\n"
        var text = ""
        if let tools, !tools.isEmpty {
            text += "\(open)system\ntools: \(tools.count)\(close)"
        }
        for message in messages {
            text += "\(open)\(message["role"] as? String ?? "")\n"
            if let reasoning = message["reasoning_content"] as? String, !reasoning.isEmpty {
                text += "<think>\(reasoning)</think>\n"
            }
            text += message["content"] as? String ?? ""
            for call in message["tool_calls"] as? [[String: any Sendable]] ?? [] {
                let function = call["function"] as? [String: any Sendable]
                let arguments = (function?["arguments"] as? [String: any Sendable] ?? [:])
                    .map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
                text += "<tool_call>\(function?["name"] as? String ?? "")(\(arguments))</tool_call>"
            }
            text += close
        }
        // The tokenizer bridge defaults this key to true.
        if additionalContext?["add_generation_prompt"] as? Bool ?? true {
            text += "\(open)assistant\n"
            if additionalContext?["enable_thinking"] as? Bool == false {
                text += "<think>\n\n</think>\n\n"
            }
        }
        return encode(text: text, addSpecialTokens: false)
    }
}

@Suite("Template boundary rule")
struct TemplateBoundaryRuleTests {
    private static let modelID = "test/chatml"
    private static let header = [ChatMLProbeTokenizer.imStart] + Array("assistant\n".utf8).map(Int.init)
    private static let chatML = CBv2CanonicalBoundaryRule(
        open: header, close: [[ChatMLProbeTokenizer.imEnd, 10]])

    private func gridScheduler(_ extra: [String: String] = [:]) -> CBv2SchedulerConfig {
        EngineV2Factory.productionSchedulerConfig(
            maxConcurrentRequests: 8,
            environment: [EngineV2Factory.canonicalPrefillGridKey: "512"].merging(extra) { $1 })
    }

    @Test("a probe is an ordinary chat request")
    func probeIsARequest() throws {
        let probe = CBv2BoundaryProbe(
            messages: [
                ["role": "user", "content": "What is the weather in Paris?"],
                [
                    "role": "assistant", "content": "",
                    "tool_calls": [
                        [
                            "id": "call_1", "type": "function",
                            "function": [
                                "name": "get_weather", "arguments": ["city": "Paris"],
                            ] as [String: any Sendable],
                        ] as [String: any Sendable]
                    ],
                ],
            ],
            tools: [
                [
                    "type": "function",
                    "function": [
                        "name": "get_weather", "description": "Current weather.",
                        "parameters": ["type": "object", "properties": [String: String]()]
                            as [String: any Sendable],
                    ] as [String: any Sendable],
                ]
            ],
            addGenerationPrompt: false, enableThinking: false)
        let body = try TemplateBoundaryRule.requestBody(for: probe, modelID: Self.modelID)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == Self.modelID)
        #expect(json["enable_thinking"] as? Bool == false)
        let call = try #require(
            ((json["messages"] as? [[String: Any]])?[1]["tool_calls"] as? [[String: Any]])?.first)
        #expect((call["function"] as? [String: Any])?["arguments"] as? String == #"{"city":"Paris"}"#)
        let request = try ProviderLoop.decodeOpenAIRequest(body, modelType: nil)
        #expect(request.messages.count == 2 && request.tools?.count == 1)
    }

    @Test("without a generation prompt the request renders the same prompt less its header")
    func noGenerationPromptDropsOnlyTheHeader() throws {
        let tokenizer = ChatMLProbeTokenizer()
        let body = try TemplateBoundaryRule.requestBody(
            for: CBv2BoundaryProbe(
                messages: [["role": "user", "content": "Hello."]], addGenerationPrompt: false),
            modelID: Self.modelID)
        let prompt = try ProviderPromptContractPipeline.tokenizeProviderBody(
            body, tokenizer: tokenizer, modelType: nil)
        let history = try ProviderPromptContractPipeline.tokenizeProviderBody(
            body, tokenizer: tokenizer, modelType: nil, addGenerationPrompt: false)
        #expect(prompt == history + Self.header)
    }

    @Test("a ChatML template gives its rule, and every two-turn check holds")
    func chatMLRule() {
        let derivation = TemplateBoundaryRule.derive(
            tokenizer: ChatMLProbeTokenizer(), modelType: nil, modelID: Self.modelID)
        #expect(derivation.rule == Self.chatML)
        for scenario in CBv2BoundaryRuleDerivation.Scenario.allCases {
            #expect(derivation.verdicts[scenario] == .held, "\(scenario.rawValue)")
        }
        #expect(
            TemplateBoundaryRule.summary(of: derivation)
                == "template boundary rule accepted open_tokens=11 close_tokens=2"
                + " checks=plain=held,noSystem=held,thinkingOff=held,replyHadReasoning=held,toolCall=held"
        )
    }

    @Test("a template whose turns end in ordinary text gets no rule")
    func rejectedTemplateGetsNoRule() {
        let derivation = TemplateBoundaryRule.derive(
            tokenizer: ChatMLProbeTokenizer(textOnlyTurns: true), modelType: nil,
            modelID: Self.modelID)
        #expect(derivation.candidate != nil && derivation.rule == nil)
        #expect(
            TemplateBoundaryRule.summary(of: derivation).hasPrefix("template boundary rule rejected "))
        #expect(
            TemplateBoundaryRule.rule(
                for: gridScheduler(), tokenizer: ChatMLProbeTokenizer(textOnlyTurns: true),
                modelType: nil, modelID: Self.modelID) == nil)
    }

    @Test("a tokenizer that renders nothing gets no rule")
    func emptyRenderGetsNoRule() {
        let derivation = TemplateBoundaryRule.derive(
            tokenizer: StubBridgeTokenizer(), modelType: nil, modelID: Self.modelID)
        #expect(derivation.candidate == nil && derivation.rule == nil)
        #expect(
            TemplateBoundaryRule.summary(of: derivation)
                == "template boundary rule not_derived open_tokens=0 close_tokens= checks=")
    }

    @Test("the template is read only with the grid on and no operator rule")
    func onlyWithTheGridAndNoOperatorRule() {
        func rule(_ scheduler: CBv2SchedulerConfig) -> CBv2CanonicalBoundaryRule? {
            TemplateBoundaryRule.rule(
                for: scheduler, tokenizer: ChatMLProbeTokenizer(), modelType: nil,
                modelID: Self.modelID)
        }
        #expect(rule(gridScheduler()) == Self.chatML)
        #expect(
            rule(EngineV2Factory.productionSchedulerConfig(maxConcurrentRequests: 8, environment: [:]))
                == nil)
        #expect(rule(gridScheduler([EngineV2Factory.canonicalBoundariesKey: "7;10"])) == nil)
        // A malformed operator value is no operator rule.
        #expect(rule(gridScheduler([EngineV2Factory.canonicalBoundariesKey: "7,x;10"])) == Self.chatML)
    }
}

private final class LoadLineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func record(_ line: String) { lock.withLock { stored.append(line) } }
    var ruleLines: [String] {
        lock.withLock { stored.filter { $0.contains("template boundary rule") } }
    }
}

private struct UnusedProcessor: UserInputProcessor {
    private struct UnusedInput: Error {}
    func prepare(input: UserInput) async throws -> LMInput { throw UnusedInput() }
}

@Suite("Template boundary rule in a slot build", .serialized)
struct TemplateBoundaryRuleSlotTests {
    private static let modelID = "template-boundary-rule-fixture"
    private static let modelType = "gemma4_text"

    init() {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }

    /// The scheduler config of a slot's engine, and the rule lines its build logged.
    private func slot(_ environment: [String: String]) async throws -> (CBv2SchedulerConfig, [String]) {
        let configuration = try JSONDecoder().decode(
            MLXLLM.Gemma4TextConfiguration.self,
            from: Data(
                """
                {"model_type":"gemma4_text","hidden_size":64,"num_hidden_layers":2,
                 "intermediate_size":128,"num_attention_heads":4,"num_key_value_heads":2,
                 "head_dim":64,"global_head_dim":64,"num_kv_shared_layers":0,
                 "vocab_size":128,"hidden_size_per_layer_input":0,"sliding_window":16,
                 "sliding_window_pattern":2,"max_position_embeddings":8192,"use_double_wide_mlp":false}
                """.utf8))
        let target = Gemma4TextModel(configuration)
        let tokenizer = ChatMLProbeTokenizer()
        let container = ModelContainer(
            context: .init(
                configuration: ModelConfiguration(id: Self.modelID), model: target,
                processor: UnusedProcessor(), tokenizer: tokenizer))
        let preparedModel = EngineV2PreparedModel(
            snapshot: .init(model: target, eosTokenIds: [1], extraEOSTokens: []),
            servingModel: target, assistant: nil,
            mtpStatus: .disabled(.configDisabled, configured: false), mtpArtifact: nil)
        let hash = String(repeating: "a", count: 64)
        let contract = "template-boundary-rule-test-contract"
        let recorder = LoadLineRecorder()
        let bundle = try await EngineV2SlotFactory.makeProductionBundle(
            modelId: Self.modelID, modelType: Self.modelType, isVLM: false, modelDirectory: nil,
            container: container, tokenizer: TokenizerHandle(tokenizer),
            sizing: .init(
                weightsBytes: 1, fp16KVBytesPerToken: 512, maxContextLength: 8_192,
                defaultMaxTokens: 32),
            kvBytesCapacity: 4 << 20, maxConcurrentRequests: 1, kvBudget: nil,
            weightHash: hash,
            specDecPreparation: .init(
                artifact: nil, status: .disabled(.configDisabled, configured: false)),
            preparedModel: preparedModel,
            assemblyOverrides: .init(
                promptContractID: contract,
                completeCheckpointIdentity: .init(
                    modelAggregateHash: hash, promptContractID: contract,
                    buildID: "template-boundary-rule-test", numericsFingerprint: "native-fp32")),
            environment: [
                PrefixCachePolicy.environmentFlag: "0", KVBackendGuardStore.pathEnvKey: "/dev/null",
            ].merging(environment) { $1 },
            logInfo: { recorder.record($0) })
        let engine = try #require(await bundle.bridge.ownedEngine as? EngineV2)
        let scheduler = engine.schedulerConfig
        await bundle.bridge.shutdown()
        return (scheduler, recorder.ruleLines)
    }

    @Test("the slot's engine gets the template's rule, and an operator rule replaces it")
    func slotEngineGetsTheRule() async throws {
        let grid = [EngineV2Factory.canonicalPrefillGridKey: "512"]
        let derivation = TemplateBoundaryRule.derive(
            tokenizer: ChatMLProbeTokenizer(), modelType: Self.modelType, modelID: Self.modelID)
        let derived = try #require(derivation.rule)

        let (fromTemplate, templateLines) = try await slot(grid)
        #expect(fromTemplate.canonicalPrefillGridTokens == 512)
        #expect(fromTemplate.canonicalBoundaryRule == derived)
        #expect(
            templateLines
                == ["engine_v2: \(Self.modelID) \(TemplateBoundaryRule.summary(of: derivation))"])

        let (fromOperator, operatorLines) = try await slot(
            grid.merging([EngineV2Factory.canonicalBoundariesKey: "7;10"]) { $1 })
        #expect(
            fromOperator.canonicalBoundaryRule == CBv2CanonicalBoundaryRule(open: [7], close: [[10]]))
        #expect(operatorLines.isEmpty)

        let (off, offLines) = try await slot([:])
        #expect(off.canonicalPrefillGridTokens == nil && off.canonicalBoundaryRule == nil)
        #expect(offLines.isEmpty)
    }
}
