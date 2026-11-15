import CryptoKit
import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// Run against the GPT-OSS 20B snapshot (tokenizer and template files only; no
/// weights are read): `DARKBLOOM_TEST_GPTOSS_TOKENIZER_DIR=<snapshot>`.
@Suite("GPT-OSS forced tool calls, real tokenizer",
       .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GPTOSS_TOKENIZER_DIR"] != nil))
struct GPTOSSForcedToolRealTokenizerTests {
    private static let stops: Set<Int> = [199999, 200002, 200012]

    private func tokenizer() async throws -> any MLXLMCommon.Tokenizer {
        let directory = URL(fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["DARKBLOOM_TEST_GPTOSS_TOKENIZER_DIR"]))
        return try await LocalTokenizerLoader(environment: [:]).load(from: directory)
    }

    @Test func theServedTokenizerFramesAForcedCall() async throws {
        let tokenizer = try await tokenizer()
        let clock = ContinuousClock()
        let started = clock.now
        let vocabulary = try JSONAnswerVocabulary(tokenizer: tokenizer, profile: .gptOSS, stopTokenIDs: Self.stops)
        print("gptoss-forced-vocabulary-build: \(clock.now - started)")
        #expect(vocabulary.pieceTokenIDs.count == 199_998)
        let framing = try GPTOSSHarmonyFraming(tokenizer: tokenizer, names: ["get_weather", "get_time"],
            firstAddedTokenID: 199998)
        print("gptoss-forced-analysis-header: \(framing.analysisHeader)")
        for (name, tokens) in zip(["get_weather", "get_time"], framing.callHeaders) {
            print("gptoss-forced-call-header \(name): \(tokens) = \(tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false))")
        }

        // A real tokenization of a forced response walks through and ends at `<|call|>`.
        let body = try GPTOSSForcedFixture.request(choice: GPTOSSForcedFixture.namedWeather)
        let prepared = try ToolChoicePromptPolicy.prepare(body, modelType: "gpt_oss")
        let constraint = try GPTOSSForcedToolConstraint(mode: prepared.mode, tools: #require(prepared.compiledTools),
            tokenizer: tokenizer, vocabulary: vocabulary, maxTokens: 4_096)
        let output = GPTOSSForcedFixture.analysis("The user wants the weather in Paris, in Celsius. Call get_weather.")
            + GPTOSSForcedFixture.call("get_weather", #"{"city":"Paris","unit":"c"}"#)
        var state = constraint.initialState
        for (offset, token) in tokenizer.encode(text: output, addSpecialTokens: false).enumerated() {
            #expect(constraint.allowedTokenIDs(state: state, remainingTokens: 4_096 - offset).contains(token),
                "token \(token) at \(offset)")
            state = try #require(constraint.nextState(state: state, tokenID: token), "token \(token) at \(offset)")
        }
        #expect(constraint.nextState(state: state, tokenID: 200012) == -1)
        print("gptoss-forced-states: \(constraint.cachedStateCount)")
    }

    /// The platform's pinned GPT-OSS prompt-contract vectors (the coordinator
    /// sidecar's mirror, date-pinned): every case renders to the same tokens
    /// here, auto, none and the named forced case alike.
    @Test func promptsMatchThePinnedContractVectors() async throws {
        let tokenizer = try await tokenizer()
        let url = try vectorFile("production_vectors.json")
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let models = try #require(root["models"] as? [[String: Any]])
        let model = try #require(models.first { $0["model_id"] as? String == "gpt-oss-20b" })
        let cases = try #require(model["cases"] as? [[String: Any]])
        #expect(cases.count == 22)
        var matched = 0
        for fixture in cases {
            let id = try #require(fixture["id"] as? String)
            let body = try JSONSerialization.data(withJSONObject: #require(fixture["provider_body"]))
            let expected = try #require(fixture["token_ids"] as? [Int])
            // The service adds a JSON response_format's instruction before the
            // scheduler prepares the prompt (MLXOpenAIService).
            let request = try OpenAIResponseFormatSupport.preparedRequest(
                ProviderLoop.decodeOpenAIRequest(body, modelType: "gpt_oss"))
            let controls = ProviderLoop.extractChatTemplateControls(from: body)
            let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "gpt_oss")
            let tokens = try ProviderPromptContractPipeline.tokenize(prepared: prepared, request: request,
                tokenizer: tokenizer, modelType: "gpt_oss", templateControls: controls)
            #expect(tokens == expected, "\(id)")
            if tokens == expected { matched += 1 }
            print("gptoss-vector \(id) mode=\(prepared.mode.telemetryValue) tokens=\(tokens.count) "
                + "sha256=\(Self.digest(tokens)) match=\(tokens == expected)")
        }
        print("gptoss-vectors matched \(matched)/\(cases.count)")
    }

    /// Auto, required and named across efforts: one prompt boundary, the
    /// effort in the system message, and the forcing instruction only when forced.
    @Test func effortAndForcedChoiceRender() async throws {
        let tokenizer = try await tokenizer()
        for effort in [nil, "low", "medium", "high"] as [String?] {
            for (label, choice) in [("auto", nil), ("required", "required"),
                                    ("named", GPTOSSForcedFixture.namedWeather)] as [(String, Any?)] {
                let body = try GPTOSSForcedFixture.body(choice: choice, effort: effort)
                let request = try ProviderLoop.decodeOpenAIRequest(body, modelType: "gpt_oss")
                let controls = ProviderLoop.extractChatTemplateControls(from: body)
                let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "gpt_oss")
                let tokens = try ProviderPromptContractPipeline.tokenize(prepared: prepared, request: request,
                    tokenizer: tokenizer, modelType: "gpt_oss", templateControls: controls)
                let text = tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false)
                #expect(text.hasSuffix(GPTOSSHarmonyFraming.promptBoundary), "\(label) \(effort ?? "default")")
                #expect(text.contains("Reasoning: \(effort ?? "medium")"), "\(label) \(effort ?? "default")")
                #expect(text.contains("a text answer is forbidden") == (label != "auto"), "\(label)")
                // Named renders only the selected function's declaration.
                #expect(text.contains("get_time") == (label != "named"), "\(label)")
                print("gptoss-render \(label) effort=\(effort ?? "default") tokens=\(tokens.count) sha256=\(Self.digest(tokens))")
            }
        }
    }

    private static func digest(_ tokens: [Int]) -> String {
        SHA256.hash(data: Data(tokens.map(String.init).joined(separator: ",").utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    private func vectorFile(_ name: String) throws -> URL {
        if let directory = ProcessInfo.processInfo.environment["DARKBLOOM_TEST_PROMPT_CONTRACT_DIR"] {
            return URL(fileURLWithPath: directory).appendingPathComponent(name)
        }
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while root != root.deletingLastPathComponent() {
            let fixtures = root.appendingPathComponent("fixtures/prompt-contract/v1")
            if FileManager.default.fileExists(atPath: fixtures.path) { return fixtures.appendingPathComponent(name) }
            root.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
