// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// Deterministic token streams: no model, no GPU.
private struct TokenStream {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    /// A token id that varies from step to step.
    mutating func next(below bound: Int = 50_000) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(bound)) + 1_000
    }
    mutating func tokens(_ count: Int) -> [Int] { (0..<count).map { _ in next() } }
}

/// The window-7 Gemma q63 shape: a 19-token clause repeated verbatim.
private let q63Block = Array(900..<919)

private func feed(
    _ tokens: [Int], into detector: inout GenerationLoopDetector, chunk: Int = 1
) -> GenerationLoopDetector.Detection? {
    var start = 0
    while start < tokens.count {
        let end = min(start + chunk, tokens.count)
        if let detection = detector.append(Array(tokens[start..<end])) { return detection }
        start = end
    }
    return nil
}

@Suite("Loop detector: exact token periodicity")
struct GenerationLoopDetectorTests {
    @Test("a 19-token block repeated after varying text stops 2,048 tokens into the repeat")
    func syntheticLoopStops() {
        var stream = TokenStream(seed: 7)
        let prefix = stream.tokens(5_000)
        let loop = Array(repeatElement(q63Block, count: 1_000).joined())
        var detector = GenerationLoopDetector()
        let detection = feed(prefix + loop, into: &detector)
        // The first check (every 64 tokens) whose last 2,048 tokens all repeat.
        #expect(detection == .init(period: 19, span: 2_048, generatedTokens: 7_104))
    }

    @Test("an answer that loops from its first token is not stopped before 4,096 tokens")
    func neverBeforeMinimumTokens() {
        let loop = Array(repeatElement(q63Block, count: 1_000).joined())
        var detector = GenerationLoopDetector()
        #expect(feed(Array(loop.prefix(4_095)), into: &detector) == nil)
        #expect(feed([loop[4_095]], into: &detector)?.generatedTokens == 4_096)
    }

    @Test("one repeated token reports period 1")
    func singleTokenRun() {
        var stream = TokenStream(seed: 3)
        var detector = GenerationLoopDetector()
        let detection = feed(stream.tokens(4_096) + Array(repeating: 42, count: 3_000), into: &detector)
        #expect(detection?.period == 1)
        #expect(detection?.generatedTokens == 6_144)
    }

    @Test("a block longer than 512 tokens never counts as a loop")
    func periodAboveMaximum() {
        var stream = TokenStream(seed: 11)
        let block = stream.tokens(600)
        var detector = GenerationLoopDetector()
        #expect(feed(stream.tokens(4_096) + Array(repeatElement(block, count: 20).joined()), into: &detector) == nil)
    }

    @Test("a long block needs 8 repeats, not just 2,048 tokens")
    func longBlockNeedsRepeats() {
        var stream = TokenStream(seed: 13)
        let block = stream.tokens(400)
        let prefix = stream.tokens(4_096)
        var seven = GenerationLoopDetector()
        // 7 repeats = 2,800 tokens: over the span but under 8 × 400.
        #expect(feed(prefix + Array(repeatElement(block, count: 7).joined()) + stream.tokens(64), into: &seven) == nil)
        var nine = GenerationLoopDetector()
        let detection = feed(prefix + Array(repeatElement(block, count: 9).joined()), into: &nine)
        #expect(detection?.period == 400)
        #expect(detection?.span == 3_200)
    }

    @Test("repetitive but varying content never fires: numbered lines and table rows")
    func varyingStructureNeverFires() {
        // "Item <n>: ok\n" for n = 1…3,000, as tokens: the number changes every line.
        var lines: [Int] = []
        for n in 1...3_000 {
            lines += [500, 501] + String(n).map { Int($0.asciiValue!) } + [502, 503, 504]
        }
        var numbered = GenerationLoopDetector()
        #expect(feed(lines, into: &numbered) == nil)
        // A table whose one cell varies: the same 30 tokens, then a changing id.
        var stream = TokenStream(seed: 17)
        var rows: [Int] = []
        for _ in 0..<400 { rows += Array(600..<630) + [stream.next()] }
        var table = GenerationLoopDetector()
        #expect(feed(rows, into: &table) == nil)
    }

    @Test("a loop broken by one changed token every 1,000 tokens never fires")
    func nearVerbatimDoesNotFire() {
        var tokens: [Int] = []
        var stream = TokenStream(seed: 19)
        while tokens.count < 20_000 {
            tokens += Array(repeatElement(q63Block, count: 52).joined())  // 988 tokens
            tokens.append(stream.next())
        }
        var detector = GenerationLoopDetector()
        #expect(feed(tokens, into: &detector) == nil)
    }

    @Test("drafted deltas of several tokens are checked like single tokens")
    func multiTokenDeltas() throws {
        var stream = TokenStream(seed: 23)
        let tokens = stream.tokens(5_000) + Array(repeatElement(q63Block, count: 1_000).joined())
        var one = GenerationLoopDetector()
        var drafted = GenerationLoopDetector()
        let single = try #require(feed(tokens, into: &one))
        let multi = try #require(feed(tokens, into: &drafted, chunk: 5))
        #expect(single.period == 19)
        #expect(multi.period == 19)
        #expect(multi.generatedTokens >= single.generatedTokens)
        #expect(multi.generatedTokens < single.generatedTokens + 5)
    }
}

@Suite("Loop guard: tool calls and the per-model policy")
struct GenerationLoopGuardTests {
    private func loopDeltas(count: Int) -> [(String, [Int])] {
        (0..<count).map { index in ("x", [q63Block[index % q63Block.count]]) }
    }

    @Test("the guard fires once, on the delta that completes the loop")
    func firesOnce() {
        var loopGuard = GenerationLoopGuard(modelType: "gemma4", toolCallMarkers: ["<tool_call>"])
        var fired: [Int] = []
        for (index, delta) in loopDeltas(count: 8_000).enumerated()
        where loopGuard.observe(text: delta.0, tokens: delta.1) != nil {
            fired.append(index + 1)
        }
        #expect(fired == [4_096])
        #expect(loopGuard.disarmed)
    }

    @Test("a tool-call frame turns the guard off for the rest of the row, even split across deltas")
    func toolCallDisarms() {
        for split in [["<tool_call>"], ["<tool", "_call>"], ["to=funct", "ions.write"]] {
            var loopGuard = GenerationLoopGuard(
                modelType: "qwen3_5_moe", toolCallMarkers: GenerationLoopGuardPolicy.genericToolCallMarkers)
            for (index, piece) in split.enumerated() {
                #expect(loopGuard.observe(text: piece, tokens: [10 + index]) == nil)
            }
            #expect(loopGuard.disarmed, "\(split)")
            let fired = loopDeltas(count: 8_000).contains { loopGuard.observe(text: $0.0, tokens: $0.1) != nil }
            #expect(!fired, "\(split)")
        }
    }

    @Test("a marker without `<` or `=` is still seen")
    func markerOutsideTheBytePrefilter() {
        var loopGuard = GenerationLoopGuard(modelType: "gemma4", toolCallMarkers: ["<tool_call>", "[TOOL_CALLS]"])
        #expect(loopGuard.observe(text: "[TOOL_", tokens: [10]) == nil)
        #expect(loopGuard.observe(text: "CALLS]", tokens: [11]) == nil)
        #expect(loopGuard.disarmed)
    }

    private func request(
        tools: [OpenAITool]? = nil, choice: OpenAIToolChoice? = nil,
        responseFormat: OpenAIResponseFormat? = nil, parser: String? = nil
    ) -> OpenAIChatCompletionRequest {
        OpenAIChatCompletionRequest(
            model: "m", messages: [.init(role: .user, content: .text("hi"))],
            tools: tools, toolChoice: choice, toolCallParser: parser, responseFormat: responseFormat,
            maxTokens: 131_072)
    }

    private func tool() -> OpenAITool {
        OpenAITool(function: .init(name: "weather", description: "Weather", parameters: .object([
            "type": .string("object"),
            "properties": .object(["city": .object(["type": .string("string")])]),
        ])))
    }

    private func resolve(
        _ modelType: String?, _ request: OpenAIChatCompletionRequest,
        setting: GenerationLoopGuardPolicy.Setting = .modelTypes(GenerationLoopGuardPolicy.defaultModelTypes)
    ) throws -> GenerationLoopGuard? {
        GenerationLoopGuardPolicy.resolve(
            modelType: modelType, request: request,
            prepared: try ToolChoicePromptPolicy.prepare(request, modelType: modelType),
            tokenConstraint: nil, setting: setting)
    }

    @Test("on by default for the text chat families, off for the others")
    func defaultModelTypes() throws {
        for modelType in ["gemma4", "gemma4_text", "qwen3_5", "qwen3_5_moe", "qwen4_exp", "gpt_oss",
                          "nemotron_h", "nemotron_h_omni", "glm5_next", "mimo_v2"] {
            #expect(try resolve(modelType, request()) != nil, "\(modelType)")
        }
        for modelType in ["diffusion_gemma", "flint", "prism_hadamard_qwen35", "qwen3_vl_moe", "llama"] {
            #expect(try resolve(modelType, request()) == nil, "\(modelType)")
        }
        #expect(try resolve(nil, request()) == nil)
    }

    @Test("DARKBLOOM_LOOP_GUARD turns it off or names the model types")
    func environmentOverride() throws {
        let key = GenerationLoopGuardPolicy.environmentKey
        let defaults = GenerationLoopGuardPolicy.Setting.modelTypes(GenerationLoopGuardPolicy.defaultModelTypes)
        #expect(GenerationLoopGuardPolicy.setting(environment: [:]) == defaults)
        #expect(GenerationLoopGuardPolicy.setting(environment: [key: "1"]) == defaults)
        #expect(GenerationLoopGuardPolicy.setting(environment: [key: "on"]) == defaults)
        #expect(GenerationLoopGuardPolicy.setting(environment: [key: "0"]) == .off)
        #expect(GenerationLoopGuardPolicy.setting(environment: [key: "off"]) == .off)
        let listed = GenerationLoopGuardPolicy.setting(environment: [key: " gemma4 , GPT_OSS "])
        #expect(listed == .modelTypes(["gemma4", "gpt_oss"]))
        #expect(try resolve("gemma4", request(), setting: .off) == nil)
        #expect(try resolve("gemma4", request(), setting: listed) != nil)
        #expect(try resolve("qwen3_5_moe", request(), setting: listed) == nil)
    }

    @Test("never on a constrained or JSON answer, or a forced call")
    func constrainedOutputIsNeverGuarded() throws {
        #expect(try resolve("gemma4", request(responseFormat: .jsonObject())) == nil)
        #expect(try resolve("gemma4", request(tools: [tool()], choice: .mode(.required))) == nil)
        #expect(try resolve("gemma4", request(tools: [tool()], choice: .mode(.auto))) != nil)
    }

    @Test("a parser that reads untagged calls leaves nothing to stop at: no guard")
    func untaggedCallParsers() throws {
        #expect(try resolve("qwen3_5_moe", request(tools: [tool()], parser: "json")) == nil)
        #expect(try resolve("qwen3_5_moe", request(tools: [tool()], parser: "unknown-parser")) == nil)
        // Without declared tools the parser is never asked.
        #expect(try resolve("qwen3_5_moe", request(parser: "json")) != nil)
    }
}
