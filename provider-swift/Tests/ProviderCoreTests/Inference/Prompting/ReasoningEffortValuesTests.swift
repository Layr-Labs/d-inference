import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// Every reasoning effort a client sends (`none` through `max`, as
/// `reasoning_effort` or `reasoning.effort`) reaches a model that reasons as
/// one of its own levels, through the production prompt pipeline
/// (`ProviderPromptContractPipeline.tokenizeProviderBody`). Hermes sends `max`;
/// Qwen 3.8 answered `high` and `max` with an untyped 400 (journey 2a, B-J2-1).
@Suite("Reasoning effort values")
struct ReasoningEffortValuesTests {
    static let efforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    enum Spelling: CaseIterable {
        case topLevel, reasoningObject

        /// The field a refusal names.
        var field: ReasoningEffortField {
            switch self {
            case .topLevel: .reasoningEffort
            case .reasoningObject: .reasoningObject
            }
        }
    }

    static func body(model: String, effort: String, _ spelling: Spelling) -> Data {
        let control = switch spelling {
        case .topLevel: #""reasoning_effort":"\#(effort)""#
        case .reasoningObject: #""reasoning":{"effort":"\#(effort)"}"#
        }
        return Data(#"{"model":"\#(model)","messages":[{"role":"user","content":"hi"}],\#(control)}"#.utf8)
    }

    /// The template context the request renders with.
    static func context(model: String, type: String, effort: String, _ spelling: Spelling) throws -> [String: any Sendable] {
        let tokenizer = EffortContextTokenizer()
        _ = try ProviderPromptContractPipeline.tokenizeProviderBody(
            body(model: model, effort: effort, spelling), tokenizer: tokenizer, modelType: type)
        return try #require(tokenizer.contexts.last)
    }

    /// Every family's table (`ReasoningEffort.swift`) has a level for each of
    /// the seven efforts, and each follows one rule: the effort's own level
    /// where the family has it, else the next one up, and the family's highest
    /// past them all, so `minimal` gets its lowest and `max` its highest.
    /// `none` switches thinking off where the family can, and gets the lowest
    /// level where it can't (GPT-OSS). The families without a table take every
    /// name too. The tests below render each row.
    @Test func everyFamilyTableCoversEveryEffort() throws {
        #expect(ReasoningEffort.allCases.map(\.rawValue) == Self.efforts)
        // The level `effort` selects among a family's `levels`, lowest first.
        func rule(_ effort: String, _ levels: [String]) -> String {
            let rank = { (name: String) in Self.efforts.firstIndex(of: name)! }
            return levels.first { rank($0) >= rank(effort) } ?? levels[levels.count - 1]
        }
        for name in Self.efforts {
            let effort = try #require(ReasoningEffort(rawValue: name))
            let thinks = name != "none"
            #expect(effort.qwen38Level.rawValue == rule(name, ["low", "medium", "xhigh"]), "Qwen 3.8, \(name)")
            #expect(effort.glmLevel?.rawValue == (thinks ? rule(name, ["low", "high", "max"]) : nil), "GLM, \(name)")
            // Super's depths: `medium_effort`, then its default, ranked as `high`.
            #expect(effort.nemotronSuperMediumEffort == (thinks ? rule(name, ["medium", "high"]) == "medium" : nil),
                    "Super, \(name)")
            #expect(effort.oneDepthThinking == thinks, "MiMo, DiffusionGemma and Gemma 4, \(name)")
            #expect(FlintRequestPolicy.acceptsEffort(name), "Flint, \(name)")
            #expect(ReasoningEffort.switchesThinkingOff(name) == !thinks, "Lightning, \(name)")
            #expect(effort.harmonyLevel.rawValue == rule(name, ["low", "medium", "high"]), "GPT-OSS, \(name)")
            #expect(ReasoningEffortPolicy.templateEffort(name, modelID: "gpt-oss-20b", modelType: "gpt_oss", thinking: nil)
                == rule(name, ["low", "medium", "high"]), "GPT-OSS rendered, \(name)")
        }
    }

    /// The Qwen 3.8 template renders `low`, `medium` and `xhigh` and raises for
    /// anything else while thinking. The Qwen 3.5 template family and the owned
    /// Flash-Next build receive the same level; Qwen 3.5, 3.6 and Bonsai 2 read
    /// only the thinking switch.
    @Test(arguments: [
        ("EigenLabs/Qwen3.8-27B-4bit-mtp", "qwen3_5"), (Qwen4SupportPolicy.ownedModelID, "qwen4_exp"),
        (Qwen4SupportPolicy.ownedModelID, "qwen4_exp_text"), ("qwen3.5-35b-a3b", "qwen3_5_moe"),
        ("ternary-bonsai-2-27b", "prism_hadamard_qwen35"),
    ])
    func theQwenFamilyRendersTheNearestQwen38Level(model: String, type: String) throws {
        let levels = ["minimal": "low", "low": "low", "medium": "medium", "high": "xhigh", "xhigh": "xhigh",
                      "max": "xhigh"]
        for spelling in Spelling.allCases {
            let off = try Self.context(model: model, type: type, effort: "none", spelling)
            #expect(off["enable_thinking"] as? Bool == false, "\(type) none \(spelling)")
            for (effort, level) in levels {
                let context = try Self.context(model: model, type: type, effort: effort, spelling)
                #expect(context["reasoning_effort"] as? String == level, "\(type) \(effort) \(spelling)")
                #expect(context["enable_thinking"] as? Bool != false, "\(type) \(effort) \(spelling)")
            }
        }
    }

    /// Every effort is taken, and only `none` sets `enable_thinking` false:
    /// Nemotron 3.5 Lightning's template has a thinking switch and reads no
    /// effort level; GPT-OSS can't switch Harmony's reasoning off, and renders
    /// its levels (`gptOSSRendersTheNearestHarmonyLevel`).
    @Test(arguments: [
        (EngineV2SupportedModels.nemotron35LightningModelID, "nemotron_h"), ("gpt-oss-20b", "gpt_oss"),
    ])
    func thinkingSwitchFamiliesTakeEveryEffort(model: String, type: String) throws {
        for effort in Self.efforts {
            for spelling in Spelling.allCases {
                let context = try Self.context(model: model, type: type, effort: effort, spelling)
                #expect((context["enable_thinking"] as? Bool == false) == (effort == "none"), "\(type) \(effort)")
            }
        }
    }

    /// Gemma 4, DiffusionGemma and MiMo have a thinking switch and no effort
    /// level: every effort but `none` reasons. Gemma 4's template defaults
    /// thinking off, so an effort turns it on, as the coordinator's prompt
    /// sidecar plans it.
    @Test(arguments: [
        ("gemma-4-26b-qat-4bit", "gemma4"), ("gemma-4-26b-text", "gemma4_text"), ("gemma-4-vision", "gemma4_vision"),
        ("native-diffusion", "diffusion_gemma"), ("mimo-v2.6-flash-mopd", "mimo_v2"),
    ])
    func binaryThinkingFamiliesReasonForEveryEffortButNone(model: String, type: String) throws {
        for effort in Self.efforts {
            for spelling in Spelling.allCases {
                let context = try Self.context(model: model, type: type, effort: effort, spelling)
                #expect(context["enable_thinking"] as? Bool == (effort != "none"), "\(type) \(effort) \(spelling)")
            }
        }
    }

    /// GPT-OSS renders each effort at the nearest of Harmony's levels (`low`,
    /// `medium`, `high`), the higher one between two; Harmony can't switch its
    /// reasoning off, so `none` renders `low`. A direct caller's `high` renders
    /// `high`; the coordinator caps OpenRouter's traffic at `medium`. The model
    /// type identifies GPT-OSS behind any catalog ID.
    @Test func gptOSSRendersTheNearestHarmonyLevel() throws {
        let levels = ["none": "low", "minimal": "low", "low": "low", "medium": "medium", "high": "high",
                      "xhigh": "high", "max": "high"]
        for model in ["gpt-oss-20b", "opaque-alias"] {
            for spelling in Spelling.allCases {
                for (effort, level) in levels {
                    let context = try Self.context(model: model, type: "gpt_oss", effort: effort, spelling)
                    #expect(context["reasoning_effort"] as? String == level, "\(model) \(effort) \(spelling)")
                }
            }
        }
    }

    /// GLM-5.3-Flash renders `low`, `high` and `max`; between two, an effort
    /// rounds up, as the coordinator's pool and sidecar map it.
    @Test func glmRendersItsNearestLevel() throws {
        let levels = ["minimal": "low", "low": "low", "medium": "high", "high": "high", "xhigh": "max", "max": "max"]
        for spelling in Spelling.allCases {
            let off = try Self.context(model: "glm-5.3-flash", type: "glm5_next", effort: "none", spelling)
            #expect(off[GLM5NextPromptPolicy.thinkingOffContextKey] as? Bool == false)
            for (effort, level) in levels {
                let context = try Self.context(model: "glm-5.3-flash", type: "glm5_next", effort: effort, spelling)
                #expect(context["reasoning_effort"] as? String == level, "\(effort) \(spelling)")
                #expect(context[GLM5NextPromptPolicy.thinkingOffContextKey] == nil, "\(effort) \(spelling)")
            }
        }
    }

    /// Flint chooses whether to reason: every effort is taken, with no effect.
    @Test func flintTakesEveryEffort() throws {
        for effort in Self.efforts {
            for spelling in Spelling.allCases {
                _ = try Self.context(model: "RecursiveSI/flint-int4", type: "flint", effort: effort, spelling)
            }
        }
    }

    /// Nemotron 3.5 Super renders two depths: `medium_effort`, and its default.
    @Test func nemotronSuperRendersMediumOrItsDefaultDepth() throws {
        let medium = ["minimal": true, "low": true, "medium": true, "high": false, "xhigh": false, "max": false]
        for spelling in Spelling.allCases {
            let off = try NemotronSuperPromptContract.controls(body: Self.body(model: "m", effort: "none", spelling))
            #expect(!off.enableThinking && !off.mediumEffort)
            for (effort, isMedium) in medium {
                let controls = try NemotronSuperPromptContract.controls(
                    body: Self.body(model: "m", effort: effort, spelling))
                #expect(controls.enableThinking, "\(effort) \(spelling)")
                #expect(controls.mediumEffort == isMedium, "\(effort) \(spelling)")
            }
        }
    }

    /// Nemotron 3.5 Super reads both fields and refuses two that differ, even
    /// two names at one depth, as such: not as an unknown name, which an
    /// unknown `reasoning.effort` is first. The same effort in both, in any
    /// spelling, renders.
    @Test func nemotronSuperRefusesTwoDifferentEfforts() throws {
        func controls(_ top: String, _ nested: String) throws -> NemotronSuperPromptContract.Controls {
            try NemotronSuperPromptContract.controls(body: Data(
                #"{"model":"m","messages":[],"reasoning_effort":"\#(top)","reasoning":{"effort":"\#(nested)"}}"#.utf8))
        }
        for (top, nested) in [("high", "max"), ("minimal", "medium"), ("turbo", "low")] {
            #expect(throws: NemotronSuperPromptContract.Failure.conflictingReasoningEfforts, "\(top)/\(nested)") {
                try controls(top, nested)
            }
        }
        #expect(throws: NemotronSuperPromptContract.Failure.unknownReasoningEffort(.reasoningObject)) {
            try controls("low", "turbo")
        }
        #expect(try controls("high", " HIGH ") == .init(enableThinking: true, mediumEffort: false))
        #expect(try controls("Low", "low") == .init(enableThinking: true, mediumEffort: true))
    }

    static let reasoningModels: [(String, String)] = [
        ("EigenLabs/Qwen3.8-27B-4bit-mtp", "qwen3_5"), (Qwen4SupportPolicy.ownedModelID, "qwen4_exp"),
        ("qwen3.5-35b-a3b", "qwen3_5_moe"), ("ternary-bonsai-2-27b", "prism_hadamard_qwen35"),
        ("gemma-4-26b-qat-4bit", "gemma4"), ("native-diffusion", "diffusion_gemma"), ("gpt-oss-20b", "gpt_oss"),
        (EngineV2SupportedModels.nemotron35LightningModelID, "nemotron_h"), ("mimo-v2.6-flash-mopd", "mimo_v2"),
        ("glm-5.3-flash", "glm5_next"), ("RecursiveSI/flint-int4", "flint"),
    ]

    /// An effort that is none of the names is refused, never rendered or
    /// silently ignored, by every model that reasons, with the error that
    /// names the field it came in.
    @Test func anUnknownEffortIsRefusedByEveryModelThatReasons() throws {
        for (model, type) in Self.reasoningModels {
            for spelling in Spelling.allCases {
                let tokenizer = EffortContextTokenizer()
                #expect(throws: MultiModelBatchSchedulerEngineError.unsupportedReasoningEffort(spelling.field),
                        "\(type) \(spelling)") {
                    try ProviderPromptContractPipeline.tokenizeProviderBody(
                        Self.body(model: model, effort: "turbo", spelling), tokenizer: tokenizer, modelType: type)
                }
                #expect(tokenizer.contexts.isEmpty, "\(type) \(spelling)")
            }
        }
        for spelling in Spelling.allCases {
            #expect(throws: NemotronSuperPromptContract.Failure.unknownReasoningEffort(spelling.field)) {
                try NemotronSuperPromptContract.controls(body: Self.body(model: "m", effort: "turbo", spelling))
            }
        }
        // GLM-5.3-Flash also reads its template's own spelling.
        let kwargs = #"{"model":"glm-5.3-flash","messages":[{"role":"user","content":"hi"}],"#
            + #""chat_template_kwargs":{"reasoning_effort":"turbo"}}"#
        #expect(throws: MultiModelBatchSchedulerEngineError.unsupportedReasoningEffort(.templateKwargs)) {
            try ProviderPromptContractPipeline.tokenizeProviderBody(
                Data(kwargs.utf8), tokenizer: EffortContextTokenizer(), modelType: "glm5_next")
        }
    }

    /// A model that doesn't reason ignores the effort, whatever it is.
    @Test func aModelThatDoesNotReasonIgnoresTheEffort() throws {
        for effort in Self.efforts + ["turbo"] {
            for spelling in Spelling.allCases {
                let context = try Self.context(model: "llama-3.2-3b", type: "llama", effort: effort, spelling)
                #expect(context["reasoning_effort"] as? String == effort)
            }
        }
    }
}

/// Records each chat-template context it renders; everything else is `inner`'s.
final class EffortContextTokenizer: MLXLMCommon.Tokenizer, @unchecked Sendable {
    let inner: any MLXLMCommon.Tokenizer
    private let lock = NSLock()
    private var recorded: [[String: any Sendable]] = []

    init(_ inner: any MLXLMCommon.Tokenizer = ParityTokenizer(eos: "<|im_end|>", harmony: false)) {
        self.inner = inner
    }

    var contexts: [[String: any Sendable]] { lock.withLock { recorded } }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        inner.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        inner.decode(tokenIds: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { inner.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { inner.convertIdToToken(id) }
    var bosToken: String? { inner.bosToken }
    var eosToken: String? { inner.eosToken }
    var unknownToken: String? { inner.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        lock.withLock { recorded.append(additionalContext ?? [:]) }
        return try inner.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}
