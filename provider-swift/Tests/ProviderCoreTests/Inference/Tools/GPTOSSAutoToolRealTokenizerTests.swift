import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// Run against the GPT-OSS 20B snapshot (tokenizer and template files only; no
/// weights are read): `DARKBLOOM_TEST_GPTOSS_TOKENIZER_DIR=<snapshot>`.
@Suite("GPT-OSS auto tool calls, real tokenizer",
       .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GPTOSS_TOKENIZER_DIR"] != nil))
struct GPTOSSAutoToolRealTokenizerTests {
    private typealias A = GPTOSSAutoFixture
    private typealias F = GPTOSSForcedFixture
    private static let stops: Set<Int> = [199999, 200002, 200012]
    private static let call = 200012

    private func constraint(tools: [[String: Any]] = [F.weather, F.time]) async throws
        -> (GPTOSSAutoToolConstraint, any MLXLMCommon.Tokenizer) {
        let directory = URL(fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GPTOSS_TOKENIZER_DIR"]))
        let tokenizer = try await LocalTokenizerLoader(environment: [:]).load(from: directory)
        var prepared = try A.prepared(tools: tools)
        prepared.declaredTools = try A.declared(tools)
        let body = try F.request(choice: "auto", tools: tools)
        let prompt = try ProviderPromptContractPipeline.tokenize(prepared: prepared, request: body,
            tokenizer: tokenizer, modelType: "gpt_oss", templateControls: ProviderLoop.extractChatTemplateControls(
                from: F.body(choice: "auto", tools: tools)))
        let clock = ContinuousClock()
        let started = clock.now
        let constraint = try #require(GPTOSSAutoToolGrammar.constraint(prepared: prepared, modelType: "gpt_oss",
            tokenizer: TokenizerHandle(tokenizer), maxTokens: 4_096, stopTokenIDs: Self.stops, promptTokens: prompt,
            runsTokenConstraints: true, logitsWidth: 201_088, enabled: true))
        print("gptoss-auto-constraint-build (vocabulary included): \(clock.now - started)")
        return (constraint, tokenizer)
    }

    private func walk(_ text: String, _ constraint: GPTOSSAutoToolConstraint, _ tokenizer: any MLXLMCommon.Tokenizer,
                      everyMaskFree: Bool = false) -> Int? {
        let tokens = tokenizer.encode(text: text, addSpecialTokens: false)
        return A.walk(tokens, constraint) { state, remaining in
            if everyMaskFree {
                #expect(constraint.maskCacheKey(state: state, remainingTokens: remaining)
                    == GPTOSSAutoToolConstraint.freeMaskKey)
            }
        }
    }

    @Test func realCallsWalkBothHeaderShapes() async throws {
        let (constraint, tokenizer) = try await constraint()
        for output in [
            F.analysis("The user wants the weather in Paris. Call get_weather.")
                + F.call("get_weather", #"{"city":"Paris","unit":"c"}"#),
            " to=functions.get_time<|channel|>commentary json<|message|>{\"timezone\":\"Europe/Paris\"}",
            F.analysis("Need time.") + "<|start|>assistant to=functions.get_time<|channel|>commentary json<|message|>"
                + #"{"timezone": "UTC"}"#,
        ] {
            let state = try #require(walk(output, constraint, tokenizer), "\(output)")
            #expect(constraint.nextState(state: state, tokenID: Self.call) == -1)
        }
        print("gptoss-auto-states: \(constraint.cachedStateCount)")
        for output in [F.analysis("x") + F.call("delete_everything", "{}"), F.analysis("x") + F.call("get_weather", #"{"city":5}"#)] {
            #expect(walk(output, constraint, tokenizer) == nil, "\(output)")
        }
    }

    @Test func realAnswersWithoutACallAreFree() async throws {
        let (constraint, tokenizer) = try await constraint()
        let output = F.analysis("The user says hi. No tool needed; maybe browser.search or functions.x later.")
            + "<|start|>assistant<|channel|>commentary<|message|>Let me think.<|end|>"
            + "<|start|>assistant<|channel|>final<|message|>Hello! Visit example.com, v1.2.3 or a.b.c.<|return|>"
        #expect(walk(output, constraint, tokenizer, everyMaskFree: true) == -1)
    }

    @Test func realRefsCompile() async throws {
        let (constraint, tokenizer) = try await constraint(tools: [A.bookInlined])
        #expect(constraint.constrainsArguments(of: "book"))
        let state = try #require(walk(A.callFirst("book", #"{"passengers":[{"name":"Ada"}]}"#), constraint, tokenizer))
        #expect(constraint.nextState(state: state, tokenID: Self.call) == -1)
        #expect(walk(A.callFirst("book", #"{"passengers":["Ada"]}"#), constraint, tokenizer) == nil)
        // Rendered with its `$ref` typed as a string: free arguments.
        let (repaired, _) = try await self.constraint(tools: [A.book])
        #expect(!repaired.constrainsArguments(of: "book"))
        #expect(walk(A.callFirst("book", #"{"passengers":["Ada"]}"#), repaired, tokenizer) != nil)
    }
}
