// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// ASCII bytes plus Gemma 4's turn and thought markers, each one special token.
struct GemmaThoughtTestTokenizer: MLXLMCommon.Tokenizer {
    static let channelOpen = 1000
    static let channelClose = 1001
    static let turnClose = 1002
    static let eos = 1003
    static let specials: [(String, Int)] = [
        ("<|channel>", 1000), ("<channel|>", 1001), ("<turn|>", 1002), ("<eos>", 1003), ("<|turn>", 1004),
    ]

    var markers = Self.specials

    static func tokens(_ text: String, markers: [(String, Int)] = specials) -> [Int] {
        let bytes = Array(text.utf8)
        var ids: [Int] = []
        var index = 0
        while index < bytes.count {
            if let marker = markers.first(where: { bytes[index...].starts(with: Array($0.0.utf8)) }) {
                ids.append(marker.1)
                index += marker.0.utf8.count
            } else {
                ids.append(Int(bytes[index]))
                index += 1
            }
        }
        return ids
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { Self.tokens(text, markers: markers) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.compactMap(convertIdToToken).joined()
    }
    func convertTokenToId(_ token: String) -> Int? { markers.first { $0.0 == token }?.1 }
    func convertIdToToken(_ id: Int) -> String? {
        if let marker = markers.first(where: { $0.1 == id }) { return marker.0 }
        guard (0..<128).contains(id), let scalar = UnicodeScalar(id) else { return nil }
        return String(Character(scalar))
    }
    var bosToken: String? { nil }
    var eosToken: String? { "<eos>" }
    var unknownToken: String? { nil }
    /// The served Gemma 4 template's shape with thinking on: the model turn
    /// is open and the model opens its own thought.
    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        Self.tokens("<|turn>user\nhi<turn|>\n<|turn>model\n", markers: markers)
    }
}

@Suite("Loop guard: ending a repeating thought")
struct GenerationLoopExitThinkingTests {
    private func gemmaExit(startsInside: Bool = false) -> GenerationLoopExitThinking {
        GenerationLoopExitThinking(
            openMarker: "<|channel>", closeMarker: "<channel|>", exitTokens: [GemmaThoughtTestTokenizer.channelClose],
            exitText: "<channel|>", startsInside: startsInside, record: GenerationLoopExitRecord())
    }

    private func loopGuard(_ exit: GenerationLoopExitThinking?) -> GenerationLoopGuard {
        GenerationLoopGuard(
            modelType: "gemma4", toolCallMarkers: GenerationLoopGuardPolicy.genericToolCallMarkers,
            exitThinking: exit)
    }

    /// Window 7's Gemma q63: one 19-token clause, verbatim.
    private func clause(_ count: Int) -> [(String, [Int])] {
        let block = Array(900..<919)
        return (0..<count).map { ("w", [block[$0 % block.count]]) }
    }

    /// Feeds until the guard fires; returns the detection and every token fed.
    private func run(
        _ deltas: [(String, [Int])], into loopGuard: inout GenerationLoopGuard
    ) -> (GenerationLoopDetector.Detection?, [Int]) {
        var fed: [Int] = []
        for (text, tokens) in deltas {
            fed += tokens
            if let detection = loopGuard.observe(text: text, tokens: tokens) { return (detection, fed) }
        }
        return (nil, fed)
    }

    @Test("a loop inside the thought asks to end the thought, and every token is kept")
    func loopInsideThought() {
        let exit = gemmaExit()
        var loopGuard = loopGuard(exit)
        let opening: [(String, [Int])] = [("<|channel>", [1000]), ("thought\n", [116, 10])]
        let (detection, fed) = run(opening + clause(8_000), into: &loopGuard)
        #expect(detection != nil)
        #expect(loopGuard.endsThought)
        #expect(exit.record.requested == detection)
        // The in-flight deltas after the stop are kept too: the answer resumes after them.
        var all = fed
        for (text, tokens) in clause(3) {
            all += tokens
            #expect(loopGuard.observe(text: text, tokens: tokens) == nil)
        }
        #expect(exit.record.generatedTokens == all)
    }

    @Test("a loop in the answer, after the thought closed, still ends the row as before")
    func loopInAnswer() {
        let exit = gemmaExit()
        var loopGuard = loopGuard(exit)
        let thought: [(String, [Int])] = [("<|channel>", [1000]), ("thought\nok", [116, 10, 111]), ("<channel|>", [1001])]
        let (detection, _) = run(thought + clause(8_000), into: &loopGuard)
        #expect(detection != nil)
        #expect(!loopGuard.endsThought)
        #expect(exit.record.requested == nil)
    }

    @Test("markers split across deltas are followed")
    func splitMarkers() {
        let exit = gemmaExit()
        var opened = loopGuard(exit)
        let (inside, _) = run([("<|chan", [60, 124]), ("nel>thought\n", [99, 10])] + clause(8_000), into: &opened)
        #expect(inside != nil)
        #expect(opened.endsThought)

        var closed = loopGuard(gemmaExit())
        let split: [(String, [Int])] = [("<|channel>", [1000]), ("thought\n<chan", [116, 10]), ("nel|>", [62])]
        let (outside, _) = run(split + clause(8_000), into: &closed)
        #expect(outside != nil)
        #expect(!closed.endsThought)
    }

    @Test("a prompt that opened the thought starts inside it")
    func startsInside() {
        let exit = gemmaExit(startsInside: true)
        var loopGuard = loopGuard(exit)
        let (detection, _) = run(clause(8_000), into: &loopGuard)
        #expect(detection != nil)
        #expect(loopGuard.endsThought)
        #expect(exit.record.requested != nil)
    }

    @Test("without the exit, the guard keeps ending the row")
    func withoutExit() {
        var loopGuard = loopGuard(nil)
        let (detection, _) = run([("<|channel>", [1000])] + clause(8_000), into: &loopGuard)
        #expect(detection != nil)
        #expect(!loopGuard.endsThought)
    }

    @Test("a tool call turns the guard off: no stop and no exit")
    func toolCallDisarms() {
        let exit = gemmaExit()
        var loopGuard = loopGuard(exit)
        let call: [(String, [Int])] = [("<|channel>", [1000]), ("<|tool_call>", [48])]
        let (detection, _) = run(call + clause(8_000), into: &loopGuard)
        #expect(detection == nil)
        #expect(exit.record.requested == nil)
    }

    // MARK: Policy

    private static let tokenizer = GemmaThoughtTestTokenizer()
    private static let prompt = GemmaThoughtTestTokenizer.tokens("<|turn>user\nhi<turn|>\n<|turn>model\n")

    private func resolve(
        _ modelType: String?, tokenizer: GemmaThoughtTestTokenizer = Self.tokenizer, prompt: [Int] = Self.prompt,
        logprobs: Bool = false,
        setting: GenerationLoopExitThinkingPolicy.Setting =
            .modelTypes(GenerationLoopExitThinkingPolicy.defaultModelTypes)
    ) -> GenerationLoopExitThinking? {
        GenerationLoopExitThinkingPolicy.resolve(
            modelType: modelType, tokenizer: tokenizer, promptTokens: prompt, logprobs: logprobs, setting: setting)
    }

    @Test("on by default for Gemma 4, with its close marker as the exit; not for families without a listed marker")
    func defaultModelTypes() throws {
        for modelType in ["gemma4", "gemma4_text", "GEMMA4"] {
            let exit = try #require(resolve(modelType), "\(modelType)")
            #expect(exit.exitTokens == [GemmaThoughtTestTokenizer.channelClose])
            #expect(exit.exitText == "<channel|>")
            #expect(!exit.startsInside)
        }
        // (`gpt_oss` has a marker since its Harmony exit: `GenerationLoopExitThinkingHarmonyTests`.)
        for modelType in ["qwen4_exp", "nemotron_h", "glm5_next", "mimo_v2", "diffusion_gemma", "llama"] {
            #expect(resolve(modelType) == nil, "\(modelType)")
        }
        #expect(resolve(nil) == nil)
    }

    @Test("DARKBLOOM_LOOP_EXIT_THINKING turns it off or names the model types")
    func environmentOverride() {
        let key = GenerationLoopExitThinkingPolicy.environmentKey
        let defaults = GenerationLoopExitThinkingPolicy.Setting.modelTypes(
            GenerationLoopExitThinkingPolicy.defaultModelTypes)
        #expect(GenerationLoopExitThinkingPolicy.setting(environment: [:]) == defaults)
        #expect(GenerationLoopExitThinkingPolicy.setting(environment: [key: "on"]) == defaults)
        #expect(GenerationLoopExitThinkingPolicy.setting(environment: [key: "0"]) == .off)
        #expect(GenerationLoopExitThinkingPolicy.setting(environment: [key: "off"]) == .off)
        let listed = GenerationLoopExitThinkingPolicy.setting(environment: [key: " gemma4_text , qwen3_5 "])
        #expect(listed == .modelTypes(["gemma4_text", "qwen3_5"]))
        #expect(resolve("gemma4", setting: .off) == nil)
        #expect(resolve("gemma4", setting: listed) == nil)
        #expect(resolve("gemma4_text", setting: listed) != nil)
        // A listed family without a known marker stays off.
        #expect(resolve("llama", setting: .modelTypes(["llama"])) == nil)
    }

    @Test("never with logprobs, and never without the marker token")
    func logprobsAndMissingMarker() {
        #expect(resolve("gemma4", logprobs: true) == nil)
        var without = Self.tokenizer
        without.markers.removeAll { $0.0 == "<channel|>" }
        #expect(resolve("gemma4", tokenizer: without) == nil)
    }

    @Test("the prompt's tail decides whether output starts inside the thought")
    func promptTail() {
        // The probe reads the last 8 prompt tokens; this tokenizer spells text byte by byte.
        let primed = GemmaThoughtTestTokenizer.tokens("<|turn>model\n<|channel>")
        let closed = GemmaThoughtTestTokenizer.tokens("<|turn>model\n<|channel><channel|>")
        #expect(resolve("gemma4", prompt: primed)?.startsInside == true)
        #expect(resolve("gemma4", prompt: closed)?.startsInside == false)
        #expect(resolve("gemma4", prompt: Self.prompt)?.startsInside == false)
    }

    // MARK: The `</think>` families

    private static let qwen = QwenByteTestTokenizer()
    private static let qwenThinking = QwenByteTestTokenizer.tokens(QwenByteTestTokenizer.prompt(thinking: true))

    /// The 35B families' exit alone, as a list set on the Mac turns it on.
    private static let qwenOn = GenerationLoopExitThinkingPolicy.Setting.modelTypes(["qwen3_5_moe"])

    private func qwenExit(_ modelType: String = "qwen3_5_moe",
                          setting: GenerationLoopExitThinkingPolicy.Setting = Self.qwenOn) -> GenerationLoopExitThinking? {
        GenerationLoopExitThinkingPolicy.resolve(
            modelType: modelType, tokenizer: Self.qwen, promptTokens: Self.qwenThinking, logprobs: false,
            setting: setting)
    }

    @Test("Qwen 3.5/3.6 end the thought as their template does: `\\n</think>\\n\\n`, the marker as its own token")
    func qwenFamilies() throws {
        for modelType in ["qwen3_5", "qwen3_5_moe"] {
            let exit = try #require(GenerationLoopExitThinkingPolicy.resolve(
                modelType: modelType, tokenizer: Self.qwen, promptTokens: Self.qwenThinking, logprobs: false,
                setting: .modelTypes([modelType])), "\(modelType)")
            #expect(exit.exitText == "\n</think>\n\n")
            #expect(exit.exitTokens == [10, 248069, 10, 10])
            #expect(exit.closeToken == 248069)
            // The served template opens the thought in the prompt.
            #expect(exit.startsInside)
        }
        // Both families are on by default. By default the scheduler keeps the
        // exit to the builds the A/B proved (the 9B, the 35B), not Qwen 3.6
        // (`qwen3_5_moe`) or Qwen 3.8 27B (`qwen3_5`). A list set on the Mac
        // names the families it turns on.
        let defaults = GenerationLoopExitThinkingPolicy.setting(environment: [:])
        #expect(qwenExit("qwen3_5_moe", setting: defaults) != nil)
        #expect(qwenExit("qwen3_5", setting: defaults) != nil)
        #expect(qwenExit("qwen3_5_moe") != nil)
        #expect(qwenExit("qwen3_5") == nil)
        // A prompt whose earlier turns closed their thoughts still opens this one.
        let history = QwenByteTestTokenizer.tokens("<|im_start|>user\nhi<|im_end|>\n<|im_start|>assistant\n"
            + "<think>\nok\n</think>\n\nhello<|im_end|>\n<|im_start|>user\nmore<|im_end|>\n"
            + "<|im_start|>assistant\n<think>\n")
        #expect(GenerationLoopExitThinkingPolicy.resolve(
            modelType: "qwen3_5_moe", tokenizer: Self.qwen, promptTokens: history, logprobs: false,
            setting: Self.qwenOn)?.startsInside == true)
        let closed = QwenByteTestTokenizer.tokens(QwenByteTestTokenizer.prompt(thinking: false))
        #expect(GenerationLoopExitThinkingPolicy.resolve(
            modelType: "qwen3_5_moe", tokenizer: Self.qwen, promptTokens: closed, logprobs: false,
            setting: Self.qwenOn)?.startsInside == false)
        // Qwen 3.8 (`qwen4_exp`) is not listed: its thought loops are rare in production.
        #expect(qwenExit("qwen4_exp") == nil)
        // The env list still turns Qwen's off and keeps Gemma's.
        let gemmaOnly = GenerationLoopExitThinkingPolicy.setting(
            environment: [GenerationLoopExitThinkingPolicy.environmentKey: "gemma4,gemma4_text"])
        #expect(GenerationLoopExitThinkingPolicy.resolve(
            modelType: "qwen3_5_moe", tokenizer: Self.qwen, promptTokens: Self.qwenThinking, logprobs: false,
            setting: gemmaOnly) == nil)
        #expect(resolve("gemma4", setting: gemmaOnly) != nil)
    }

    @Test("by default Qwen's exit takes only the builds the A/B proved; a list set on the Mac takes every build")
    func qwenDefaultBuilds() {
        typealias Policy = GenerationLoopExitThinkingPolicy
        let defaults = Policy.setting(environment: [:])
        #expect(Policy.setting(environment: [Policy.environmentKey: "on"]) == defaults)
        #expect(!Policy.keepsLengthByDefault(modelType: "qwen3_5", modelID: "Qwen3.5-9B", setting: defaults))
        #expect(!Policy.keepsLengthByDefault(modelType: "qwen3_5_moe", modelID: "qwen3.5-35b-a3b", setting: defaults))
        // The same families' other builds: Qwen 3.6, Qwen 3.8 27B, another 9B build.
        #expect(Policy.keepsLengthByDefault(
            modelType: "qwen3_5_moe", modelID: "qwen3.6-35b-a3b-vl-mtp-mxfp8", setting: defaults))
        for id in ModelRuntimeRequirements.qwen38ConcreteModelIDs {
            #expect(Policy.keepsLengthByDefault(modelType: "qwen3_5", modelID: id, setting: defaults), "\(id)")
        }
        #expect(Policy.keepsLengthByDefault(
            modelType: "qwen3_5", modelID: "EigenLabs/Qwen3.5-9B-MLX-4bit-mtp", setting: defaults))
        // A build counts only with its own `model_type`.
        #expect(Policy.keepsLengthByDefault(modelType: "qwen3_5_moe", modelID: "Qwen3.5-9B", setting: defaults))
        // Gemma's and GPT-OSS's exits take every build.
        #expect(!Policy.keepsLengthByDefault(
            modelType: "gemma4", modelID: "mlx-community/gemma-4-26B-A4B-it-qat-4bit", setting: defaults))
        #expect(!Policy.keepsLengthByDefault(modelType: "gpt_oss", modelID: "gpt-oss-20b", setting: defaults))
        // A list set on the Mac turns its families on for every build.
        let listed = Policy.setting(environment: [Policy.environmentKey: "qwen3_5,qwen3_5_moe"])
        #expect(!Policy.keepsLengthByDefault(
            modelType: "qwen3_5", modelID: "EigenLabs/Qwen3.8-27B-4bit-mtp", setting: listed))
        #expect(!Policy.keepsLengthByDefault(
            modelType: "qwen3_5_moe", modelID: "qwen3.6-35b-a3b-vl-mtp-mxfp8", setting: listed))
    }

    @Test("a Qwen thought that loops asks to end the thought; a loop after `</think>` does not")
    func qwenGuard() throws {
        var inThought = GenerationLoopGuard(
            modelType: "qwen3_5_moe", toolCallMarkers: GenerationLoopGuardPolicy.genericToolCallMarkers,
            exitThinking: try #require(qwenExit()))
        let (thoughtStop, _) = run(clause(8_000), into: &inThought)
        #expect(thoughtStop != nil)
        #expect(inThought.endsThought)

        var inAnswer = GenerationLoopGuard(
            modelType: "qwen3_5_moe", toolCallMarkers: GenerationLoopGuardPolicy.genericToolCallMarkers,
            exitThinking: try #require(qwenExit()))
        let closing: [(String, [Int])] = [("ok\n", [111, 107, 10]), ("</think>", [248069]), ("\n\n", [10, 10])]
        let (answerStop, _) = run(closing + clause(8_000), into: &inAnswer)
        #expect(answerStop != nil)
        #expect(!inAnswer.endsThought)
    }

    @Test("a Qwen thought the model opens itself, after a thinking-off prompt, can be ended; a split `</think>` closes it")
    func qwenChannelEdges() throws {
        let closedPrompt = QwenByteTestTokenizer.tokens(QwenByteTestTokenizer.prompt(thinking: false))
        let exit = try #require(GenerationLoopExitThinkingPolicy.resolve(
            modelType: "qwen3_5_moe", tokenizer: Self.qwen, promptTokens: closedPrompt, logprobs: false,
            setting: Self.qwenOn))
        #expect(!exit.startsInside)
        var reopened = GenerationLoopGuard(
            modelType: "qwen3_5_moe", toolCallMarkers: GenerationLoopGuardPolicy.genericToolCallMarkers, exitThinking: exit)
        let (inside, _) = run([("<think>", [248068]), ("\n", [10])] + clause(8_000), into: &reopened)
        #expect(inside != nil)
        #expect(reopened.endsThought)

        var split = GenerationLoopGuard(
            modelType: "qwen3_5_moe", toolCallMarkers: GenerationLoopGuardPolicy.genericToolCallMarkers,
            exitThinking: try #require(qwenExit()))
        let pieces: [(String, [Int])] = [("ok\n</thi", [111, 107, 10, 60, 47, 116, 104, 105]), ("nk>\n\n", [110, 107, 62, 10, 10])]
        let (outside, _) = run(pieces + clause(8_000), into: &split)
        #expect(outside != nil)
        #expect(!split.endsThought)
    }

    @Test("a `</think>` whose text has not arrived yet keeps the stop a length: in the stopping delta or after it")
    func qwenCloseTheTextHasNotShown() throws {
        // The stopping delta carries the close token, but the detokenizer has
        // not released its text yet: the row is not stopped inside its thought.
        let held = try #require(qwenExit())
        var stopping = GenerationLoopGuard(
            modelType: "qwen3_5_moe", toolCallMarkers: GenerationLoopGuardPolicy.genericToolCallMarkers, exitThinking: held)
        var fired: GenerationLoopDetector.Detection?
        for (index, (text, tokens)) in clause(8_000).enumerated() {
            // Every delta from the 4,096th on could be the one that fires.
            let closing = index >= 4_095 ? tokens + [248069] : tokens
            if let detection = stopping.observe(text: text, tokens: closing) { fired = detection; break }
        }
        #expect(fired != nil)
        #expect(!stopping.endsThought)
        #expect(held.record.requested == nil)

        // After the stop: `</think>` spelled as ordinary pieces (no close
        // token) still closes the thought, in the text the guard follows.
        let after = try #require(qwenExit())
        var spelled = GenerationLoopGuard(
            modelType: "qwen3_5_moe", toolCallMarkers: GenerationLoopGuardPolicy.genericToolCallMarkers, exitThinking: after)
        let (stop, _) = run(clause(8_000), into: &spelled)
        #expect(stop != nil)
        #expect(spelled.endsThought)
        #expect(!after.record.closedAfterStop)
        #expect(spelled.observe(text: "\n</", tokens: [10, 1_000]) == nil)
        #expect(spelled.observe(text: "think>\n\nB", tokens: [1_001, 1_002, 66]) == nil)
        #expect(after.record.closedAfterStop)
    }

    @Test("the exit's tokens must spell its text: a tokenizer that adds a prefix gets no exit")
    func exitTokensSpellTheText() {
        struct Prefixing: MLXLMCommon.Tokenizer {
            let inner = QwenByteTestTokenizer()
            func encode(text: String, addSpecialTokens: Bool) -> [Int] {
                [248044] + inner.encode(text: text, addSpecialTokens: addSpecialTokens)
            }
            func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
                inner.decode(tokenIds: tokenIds, skipSpecialTokens: skipSpecialTokens)
            }
            func convertTokenToId(_ token: String) -> Int? { inner.convertTokenToId(token) }
            func convertIdToToken(_ id: Int) -> String? { inner.convertIdToToken(id) }
            var bosToken: String? { nil }
            var eosToken: String? { inner.eosToken }
            var unknownToken: String? { nil }
            func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                additionalContext: [String: any Sendable]?) throws -> [Int] {
                try inner.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
            }
        }
        #expect(GenerationLoopExitThinkingPolicy.resolve(
            modelType: "qwen3_5_moe", tokenizer: Prefixing(), promptTokens: Self.qwenThinking, logprobs: false,
            setting: Self.qwenOn) == nil)
    }

    @Test("darkbloom start passes the loop guard's and the exit's switches to the launchd daemon")
    func launchdPassthrough() {
        for key in [GenerationLoopExitThinkingPolicy.environmentKey, GenerationLoopGuardPolicy.environmentKey] {
            #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key), "\(key)")
            #expect(LaunchAgent.passthroughEnvironment(from: [key: "0"])[key] == "0", "\(key)")
        }
    }

    @Test("the guard's policy carries the exit to the guard")
    func guardPolicyCarriesTheExit() throws {
        let request = OpenAIChatCompletionRequest(
            model: "m", messages: [.init(role: .user, content: .text("hi"))], maxTokens: 131_072)
        let exit = gemmaExit()
        let loopGuard = try #require(GenerationLoopGuardPolicy.resolve(
            modelType: "gemma4", request: request,
            prepared: try ToolChoicePromptPolicy.prepare(request, modelType: "gemma4"),
            tokenConstraint: nil, setting: .modelTypes(["gemma4"]), exitThinking: exit))
        #expect(loopGuard.exitThinking?.record === exit.record)
    }
}
