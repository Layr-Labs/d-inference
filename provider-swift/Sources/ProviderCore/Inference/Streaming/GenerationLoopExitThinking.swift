// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

/// The loop guard's way out of a repeating thought.
///
/// When the guard (`GenerationLoopGuard`) finds a verbatim loop while the row
/// is inside its reasoning channel, the row is stopped as before, and the
/// request then continues from the same tokens with the family's
/// end-of-thinking marker appended, so the model writes its answer instead of
/// ending with an empty one (`LoopExitThinkingContinuation`). A loop outside
/// the reasoning channel still ends as `length`.
public struct GenerationLoopExitThinking: Sendable {
    /// Text that opens the reasoning channel in the generated stream.
    let openMarker: String
    /// Text that closes it.
    let closeMarker: String
    /// The tokens appended to end the thought: the family's closing text, with
    /// the close marker as its own special token.
    let exitTokens: [Int]
    /// Their text, as the client's stream shows them.
    let exitText: String
    /// The close marker's own token. A row that produced it after the stop
    /// closed its thought itself.
    let closeToken: Int
    /// The prompt itself left the reasoning channel open.
    let startsInside: Bool
    /// Shared with the continuation: the row's tokens and the guard's request.
    let record: GenerationLoopExitRecord
    /// Where the continuation's stop strings apply when the exit itself opens
    /// the answer (GPT-OSS's final header); nil keeps the request's scope.
    let answerStopScope: CBv2StopStringScope?
    /// The most the answer after the thought may take, within the request's own
    /// budget: a model that wrote a loop may write a near-verbatim one next,
    /// which the guard does not see.
    var answerTokenLimit = GenerationLoopExitThinkingPolicy.answerTokenLimit

    init(
        openMarker: String, closeMarker: String, exitTokens: [Int], exitText: String, closeToken: Int? = nil,
        startsInside: Bool, record: GenerationLoopExitRecord, answerStopScope: CBv2StopStringScope? = nil,
        answerTokenLimit: Int = GenerationLoopExitThinkingPolicy.answerTokenLimit
    ) {
        self.openMarker = openMarker
        self.closeMarker = closeMarker
        self.exitTokens = exitTokens
        self.exitText = exitText
        self.closeToken = closeToken ?? exitTokens.first ?? -1
        self.startsInside = startsInside
        self.record = record
        self.answerStopScope = answerStopScope
        self.answerTokenLimit = answerTokenLimit
    }
}

/// One request's generated tokens and whether its loop guard asked to end
/// the thought. Written by the bridge's pump (through the guard) and read by
/// the scheduler's continuation once the row has ended.
public final class GenerationLoopExitRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [Int] = []
    private var detection: GenerationLoopDetector.Detection?
    private var closedAfter = false

    func append(_ new: [Int]) {
        guard !new.isEmpty else { return }
        lock.withLock { tokens.append(contentsOf: new) }
    }

    func requestExit(_ detection: GenerationLoopDetector.Detection) {
        lock.withLock { if self.detection == nil { self.detection = detection } }
    }

    /// The detection that ended the thought, or nil while none did.
    var requested: GenerationLoopDetector.Detection? { lock.withLock { detection } }

    /// Every token the row produced, the in-flight ones after the stop included.
    var generatedTokens: [Int] { lock.withLock { tokens } }

    func noteClosedAfterStop() {
        lock.withLock { closedAfter = true }
    }

    /// The row's text after the stop closed the thought: a close whose token
    /// came before its text, or one spelled as ordinary pieces.
    var closedAfterStop: Bool { lock.withLock { closedAfter } }
}

/// Which requests may end a repeating thought instead of the whole answer.
///
/// On by default for Gemma 4, whose thought closes with one special token
/// (`<channel|>`), and GPT-OSS (`gpt_oss`), whose Harmony analysis message
/// ends with `<|end|>` and is followed by the next assistant message
/// (`harmonyAnalysis`) or, for a request without tools, by the final
/// channel's header (`harmonyAnalysisToFinal`). Qwen 3.5/3.6
/// (`qwen3_5_moe`, `qwen3_5`), whose template closes a thought with
/// `\n</think>\n\n` (`</think>` is one special token), are listed but off by
/// default: their thought loops were too rare in the A/B to show rescues, and
/// `qwen3_5` is also Qwen 3.8 27B. The guard keeps ending every other loop as
/// `length`: a loop outside the thought, a family that is not on, a request
/// that asked for logprobs (the forced tokens have none), a pair's request.
/// Nemotron 3.5 Super (`nemotron_h_omni`) has the marker and is off by default
/// until its A/B; it takes its owner's own route (`NemotronSuperLocalBinding`),
/// which continues the answer the same way.
///
/// `DARKBLOOM_LOOP_EXIT_THINKING`: unset, `1` or `on` keeps the default list;
/// `0` or `off` turns it off; any other value is the comma-separated list of
/// `model_type`s to allow, among those with a listed marker.
/// `DARKBLOOM_GPTOSS_FINAL_EXIT`: `0`, `off` or `false` keeps GPT-OSS's exit to
/// requests that declare tools (#2070's exit alone); anything else leaves it on.
enum GenerationLoopExitThinkingPolicy {
    static let environmentKey = "DARKBLOOM_LOOP_EXIT_THINKING"

    struct Markers: Sendable, Equatable {
        let open: String
        let close: String
        /// What the family's template writes around the close marker when the
        /// model ends its own thought (Qwen: `\n</think>\n\n`).
        var before = ""
        var after = ""
        /// Control tokens spelled in `after` (Harmony's `<|start|>`): each must
        /// be fed as its own token, never as ordinary pieces of its text.
        var controls: [String] = []
        /// The continuation's stop scope when `after` opens the answer itself.
        var answerStopScope: CBv2StopStringScope?
    }

    /// The families whose thought this can end, by `model_type`.
    static let markersByModelType: [String: Markers] = [
        "gpt_oss": harmonyAnalysis,
        "gemma4": .init(open: "<|channel>", close: "<channel|>"),
        "gemma4_text": .init(open: "<|channel>", close: "<channel|>"),
        "qwen3_5": qwenThink,
        "qwen3_5_moe": qwenThink,
        // Super's template writes `reasoning + "</think>" + content`: nothing around the marker.
        "nemotron_h_omni": .init(open: "<think>", close: "</think>"),
    ]

    /// GPT-OSS's Harmony analysis message (`<|channel|>analysis<|message|>` …
    /// `<|end|>`). The exit ends that message and starts the next assistant
    /// message, `<|end|><|start|>assistant`, as the model does after its own
    /// analysis: the model then picks the channel itself, `final` for an
    /// answer or `commentary to=functions.…` for a tool call.
    static let harmonyAnalysis = Markers(
        open: "<|channel|>analysis", close: "<|end|>", after: "<|start|>assistant", controls: ["<|start|>"])

    /// GPT-OSS without tools: the same end of the analysis, then the final
    /// channel's header, so the model writes its answer. Left to pick its
    /// channel, the model reopened its analysis and looped again in 10 of 10
    /// GPQA loopers without tools (GPU A/B, effort high, T 0); without tools
    /// there is no call to pick. Its output starts inside the final channel,
    /// so the request's stops apply from its first token.
    static let harmonyAnalysisToFinal = Markers(
        open: "<|channel|>analysis", close: "<|end|>", after: "<|start|>assistant<|channel|>final<|message|>",
        controls: ["<|start|>", "<|channel|>", "<|message|>"],
        answerStopScope: GPTOSSHarmonyTemplateFix.insideFinalChannelStopScope)

    /// A family's exit for a request without tools, where it differs.
    static let markersWithoutToolsByModelType: [String: Markers] = ["gpt_oss": harmonyAnalysisToFinal]

    /// As the Qwen 3.5/3.6 template writes a closed thought:
    /// `<think>\n…\n</think>\n\n` before the answer.
    static let qwenThink = Markers(open: "<think>", close: "</think>", before: "\n", after: "\n\n")

    static let defaultModelTypes: Set<String> = ["gemma4", "gemma4_text", "gpt_oss"]

    /// The answer's own cap. Gemma's GPQA answers after a thought are under
    /// 1,000 tokens; a Tau2 reply or call is shorter.
    static let answerTokenLimit = 8_192

    enum Setting: Sendable, Equatable {
        case off
        case modelTypes(Set<String>)
    }

    static let current = setting(environment: ProcessInfo.processInfo.environment)

    /// Whether a GPT-OSS request without tools gets its exit
    /// (`harmonyAnalysisToFinal`); off keeps the exit to requests with tools.
    static let finalExitEnvironmentKey = "DARKBLOOM_GPTOSS_FINAL_EXIT"

    static let finalExitCurrent = finalExit(environment: ProcessInfo.processInfo.environment)

    static func finalExit(environment: [String: String]) -> Bool {
        let raw = environment[finalExitEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !["0", "off", "false"].contains(raw ?? "")
    }

    static func setting(environment: [String: String]) -> Setting {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return .modelTypes(defaultModelTypes) }
        switch raw.lowercased() {
        case "1", "on", "true": return .modelTypes(defaultModelTypes)
        case "0", "off", "false": return .off
        default:
            let types = Set(raw.lowercased().split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            return types.isEmpty ? .off : .modelTypes(types)
        }
    }

    /// The exit for one guarded request, or nil when its loops must
    /// keep ending as `length`.
    static func resolve(
        modelType: String?,
        tokenizer: any MLXLMCommon.Tokenizer,
        promptTokens: [Int],
        logprobs: Bool,
        declaresTools: Bool = false,
        setting: Setting = current,
        finalExit: Bool = finalExitCurrent
    ) -> GenerationLoopExitThinking? {
        guard case .modelTypes(let enabled) = setting,
              let modelType = modelType?.lowercased(), enabled.contains(modelType),
              let markers = exitMarkers(modelType: modelType, declaresTools: declaresTools, finalExit: finalExit),
              !logprobs,
              let close = tokenizer.convertTokenToId(markers.close),
              tokenizer.convertIdToToken(close) == markers.close
        else { return nil }
        let tail = tokenizer.decode(
            tokenIds: Array(promptTokens.suffix(ReasoningPromptProbe.tailTokenCount)),
            skipSpecialTokens: false)
        // The marker is its own token, so the text on each side tokenizes as
        // it does in the template's whole closing text.
        func spell(_ text: String) -> [Int] {
            text.isEmpty ? [] : tokenizer.encode(text: text, addSpecialTokens: false)
        }
        let exitTokens = spell(markers.before) + [close] + spell(markers.after)
        let exitText = markers.before + markers.close + markers.after
        // The model must be fed what the client is shown, its control tokens
        // as themselves.
        guard tokenizer.decode(tokenIds: exitTokens, skipSpecialTokens: false) == exitText,
              markers.controls.allSatisfy({ control in
                  tokenizer.convertTokenToId(control).map {
                      tokenizer.convertIdToToken($0) == control && exitTokens.contains($0)
                  } ?? false
              })
        else { return nil }
        return GenerationLoopExitThinking(
            openMarker: markers.open, closeMarker: markers.close,
            exitTokens: exitTokens, exitText: exitText, closeToken: close,
            startsInside: endsInside(tail, open: markers.open, close: markers.close),
            record: GenerationLoopExitRecord(), answerStopScope: markers.answerStopScope)
    }

    /// The family's markers for this request: without tools, its own exit for
    /// that case when it has one, and none when that exit is switched off.
    static func exitMarkers(modelType: String, declaresTools: Bool, finalExit: Bool) -> Markers? {
        guard !declaresTools, let withoutTools = markersWithoutToolsByModelType[modelType] else {
            return markersByModelType[modelType]
        }
        return finalExit ? withoutTools : nil
    }

    /// Whether `text` leaves the channel open: its last marker opens it.
    static func endsInside(_ text: String, open: String, close: String) -> Bool {
        guard let opened = text.range(of: open, options: .backwards) else { return false }
        guard let closed = text.range(of: close, options: .backwards) else { return true }
        return opened.lowerBound > closed.lowerBound
    }
}
