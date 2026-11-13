// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// ASCII bytes plus GPT-OSS's Harmony control tokens and the header words the
/// o200k_harmony vocabulary holds as one token, with their real ids
/// (`<|end|><|start|>assistant` is [200007, 200006, 173781]).
struct HarmonyTestTokenizer: MLXLMCommon.Tokenizer {
    static let start = 200_006
    static let end = 200_007
    static let message = 200_008
    static let channel = 200_005
    static let assistant = 173_781
    static let final = 17_196
    static let stops: Set<Int> = [200_002, 199_999, 200_012]
    static let vocabulary: [(String, Int)] = [
        ("<|start|>", 200_006), ("<|end|>", 200_007), ("<|message|>", 200_008), ("<|channel|>", 200_005),
        ("<|return|>", 200_002), ("<|call|>", 200_012), ("<|constrain|>", 200_003), ("<|endoftext|>", 199_999),
        ("assistant", 173_781), ("analysis", 35_644), ("final", 17_196),
    ]

    var markers = Self.vocabulary
    /// `convertTokenToId` answers for these spellings only (all by default).
    var resolvable: Set<String>?
    /// Spells every text as bytes, control spellings included.
    var spellsControlsAsBytes = false

    static func tokens(_ text: String, markers: [(String, Int)] = vocabulary) -> [Int] {
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

    /// The served template's shape: the effort in the system message, the
    /// tools' names in a developer message, the prompt ending at a new
    /// assistant message.
    static func prompt(effort: String = "medium", tools: [String] = []) -> String {
        "<|start|>system<|message|>Reasoning: \(effort)\n\n# Valid channels: analysis, commentary, final.<|end|>"
            + (tools.isEmpty ? "" : "<|start|>developer<|message|># Tools\n\(tools.joined(separator: ","))<|end|>")
            + "<|start|>user<|message|>hi<|end|><|start|>assistant"
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        spellsControlsAsBytes ? Array(text.utf8).map(Int.init) : Self.tokens(text, markers: markers)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.compactMap(convertIdToToken).joined()
    }
    func convertTokenToId(_ token: String) -> Int? {
        if let resolvable, !resolvable.contains(token) { return nil }
        return markers.first { $0.0 == token }?.1
    }
    func convertIdToToken(_ id: Int) -> String? {
        if let marker = markers.first(where: { $0.1 == id }) { return marker.0 }
        guard (0..<128).contains(id), let scalar = UnicodeScalar(id) else { return nil }
        return String(Character(scalar))
    }
    var bosToken: String? { nil }
    var eosToken: String? { "<|return|>" }
    var unknownToken: String? { nil }
    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        let names = (tools ?? []).compactMap { ($0["function"] as? [String: any Sendable])?["name"] as? String }
        let effort = additionalContext?["reasoning_effort"] as? String ?? "medium"
        return Self.tokens(Self.prompt(effort: effort, tools: names), markers: markers)
    }
}

/// A GPT-OSS row, one token per delta as the real tokenizer splits Harmony
/// headers: `<|channel|>`, `analysis`, `<|message|>`. A looping row repeats one
/// clause; the guard's cancel ends it `.cancelled` (unless cancelled, it ends
/// `.length` after a short wait). Any later submission is the continuation.
final class HarmonyLoopTestEngine: CBv2Engine, @unchecked Sendable {
    enum Row: Sendable {
        /// The analysis repeats itself.
        case analysisLoop
        /// The analysis ends, then the final answer repeats itself.
        case finalLoop
        /// The analysis ends and the final answer follows: the guard never fires.
        case answers
    }

    enum Next: Sendable {
        /// `<|channel|>final<|message|>Answer: B`, then `<|return|>`.
        case final
        /// `<|channel|>commentary to=functions.get_weather <|constrain|>json<|message|>{…}`, then `<|call|>`.
        case callInChannel
        /// ` to=functions.get_weather<|channel|>commentary json<|message|>{…}`, then `<|call|>`.
        case callInRole
        /// Another analysis message, which repeats itself too.
        case reopensAnalysis
        /// The answer's text alone, then `<|return|>`: the exit opened the final channel.
        case answer
        /// The answer's text alone, repeating itself.
        case answerLoop
        /// `<|return|>` at once: the model ends the answer without text.
        case noAnswer
    }

    static let clause = Array("We need to check the reservation first. ")
    static let arguments = #"{"city":"Paris"}"#

    private let lock = NSLock()
    private var continuations: [AsyncStream<CBv2Event>.Continuation] = []
    private var submitted: [CBv2Request] = []
    private var produced: [[Int]] = []
    private var cancels = 0
    let row: Row
    let next: Next
    let markers: [(String, Int)]

    init(_ row: Row, then next: Next = .final, markers: [(String, Int)] = HarmonyTestTokenizer.vocabulary) {
        self.row = row
        self.next = next
        self.markers = markers
    }

    var requests: [CBv2Request] { lock.withLock { submitted } }
    var outputs: [[Int]] { lock.withLock { produced } }
    var cancelCount: Int { lock.withLock { cancels } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        let index = lock.withLock {
            submitted.append(request)
            continuations.append(continuation)
            produced.append([])
            return submitted.count - 1
        }
        func emit(_ text: String, extra: [Int] = []) {
            let tokens = HarmonyTestTokenizer.tokens(text, markers: markers) + extra
            lock.withLock { produced[index] += tokens }
            continuation.yield(.delta(text: text, tokens: tokens, logprobs: nil))
        }
        func header(_ channel: String) { ["<|channel|>", channel, "<|message|>"].forEach { emit($0) } }
        func nextMessage() { ["<|end|>", "<|start|>", "assistant"].forEach { emit($0) } }
        func loop() {
            for position in 0..<4_200 { emit(String(Self.clause[position % Self.clause.count])) }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.finish(index, .length)
            }
        }
        // The engine suppresses a stop token's text: its delta carries the token only.
        func stop(_ token: Int) {
            lock.withLock { produced[index].append(token) }
            continuation.yield(.delta(text: "", tokens: [token], logprobs: nil))
            finish(index, .stop)
        }
        if index == 0 {
            header("analysis")
            switch row {
            case .analysisLoop:
                loop()
            case .finalLoop:
                emit("ok")
                nextMessage()
                header("final")
                loop()
            case .answers:
                emit("ok")
                nextMessage()
                header("final")
                for character in "Answer: B" { emit(String(character)) }
                stop(200_002)
            }
        } else {
            switch next {
            case .final:
                header("final")
                for character in "Answer: B" { emit(String(character)) }
                stop(200_002)
            case .callInChannel:
                ["<|channel|>", "comment", "ary", " to", "=", "functions", ".get", "_weather", " ", "<|constrain|>",
                 "json", "<|message|>"].forEach { emit($0) }
                for character in Self.arguments { emit(String(character)) }
                stop(200_012)
            case .callInRole:
                [" to", "=", "functions", ".get", "_weather", "<|channel|>", "comment", "ary", " json",
                 "<|message|>"].forEach { emit($0) }
                for character in Self.arguments { emit(String(character)) }
                stop(200_012)
            case .reopensAnalysis:
                header("analysis")
                loop()
            case .answer:
                for character in "Answer: B" { emit(String(character)) }
                stop(200_002)
            case .answerLoop:
                loop()
            case .noAnswer:
                stop(200_002)
            }
        }
        return stream
    }

    private func finish(_ index: Int, _ reason: CBv2FinishReason) {
        let (continuation, prompt, completion) = lock.withLock {
            defer { continuations[index] = AsyncStream<CBv2Event>.makeStream().continuation }
            return (continuations[index], submitted[index].promptTokens.count, produced[index].count)
        }
        continuation.yield(.finished(
            reason: reason, usage: CBv2Usage(promptTokens: prompt, completionTokens: completion)))
        continuation.finish()
    }

    func cancel(_ id: CBv2RequestID) {
        let index = lock.withLock {
            cancels += 1
            return submitted.lastIndex { $0.id == id }
        }
        if let index { finish(index, .cancelled) }
    }

    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }

    func shutdown() async {}
}

@Suite("Loop guard: a repeating GPT-OSS analysis ends in an answer or a tool call (Harmony)")
struct GenerationLoopExitThinkingHarmonyTests {
    private static let tokenizer = HarmonyTestTokenizer()
    private static let prompt = HarmonyTestTokenizer.tokens(HarmonyTestTokenizer.prompt())
    private static let exitTokens = [HarmonyTestTokenizer.end, HarmonyTestTokenizer.start, HarmonyTestTokenizer.assistant]
    /// Without tools: the same, then the final channel's header.
    private static let finalExitTokens = exitTokens
        + [HarmonyTestTokenizer.channel, HarmonyTestTokenizer.final, HarmonyTestTokenizer.message]
    private static let defaults = GenerationLoopExitThinkingPolicy.Setting.modelTypes(
        GenerationLoopExitThinkingPolicy.defaultModelTypes)

    private func resolve(
        _ modelType: String? = "gpt_oss", tokenizer: HarmonyTestTokenizer = Self.tokenizer,
        prompt: [Int] = Self.prompt, logprobs: Bool = false, declaresTools: Bool = true,
        setting: GenerationLoopExitThinkingPolicy.Setting = Self.defaults, finalExit: Bool = true
    ) -> GenerationLoopExitThinking? {
        GenerationLoopExitThinkingPolicy.resolve(
            modelType: modelType, tokenizer: tokenizer, promptTokens: prompt, logprobs: logprobs,
            declaresTools: declaresTools, setting: setting, finalExit: finalExit)
    }

    @Test("without tools, the exit also opens the final channel: the model answers instead of reopening its analysis")
    func withoutToolsOpensFinal() throws {
        let withTools = try #require(resolve(declaresTools: true))
        #expect(withTools.exitText == "<|end|><|start|>assistant")
        #expect(withTools.answerStopScope == nil)
        // On the GPU A/B (11-13, effort high, T 0), after `<|end|><|start|>assistant` the model reopened its
        // analysis and looped again in 10 of 10 GPQA loopers without tools; without tools there is no call to pick.
        let exit = try #require(resolve(declaresTools: false))
        #expect(exit.exitTokens == Self.finalExitTokens)
        #expect(exit.exitText == "<|end|><|start|>assistant<|channel|>final<|message|>")
        #expect(exit.closeToken == HarmonyTestTokenizer.end)
        #expect(exit.openMarker == "<|channel|>analysis")
        #expect(exit.closeMarker == "<|end|>")
        #expect(!exit.startsInside)
        // Its output starts inside the final channel, so the request's stops apply from its first token.
        #expect(exit.answerStopScope == GPTOSSHarmonyTemplateFix.insideFinalChannelStopScope)
        // The other families do not depend on tools.
        let gemma = try #require(GenerationLoopExitThinkingPolicy.resolve(
            modelType: "gemma4", tokenizer: GemmaThoughtTestTokenizer(),
            promptTokens: GemmaThoughtTestTokenizer.tokens("<|turn>user\nhi<turn|>\n<|turn>model\n"), logprobs: false,
            declaresTools: false, setting: Self.defaults))
        #expect(gemma.exitText == "<channel|>")
        #expect(gemma.answerStopScope == nil)
    }

    @Test("`DARKBLOOM_GPTOSS_FINAL_EXIT` off keeps 0.10.13's exit for tool requests only; it reaches the launchd daemon")
    func finalExitSwitch() throws {
        let key = GenerationLoopExitThinkingPolicy.finalExitEnvironmentKey
        #expect(key == "DARKBLOOM_GPTOSS_FINAL_EXIT")
        for value in ["0", "off", "false", " OFF "] {
            #expect(!GenerationLoopExitThinkingPolicy.finalExit(environment: [key: value]), "\(value)")
        }
        for value in ["", "1", "on", "true"] {
            #expect(GenerationLoopExitThinkingPolicy.finalExit(environment: [key: value]), "\(value)")
        }
        #expect(GenerationLoopExitThinkingPolicy.finalExit(environment: [:]))
        #expect(resolve(declaresTools: false, finalExit: false) == nil)
        #expect(resolve(declaresTools: true, finalExit: false)?.exitText == "<|end|><|start|>assistant")
        // A family list without `gpt_oss` turns both off.
        let list = GenerationLoopExitThinkingPolicy.setting(
            environment: [GenerationLoopExitThinkingPolicy.environmentKey: "gemma4,gemma4_text"])
        #expect(resolve(declaresTools: false, setting: list) == nil)
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "0"])[key] == "0")
    }

    @Test("the final exit's stop scope: the request's stops apply from the continuation's first token to the message's end")
    func insideFinalStopScope() {
        let scope = GPTOSSHarmonyTemplateFix.insideFinalChannelStopScope
        let answer = StopHoldback(stopStrings: ["B"], scope: scope).ingest("Answer: B")
        #expect(answer.stopped)
        #expect(answer.text == "Answer: ")
        // Text after the message ends is not the answer.
        let later = StopHoldback(stopStrings: ["B"], scope: scope)
            .ingest("Answer<|end|><|start|>assistant<|channel|>analysis<|message|>B")
        #expect(!later.stopped)
        // The model's own scope waits for a header that the exit already fed: it would never match.
        let model = StopHoldback(stopStrings: ["B"], scope: GPTOSSHarmonyTemplateFix.finalChannelStopScope)
        #expect(!model.ingest("Answer: B").stopped)
        // As in other scopes that start in the answer, a stop that matches only leading whitespace waits for text.
        let leading = StopHoldback(stopStrings: ["\n"], scope: scope).ingest("\nAnswer: B\nmore")
        #expect(leading.stopped)
        #expect(leading.text == "\nAnswer: B")
    }

    // MARK: Policy

    @Test("on by default for GPT-OSS: the exit ends the analysis message and starts the next assistant message")
    func harmonyExit() throws {
        for modelType in ["gpt_oss", "GPT_OSS"] {
            let exit = try #require(resolve(modelType), "\(modelType)")
            #expect(exit.exitTokens == Self.exitTokens)
            #expect(exit.exitText == "<|end|><|start|>assistant")
            #expect(exit.closeToken == HarmonyTestTokenizer.end)
            #expect(exit.openMarker == "<|channel|>analysis")
            #expect(exit.closeMarker == "<|end|>")
            // The prompt ends at `<|start|>assistant`: the model opens its analysis itself.
            #expect(!exit.startsInside)
        }
        #expect(GenerationLoopExitThinkingPolicy.defaultModelTypes.contains("gpt_oss"))
    }

    @Test("the prompt's tail: a history with an earlier analysis and a tool result still starts outside")
    func promptTail() throws {
        let history = HarmonyTestTokenizer.tokens("<|start|>user<|message|>hi<|end|>"
            + "<|start|>assistant<|channel|>analysis<|message|>Look it up.<|end|>"
            + "<|start|>assistant to=functions.get_weather<|channel|>commentary json<|message|>{}<|call|>"
            + "<|start|>functions.get_weather to=assistant<|channel|>commentary<|message|>\"sun\"<|end|>"
            + "<|start|>assistant")
        #expect(try #require(resolve(prompt: history)).startsInside == false)
        // A prompt that leaves an analysis message open starts inside it.
        let open = HarmonyTestTokenizer.tokens(HarmonyTestTokenizer.prompt() + "<|channel|>analysis<|message|>")
        #expect(try #require(resolve(prompt: open)).startsInside)
    }

    @Test("the switch: off, or a list without gpt_oss, keeps the length stop; never with logprobs")
    func switchAndLogprobs() throws {
        let key = GenerationLoopExitThinkingPolicy.environmentKey
        for value in ["0", "off", "false", "gemma4,gemma4_text,qwen3_5_moe"] {
            let setting = GenerationLoopExitThinkingPolicy.setting(environment: [key: value])
            #expect(resolve(setting: setting) == nil, "\(value)")
        }
        let alone = GenerationLoopExitThinkingPolicy.setting(environment: [key: "gpt_oss"])
        #expect(resolve(setting: alone) != nil)
        #expect(resolve(logprobs: true) == nil)
        // The list reaches the launchd daemon as written.
        let listed = LaunchAgent.passthroughEnvironment(from: [key: "gemma4,gemma4_text,qwen3_5_moe"])
        #expect(listed[key] == "gemma4,gemma4_text,qwen3_5_moe")
    }

    @Test("the control tokens must be fed as themselves: a tokenizer that spells them as text gets no exit")
    func controlTokensResolve() {
        // The served spelling resolves; each case below differs from it in one respect.
        #expect(resolve(tokenizer: Self.tokenizer) != nil)
        // Encodes `<|start|>assistant` as bytes, which decode to the same text.
        var spelled = Self.tokenizer
        spelled.spellsControlsAsBytes = true
        #expect(resolve(tokenizer: spelled) == nil)
        // `<|start|>` that does not resolve to its own token.
        var noStart = Self.tokenizer
        noStart.resolvable = Set(HarmonyTestTokenizer.vocabulary.map(\.0)).subtracting(["<|start|>"])
        #expect(resolve(tokenizer: noStart) == nil)
        // No `<|end|>`, no exit.
        var noEnd = Self.tokenizer
        noEnd.resolvable = Set(HarmonyTestTokenizer.vocabulary.map(\.0)).subtracting(["<|end|>"])
        #expect(resolve(tokenizer: noEnd) == nil)
        // The final exit also feeds `<|channel|>` and `<|message|>`, each as itself.
        for control in ["<|channel|>", "<|message|>"] {
            var missing = Self.tokenizer
            missing.resolvable = Set(HarmonyTestTokenizer.vocabulary.map(\.0)).subtracting([control])
            #expect(resolve(tokenizer: missing, declaresTools: false) == nil, "\(control)")
            #expect(resolve(tokenizer: missing, declaresTools: true) != nil, "\(control)")
        }
        var spelledFinal = Self.tokenizer
        spelledFinal.spellsControlsAsBytes = true
        #expect(resolve(tokenizer: spelledFinal, declaresTools: false) == nil)
    }

    // MARK: The guard

    private func loopGuard(_ exit: GenerationLoopExitThinking?, markers: [String] = []) -> GenerationLoopGuard {
        GenerationLoopGuard(
            modelType: "gpt_oss", toolCallMarkers: GenerationLoopGuardPolicy.genericToolCallMarkers + markers,
            exitThinking: exit)
    }

    private func pieces(_ texts: [String]) -> [(String, [Int])] {
        texts.map { ($0, HarmonyTestTokenizer.tokens($0)) }
    }

    private func clause(_ count: Int) -> [(String, [Int])] {
        let block = Array(900..<917)
        return (0..<count).map { ("w", [block[$0 % block.count]]) }
    }

    private func run(
        _ deltas: [(String, [Int])], into loopGuard: inout GenerationLoopGuard
    ) -> GenerationLoopDetector.Detection? {
        for (text, tokens) in deltas {
            if let detection = loopGuard.observe(text: text, tokens: tokens) { return detection }
        }
        return nil
    }

    private static let analysis = ["<|channel|>", "analysis", "<|message|>"]
    private static let next = ["<|end|>", "<|start|>", "assistant"]

    @Test("a loop inside the analysis message asks to end it; the header is followed across its three deltas")
    func loopInsideAnalysis() throws {
        let exit = try #require(resolve())
        var loopGuard = loopGuard(exit)
        let detection = run(pieces(Self.analysis) + clause(8_000), into: &loopGuard)
        #expect(detection != nil)
        #expect(loopGuard.endsThought)
        #expect(exit.record.requested == detection)
    }

    @Test("a loop after the analysis (final, a commentary preamble) still ends as length")
    func loopAfterAnalysis() throws {
        for channel in ["final", "commentary"] {
            let exit = try #require(resolve())
            var loopGuard = loopGuard(exit)
            let opening = pieces(Self.analysis + ["ok"] + Self.next + ["<|channel|>", channel, "<|message|>"])
            #expect(run(opening + clause(8_000), into: &loopGuard) != nil, "\(channel)")
            #expect(!loopGuard.endsThought, "\(channel)")
            #expect(exit.record.requested == nil, "\(channel)")
        }
    }

    @Test("a second analysis message that loops asks to end it")
    func secondAnalysisMessage() throws {
        let exit = try #require(resolve())
        var loopGuard = loopGuard(exit)
        let opening = pieces(Self.analysis + ["ok"] + Self.next + Self.analysis)
        #expect(run(opening + clause(8_000), into: &loopGuard) != nil)
        #expect(loopGuard.endsThought)
    }

    @Test("`<|start|>assistant` without `<|end|>` keeps the analysis open, as both Harmony parsers read it")
    func roleMarkerInsideAnalysis() throws {
        let exit = try #require(resolve())
        var loopGuard = loopGuard(exit)
        let skipped = Self.analysis + ["ok"] + ["<|start|>", "assistant", "<|channel|>", "final", "<|message|>"]
        #expect(run(pieces(skipped) + clause(8_000), into: &loopGuard) != nil)
        #expect(loopGuard.endsThought)
        // The client is shown the same: without `<|end|>` the text after the
        // role marker is still the analysis, streamed and collected, so the
        // exit's `<|end|>` is what lets an answer through.
        var streaming = StreamingReasoningParser(format: .harmony)
        let streamed = (skipped + ["Answer"]).flatMap { streaming.parse($0) } + streaming.finish()
        let streamedContent = streamed.map(\.content).joined()
        #expect(streamedContent.isEmpty)
        let collected = ReasoningParser(format: .harmony).parse(skipped.joined() + "Answer")
        #expect(collected.content.isEmpty)
        #expect(collected.reasoningContent?.hasSuffix("Answer") == true)
    }

    @Test("a call header turns the guard off: no stop, no exit")
    func callDisarms() throws {
        let exit = try #require(resolve())
        var loopGuard = loopGuard(exit, markers: ["<|start|>assistant<|channel|>commentary to=functions."])
        let call = pieces(Self.analysis + ["ok"] + Self.next + ["<|channel|>", "commentary to", "=functions.get"])
        #expect(run(call + clause(8_000), into: &loopGuard) == nil)
        #expect(exit.record.requested == nil)
    }

    @Test("an `<|end|>` in the stopping delta, or in flight after the stop, keeps the stop a length")
    func analysisClosedByTheRow() throws {
        let exit = try #require(resolve())
        var stopping = loopGuard(exit)
        _ = run(pieces(Self.analysis), into: &stopping)
        var fired: GenerationLoopDetector.Detection?
        // From well before the first check on, every delta also carries a
        // close token whose text has not arrived: whichever delta fires holds one.
        for (index, (text, tokens)) in clause(8_000).enumerated() {
            let closing = index >= 3_000 ? tokens + [HarmonyTestTokenizer.end] : tokens
            if let detection = stopping.observe(text: text, tokens: closing) { fired = detection; break }
        }
        #expect(fired != nil)
        #expect(!stopping.endsThought)
        #expect(exit.record.requested == nil)

        let after = try #require(resolve())
        var closed = loopGuard(after)
        #expect(run(pieces(Self.analysis) + clause(8_000), into: &closed) != nil)
        #expect(closed.endsThought)
        #expect(!after.record.closedAfterStop)
        #expect(closed.observe(text: "<|end|>", tokens: [HarmonyTestTokenizer.end]) == nil)
        #expect(after.record.closedAfterStop)
    }

    // MARK: Serving (scheduler text path, the real bridge, a scripted engine)

    private struct Outcome {
        /// The scheduler's raw text events, in order.
        var chunks: [String] = []
        /// Through the streaming Harmony parser, as the SSE frames split it.
        var content = ""
        var reasoning = ""
        /// Through the collected (non-stream) Harmony parser.
        var collected = ParsedReasoning(content: "", reasoningContent: nil)
        var calls: [ToolCall] = []
        var callDeltas: [ServerToolCallDelta] = []
        var events: [MLXServerGenerationEvent] = []
        var info: ServerGenerationInfo?
        var error: (any Error)?
        var loopGuardStops: [Bool?] = []
    }

    private final class TelemetrySink: @unchecked Sendable {
        private let lock = NSLock()
        private var received: [TelemetryEvent] = []
        func add(_ event: TelemetryEvent) { lock.withLock { received.append(event) } }
        var loopGuardStops: [Bool?] {
            lock.withLock {
                received.filter { $0.fields?["operation"]?.description == "engine_v2_loop_guard" }
                    .map { $0.fields?["ends_thought"]?.value as? Bool }
            }
        }
    }

    private static let tools = #","tools":[{"type":"function","function":{"name":"get_weather","#
        + #""description":"Weather in a city","parameters":{"type":"object","#
        + #""properties":{"city":{"type":"string"}},"required":["city"]}}}]"#

    private func serve(
        _ engine: HarmonyLoopTestEngine, tokenizer: HarmonyTestTokenizer = Self.tokenizer, effort: String? = nil,
        maxTokens: Int = 8_192, extra: String = Self.tools, streamCalls: Bool = false,
        exitSetting: GenerationLoopExitThinkingPolicy.Setting = Self.defaults, finalExit: Bool = true,
        usage: EngineV2RequestUsageSignal? = nil
    ) async throws -> Outcome {
        let telemetry = TelemetrySink()
        let handle = TokenizerHandle(tokenizer)
        // The model's own stop scope, as `ModelEOSPolicy` gives a GPT-OSS slot.
        let bridge = EngineV2Bridge(engine: engine, modelId: "gpt-oss-20b", tokenizer: handle,
            eosTokenIds: HarmonyTestTokenizer.stops, stopStringScope: GPTOSSHarmonyTemplateFix.finalChannelStopScope,
            defaultMaxTokens: 64,
            maxConcurrentRequests: 1, emitTelemetry: { telemetry.add($0) })
        var scheduler = MultiModelBatchSchedulerEngine(registryProvider: {
            ["gpt-oss-20b": .init(tokenizer: handle, modelType: "gpt_oss", engineV2Bridge: bridge)]
        }, templateControls: ChatTemplateControls(reasoningEffort: effort), engineV2Usage: usage)
        // The switches as a clean process reads them, whatever this process's environment says.
        scheduler.exitThinkingSetting = exitSetting
        scheduler.gptossFinalExit = finalExit
        var request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data("""
        {"model":"gpt-oss-20b","messages":[{"role":"user","content":"hi"}],\
        "reasoning_parser":"harmony","temperature":0,"max_tokens":\(maxTokens)\(extra)}
        """.utf8))
        request.streamToolCallDeltas = streamCalls
        var outcome = Outcome()
        var parser = StreamingReasoningParser(format: .harmony)
        func apply(_ parsed: ParsedReasoning) {
            outcome.content += parsed.content
            outcome.reasoning += parsed.reasoningContent ?? ""
        }
        do {
            for try await event in try await scheduler.streamChatCompletion(request: request) {
                outcome.events.append(event)
                switch event {
                case .content(let text):
                    outcome.chunks.append(text)
                    parser.parse(text).forEach(apply)
                case .parsed(let parsed): apply(parsed)
                case .info(let info): outcome.info = info
                case .toolCall(let call): outcome.calls.append(call)
                case .toolCallDelta(let delta):
                    outcome.callDeltas.append(delta)
                    if let call = delta.completed { outcome.calls.append(call) }
                case .logprobs: break
                }
            }
        } catch { outcome.error = error }
        parser.finish().forEach(apply)
        outcome.collected = ReasoningParser(format: .harmony).parse(outcome.chunks.joined())
        await bridge.shutdown()
        outcome.loopGuardStops = telemetry.loopGuardStops
        return outcome
    }

    private static let loopText = String(HarmonyLoopTestEngine.clause)

    /// No Harmony framing in what the client reads as text.
    private func framingFree(_ text: String) -> Bool {
        !["<|", "|>", "assistant", "analysis", "functions."].contains { text.contains($0) }
    }

    @Test("a loop in the analysis ends the message; the final answer follows; usage counts every token")
    func analysisLoopEndsInAnAnswer() async throws {
        let engine = HarmonyLoopTestEngine(.analysisLoop)
        let outcome = try await serve(engine)
        #expect(outcome.error == nil)
        #expect(engine.cancelCount == 1)
        let requests = engine.requests
        #expect(requests.count == 2)
        let first = try #require(requests.first)
        let continuation = try #require(requests.last)
        let rowOutput = try #require(engine.outputs.first)
        let answerOutput = try #require(engine.outputs.last)
        // The same prompt, every token the row produced (the in-flight ones
        // after the stop included), then `<|end|><|start|>assistant`.
        #expect(continuation.promptTokens == first.promptTokens + rowOutput + Self.exitTokens)
        #expect(continuation.maxTokens == first.maxTokens - rowOutput.count - 3)
        // The continuation keeps the request's sampling (temperature 0) and the model's stop scope.
        #expect(continuation.sampling.temperature == 0)
        #expect(continuation.stopStringScope == GPTOSSHarmonyTemplateFix.finalChannelStopScope)
        #expect(continuation.sampling.temperature == first.sampling.temperature)
        #expect(continuation.sampling.topP == first.sampling.topP)
        #expect(continuation.sampling.seed == first.sampling.seed)
        // Streamed: the analysis is reasoning, the answer is content, no framing in either.
        #expect(outcome.reasoning.hasPrefix(Self.loopText))
        #expect(framingFree(outcome.reasoning))
        #expect(outcome.content == "Answer: B")
        // Collected (non-stream): the same split.
        #expect(outcome.collected.content == "Answer: B")
        #expect(outcome.collected.reasoningContent?.hasPrefix(Self.loopText.trimmingCharacters(in: .whitespaces)) == true)
        #expect(outcome.collected.reasoningContent.map(framingFree) == true)
        #expect(outcome.info?.stopReason == "stop")
        #expect(outcome.info?.promptTokens == first.promptTokens.count)
        #expect(outcome.info?.completionTokens == rowOutput.count + 3 + answerOutput.count)
        #expect(outcome.loopGuardStops == [true])
    }

    @Test("streaming deltas: the row's text, the exit as one chunk, then the continuation's; the parser routes each")
    func streamingDeltas() async throws {
        let engine = HarmonyLoopTestEngine(.analysisLoop)
        let outcome = try await serve(engine)
        // The row's text, the exit once, then the continuation's text, in order and whole. Chunk boundaries are
        // the stream's own: the tool handler may hold `<|start|>assistant` (a call header's prefix) and the
        // Harmony header filter a header in progress, until the next chunk shows what they are.
        let joined = outcome.chunks.joined()
        let exitRange = try #require(joined.range(of: "<|end|><|start|>assistant"))
        #expect(joined.components(separatedBy: "<|end|>").count == 2)
        #expect(String(joined[..<exitRange.lowerBound]).hasPrefix("<|channel|>analysis<|message|>" + Self.loopText))
        #expect(String(joined[exitRange.upperBound...]) == "<|channel|>final<|message|>Answer: B")
        // Event order: every text event precedes the one terminal.
        let infoIndex = try #require(outcome.events.firstIndex { event in
            if case .info = event { return true }
            return false
        })
        #expect(infoIndex == outcome.events.count - 1)
        // Fed chunk by chunk, the parser never shows reasoning after content.
        var parser = StreamingReasoningParser(format: .harmony)
        var sawContent = false
        var reasoningAfterContent = false
        for chunk in outcome.chunks {
            for piece in parser.parse(chunk) {
                if !piece.content.isEmpty { sawContent = true }
                if sawContent, !(piece.reasoningContent ?? "").isEmpty { reasoningAfterContent = true }
            }
        }
        #expect(sawContent)
        #expect(!reasoningAfterContent)
    }

    @Test("a tool call after the exit: the call is parsed and validated, nothing leaks as content",
          arguments: [HarmonyLoopTestEngine.Next.callInChannel, .callInRole], [false, true])
    func toolCallAfterTheExit(next: HarmonyLoopTestEngine.Next, streamCalls: Bool) async throws {
        let engine = HarmonyLoopTestEngine(.analysisLoop, then: next)
        let outcome = try await serve(engine, extra: Self.tools, streamCalls: streamCalls)
        #expect(outcome.error == nil)
        #expect(engine.requests.count == 2)
        let first = try #require(engine.requests.first)
        let rowOutput = try #require(engine.outputs.first)
        #expect(try #require(engine.requests.last).promptTokens == first.promptTokens + rowOutput + Self.exitTokens)
        #expect(outcome.calls.count == 1)
        let call = try #require(outcome.calls.first)
        #expect(call.function.name == "get_weather")
        #expect(call.function.arguments == ["city": .string("Paris")])
        if streamCalls {
            #expect(outcome.callDeltas.first?.name == "get_weather")
        }
        #expect(outcome.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(outcome.reasoning.hasPrefix(Self.loopText))
        #expect(framingFree(outcome.reasoning))
        #expect(outcome.info?.stopReason == "stop")
        #expect(outcome.info?.completionTokens
            == rowOutput.count + 3 + (try #require(engine.outputs.last)).count)
        #expect(outcome.loopGuardStops == [true])
    }

    @Test("with tools declared, a final answer after the exit is still content")
    func finalAnswerWithTools() async throws {
        let engine = HarmonyLoopTestEngine(.analysisLoop, then: .final)
        let outcome = try await serve(engine, extra: Self.tools, streamCalls: true)
        #expect(outcome.error == nil)
        #expect(outcome.calls.isEmpty)
        #expect(outcome.content == "Answer: B")
        #expect(outcome.info?.stopReason == "stop")
    }

    @Test("every reasoning effort: the rendered effort is kept in the continuation's prompt and the answer follows",
          arguments: [(nil, "medium"), ("low", "low"), ("medium", "medium"), ("high", "high"), ("xhigh", "high")]
              as [(String?, String)])
    func reasoningEfforts(effort: String?, level: String) async throws {
        let engine = HarmonyLoopTestEngine(.analysisLoop)
        let outcome = try await serve(engine, effort: effort, extra: Self.tools)
        #expect(outcome.error == nil)
        let first = try #require(engine.requests.first)
        let continuation = try #require(engine.requests.last)
        #expect(engine.requests.count == 2)
        #expect(Self.tokenizer.decode(tokenIds: first.promptTokens, skipSpecialTokens: false)
            .contains("Reasoning: \(level)\n"))
        #expect(Array(continuation.promptTokens.prefix(first.promptTokens.count)) == first.promptTokens)
        #expect(continuation.promptTokens.suffix(3) == Self.exitTokens[...])
        #expect(outcome.content == "Answer: B")
        #expect(outcome.info?.stopReason == "stop")
    }

    @Test("a continuation that opens another analysis and loops ends as length, with no second exit")
    func reopenedAnalysisEndsAsLength() async throws {
        let engine = HarmonyLoopTestEngine(.analysisLoop, then: .reopensAnalysis)
        // Room for the continuation's own loop to reach the guard (the answer's cap, 8,192).
        let outcome = try await serve(engine, maxTokens: 16_384)
        #expect(outcome.error == nil)
        #expect(engine.requests.count == 2)
        #expect(engine.cancelCount == 2)
        #expect(outcome.info?.stopReason == "length")
        #expect(outcome.content.isEmpty)
        #expect(outcome.loopGuardStops == [true, false])
        let rowOutput = try #require(engine.outputs.first)
        let answerOutput = try #require(engine.outputs.last)
        #expect(outcome.info?.completionTokens == rowOutput.count + 3 + answerOutput.count)
    }

    @Test("a thought loop that left no answer budget ends as length, as before", arguments: [true, false])
    func noBudgetLeft(declaresTools: Bool) async throws {
        let engine = HarmonyLoopTestEngine(.analysisLoop)
        // The row produces 3 + 4,200 tokens: under 256 are left for the answer.
        let outcome = try await serve(engine, maxTokens: 4_400, extra: declaresTools ? Self.tools : "")
        #expect(engine.requests.count == 1)
        #expect(outcome.info?.stopReason == "length")
        #expect(outcome.content.isEmpty)
        #expect(outcome.loopGuardStops == [true])
    }

    /// The same Harmony tokenizer without `<|end|>` in its lookup: no exit
    /// resolves, which is the switch's off path; prompts and output are the same tokens.
    private static let withoutExit: HarmonyTestTokenizer = {
        var tokenizer = HarmonyTestTokenizer()
        tokenizer.resolvable = Set(HarmonyTestTokenizer.vocabulary.map(\.0)).subtracting(["<|end|>"])
        return tokenizer
    }()

    @Test("no change where the guard doesn't fire, or fires after the analysis: the same events as without the exit",
          arguments: [HarmonyLoopTestEngine.Row.answers, .finalLoop], [true, false])
    func unchangedWithoutAnAnalysisLoop(row: HarmonyLoopTestEngine.Row, declaresTools: Bool) async throws {
        let on = HarmonyLoopTestEngine(row)
        let off = HarmonyLoopTestEngine(row)
        let extra = declaresTools ? Self.tools : ""
        let withExit = try await serve(on, extra: extra)
        let without = try await serve(off, tokenizer: Self.withoutExit, extra: extra)
        #expect(on.requests.count == 1)
        #expect(off.requests.count == 1)
        #expect(on.requests.first?.promptTokens == off.requests.first?.promptTokens)
        #expect(withExit.chunks == without.chunks)
        #expect(withExit.content == without.content)
        #expect(withExit.reasoning == without.reasoning)
        #expect(withExit.info?.stopReason == without.info?.stopReason)
        #expect(withExit.info?.promptTokens == without.info?.promptTokens)
        #expect(withExit.info?.completionTokens == without.info?.completionTokens)
        #expect(withExit.loopGuardStops == without.loopGuardStops)
        switch row {
        case .answers:
            #expect(withExit.content == "Answer: B")
            #expect(withExit.info?.stopReason == "stop")
            #expect(withExit.loopGuardStops.isEmpty)
        default:
            #expect(withExit.info?.stopReason == "length")
            #expect(withExit.loopGuardStops == [false])
        }
    }

    @Test("without tools: the exit opens the final channel, the answer follows as content, usage counts every token",
          arguments: [false, true])
    func noToolsEndsInFinal(noneChoice: Bool) async throws {
        let engine = HarmonyLoopTestEngine(.analysisLoop, then: .answer)
        // `tool_choice: none` drops the tools before rendering (`prepared.tools` is nil): no call can follow.
        let outcome = try await serve(engine, extra: noneChoice ? Self.tools + #","tool_choice":"none""# : "")
        #expect(outcome.error == nil)
        #expect(engine.cancelCount == 1)
        #expect(engine.requests.count == 2)
        let first = try #require(engine.requests.first)
        let continuation = try #require(engine.requests.last)
        let rowOutput = try #require(engine.outputs.first)
        let answerOutput = try #require(engine.outputs.last)
        // The same prompt, every token the row produced, then `<|end|><|start|>assistant<|channel|>final<|message|>`.
        #expect(continuation.promptTokens == first.promptTokens + rowOutput + Self.finalExitTokens)
        #expect(continuation.maxTokens == first.maxTokens - rowOutput.count - Self.finalExitTokens.count)
        #expect(continuation.sampling.temperature == 0)
        // The row's stops apply in the final channel only; the continuation's output starts inside it.
        #expect(first.stopStringScope == GPTOSSHarmonyTemplateFix.finalChannelStopScope)
        #expect(continuation.stopStringScope == GPTOSSHarmonyTemplateFix.insideFinalChannelStopScope)
        // Streamed and collected: the analysis is reasoning, the answer is content, no framing in either.
        #expect(outcome.reasoning.hasPrefix(Self.loopText))
        #expect(framingFree(outcome.reasoning))
        #expect(outcome.content == "Answer: B")
        #expect(outcome.collected.content == "Answer: B")
        #expect(outcome.collected.reasoningContent.map(framingFree) == true)
        #expect(outcome.calls.isEmpty)
        // The exit once, as the client's stream shows it.
        let joined = outcome.chunks.joined()
        #expect(joined.components(separatedBy: "<|end|><|start|>assistant<|channel|>final<|message|>").count == 2)
        #expect(joined.hasSuffix("<|end|><|start|>assistant<|channel|>final<|message|>Answer: B"))
        #expect(outcome.info?.stopReason == "stop")
        #expect(outcome.info?.promptTokens == first.promptTokens.count)
        #expect(outcome.info?.completionTokens == rowOutput.count + Self.finalExitTokens.count + answerOutput.count)
        #expect(outcome.loopGuardStops == [true])
    }

    @Test("without tools, a stop string that ends the answer is the request's matched stop sequence")
    func noToolsStopInTheAnswer() async throws {
        let engine = HarmonyLoopTestEngine(.analysisLoop, then: .answer)
        let usage = EngineV2RequestUsageSignal()
        // "need" is only in the row's analysis (the loop's clause), where stops do not apply.
        let outcome = try await serve(engine, extra: #","stop":["need","B"]"#, usage: usage)
        #expect(outcome.error == nil)
        #expect(engine.requests.count == 2)
        #expect(engine.requests.last?.stopStrings == ["need", "B"])
        #expect(outcome.info?.stopReason == "stop")
        // Matched from the continuation's first token: its output starts inside the final channel.
        #expect(usage.matchedStopSequence == "B")
    }

    @Test("without tools, an answer the model ends at once is an empty stop: the model's own end, counted")
    func noToolsEmptyAnswer() async throws {
        let engine = HarmonyLoopTestEngine(.analysisLoop, then: .noAnswer)
        let outcome = try await serve(engine, extra: "")
        #expect(outcome.error == nil)
        #expect(engine.requests.count == 2)
        let rowOutput = try #require(engine.outputs.first)
        #expect(outcome.content.isEmpty)
        #expect(outcome.info?.stopReason == "stop")
        #expect(outcome.info?.completionTokens == rowOutput.count + Self.finalExitTokens.count + 1)
    }

    @Test("without tools, an answer that repeats itself after the exit ends as length, with the answer so far")
    func finalAnswerLoopEndsAsLength() async throws {
        let engine = HarmonyLoopTestEngine(.analysisLoop, then: .answerLoop)
        // Room for the answer's own loop to reach the guard (the answer's cap, 8,192).
        let outcome = try await serve(engine, maxTokens: 16_384, extra: "")
        #expect(outcome.error == nil)
        #expect(engine.requests.count == 2)
        #expect(engine.cancelCount == 2)
        #expect(outcome.info?.stopReason == "length")
        #expect(outcome.content.hasPrefix(Self.loopText))
        #expect(outcome.loopGuardStops == [true, false])
    }

    @Test("`DARKBLOOM_GPTOSS_FINAL_EXIT` off: without tools an analysis loop ends as length, as 0.10.13")
    func finalExitOffKeepsLength() async throws {
        let engine = HarmonyLoopTestEngine(.analysisLoop, then: .answer)
        let outcome = try await serve(engine, extra: "", finalExit: false)
        #expect(engine.requests.count == 1)
        #expect(outcome.info?.stopReason == "length")
        #expect(outcome.content.isEmpty)
        #expect(outcome.loopGuardStops == [false])
        // With tools, the switch changes nothing.
        let tools = HarmonyLoopTestEngine(.analysisLoop)
        let withTools = try await serve(tools, finalExit: false)
        #expect(tools.requests.count == 2)
        #expect(withTools.content == "Answer: B")
    }

    @Test("off: an analysis loop ends as length with nothing more submitted, as 0.10.12",
          arguments: ["0", "gemma4,gemma4_text"])
    func offKeepsLength(switchValue: String) async throws {
        let setting = GenerationLoopExitThinkingPolicy.setting(
            environment: [GenerationLoopExitThinkingPolicy.environmentKey: switchValue])
        let engine = HarmonyLoopTestEngine(.analysisLoop)
        let outcome = try await serve(engine, exitSetting: setting)
        #expect(engine.requests.count == 1)
        #expect(outcome.info?.stopReason == "length")
        #expect(outcome.content.isEmpty)
        #expect(outcome.loopGuardStops == [false])
        // The exit that cannot resolve (a tokenizer without `<|end|>`) is the same path.
        let unresolved = HarmonyLoopTestEngine(.analysisLoop)
        let same = try await serve(unresolved, tokenizer: Self.withoutExit)
        #expect(same.chunks == outcome.chunks)
        #expect(same.info?.completionTokens == outcome.info?.completionTokens)
    }
}

/// Against the GPT-OSS 20B snapshot's tokenizer and served template (no
/// weights are read): `DARKBLOOM_TEST_GPTOSS_TOKENIZER_DIR=<snapshot>`.
@Suite("Loop guard: GPT-OSS's exit with the real tokenizer",
       .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GPTOSS_TOKENIZER_DIR"] != nil))
struct GenerationLoopExitThinkingHarmonyRealTokenizerTests {
    private func tokenizer() async throws -> any MLXLMCommon.Tokenizer {
        let directory = URL(fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GPTOSS_TOKENIZER_DIR"]))
        return try await LocalTokenizerLoader(environment: [:]).load(from: directory)
    }

    private func body(effort: String?, tools: Bool) throws -> Data {
        var root: [String: Any] = [
            "model": "gpt-oss-20b", "temperature": 0,
            "messages": [["role": "user", "content": "What is the weather in Paris?"]],
        ]
        if let effort { root["reasoning_effort"] = effort }
        if tools {
            root["tools"] = [["type": "function", "function": [
                "name": "get_weather", "description": "Weather in a city",
                "parameters": ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]],
            ]]]
            root["messages"] = [
                ["role": "user", "content": "What is the weather in Paris?"],
                ["role": "assistant", "content": "",
                 "tool_calls": [["id": "c1", "type": "function",
                                 "function": ["name": "get_weather", "arguments": #"{"city":"Paris"}"#]]]],
                ["role": "tool", "tool_call_id": "c1", "content": "sunny"],
                ["role": "user", "content": "And in Lyon?"],
            ]
        }
        return try JSONSerialization.data(withJSONObject: root)
    }

    @Test("the served tokenizer spells the exit as three tokens; every effort's prompt ends where the model opens its analysis")
    func servedTokenizerAndTemplate() async throws {
        let tokenizer = try await tokenizer()
        for effort in [nil, "low", "medium", "high"] as [String?] {
            for tools in [false, true] {
                let data = try body(effort: effort, tools: tools)
                let request = try ProviderLoop.decodeOpenAIRequest(data, modelType: "gpt_oss")
                let controls = ProviderLoop.extractChatTemplateControls(from: data)
                let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "gpt_oss")
                let prompt = try ProviderPromptContractPipeline.tokenize(prepared: prepared, request: request,
                    tokenizer: tokenizer, modelType: "gpt_oss", templateControls: controls)
                let text = tokenizer.decode(tokenIds: prompt, skipSpecialTokens: false)
                #expect(text.hasSuffix("<|start|>assistant"), "\(effort ?? "default") tools=\(tools)")
                #expect(text.contains("Reasoning: \(effort ?? "medium")"), "\(effort ?? "default") tools=\(tools)")
                let exit = try #require(GenerationLoopExitThinkingPolicy.resolve(
                    modelType: "gpt_oss", tokenizer: tokenizer, promptTokens: prompt, logprobs: false,
                    declaresTools: true, setting: .modelTypes(GenerationLoopExitThinkingPolicy.defaultModelTypes)))
                #expect(exit.exitTokens == [200_007, 200_006, 173_781])
                #expect(exit.closeToken == 200_007)
                #expect(tokenizer.decode(tokenIds: exit.exitTokens, skipSpecialTokens: false)
                    == "<|end|><|start|>assistant")
                #expect(!exit.startsInside)
                // Without tools: the same, then the final channel's header, each control as itself.
                let final = try #require(GenerationLoopExitThinkingPolicy.resolve(
                    modelType: "gpt_oss", tokenizer: tokenizer, promptTokens: prompt, logprobs: false,
                    declaresTools: false, setting: .modelTypes(GenerationLoopExitThinkingPolicy.defaultModelTypes),
                    finalExit: true))
                #expect(final.exitTokens == [200_007, 200_006, 173_781, 200_005, 17_196, 200_008])
                #expect(tokenizer.decode(tokenIds: final.exitTokens, skipSpecialTokens: false)
                    == "<|end|><|start|>assistant<|channel|>final<|message|>")
                #expect(!final.startsInside)
            }
        }
    }

    @Test("real tokens: an analysis cut by the exit, then a final answer or a call, parse as the model's own would")
    func realTokensParse() async throws {
        let tokenizer = try await tokenizer()
        let analysis = tokenizer.encode(
            text: "<|channel|>analysis<|message|>We need to check. We need to check. ", addSpecialTokens: false)
        let exit = [200_007, 200_006, 173_781]
        let answer = tokenizer.encode(text: "<|channel|>final<|message|>Answer: B", addSpecialTokens: false)
        let text = tokenizer.decode(tokenIds: analysis + exit + answer, skipSpecialTokens: false)
        let collected = ReasoningParser(format: .harmony).parse(text)
        #expect(collected.content == "Answer: B")
        #expect(collected.reasoningContent == "We need to check. We need to check.")
        // The model's own text after its analysis is the same tokens.
        #expect(tokenizer.encode(text: "<|end|><|start|>assistant", addSpecialTokens: false) == exit)
        let call = tokenizer.encode(
            text: #"<|channel|>commentary to=functions.get_weather <|constrain|>json<|message|>{"city":"Lyon"}"#,
            addSpecialTokens: false)
        let callText = tokenizer.decode(tokenIds: exit + call, skipSpecialTokens: false)
        let parsed = try #require(HarmonyToolCallParser().parse(content: callText, tools: nil))
        #expect(parsed.function.name == "get_weather")
        #expect(parsed.function.arguments == ["city": .string("Lyon")])
        // Without tools the exit feeds the final header; the answer after it is the same tokens as the model's own.
        let finalExit = [200_007, 200_006, 173_781, 200_005, 17_196, 200_008]
        #expect(tokenizer.encode(text: "<|end|><|start|>assistant<|channel|>final<|message|>", addSpecialTokens: false)
            == finalExit)
        let bare = tokenizer.encode(text: "Answer: B", addSpecialTokens: false)
        let finalText = tokenizer.decode(tokenIds: analysis + finalExit + bare, skipSpecialTokens: false)
        let answered = ReasoningParser(format: .harmony).parse(finalText)
        #expect(answered.content == "Answer: B")
        #expect(answered.reasoningContent == "We need to check. We need to check.")
    }
}
