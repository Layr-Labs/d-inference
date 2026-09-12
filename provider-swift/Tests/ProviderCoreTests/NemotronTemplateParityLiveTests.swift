// Copyright © 2026 Eigen Labs.

import Foundation
import Jinja
import MLXLMServer
import XCTest
@testable import ProviderCore

final class NemotronTemplateParityLiveTests: XCTestCase {
    func testProviderPathMatchesReferenceCorpus() async throws {
        guard let path = ProcessInfo.processInfo.environment["NEMOTRON_TEMPLATE_MODEL_DIR"] else {
            throw XCTSkip("set NEMOTRON_TEMPLATE_MODEL_DIR for the local artifact parity gate")
        }
        let modelDirectory = URL(fileURLWithPath: path, isDirectory: true)
        let fixtureURL = try XCTUnwrap(Bundle.module.url(
            forResource: "nemotron-reference-corpus", withExtension: "json", subdirectory: "Fixtures"))
        let corpus = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        let cases = try XCTUnwrap(corpus["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 25)
        let tokenizer = try await LocalTokenizerLoader().load(from: modelDirectory)
        for fixture in cases {
            let name = try XCTUnwrap(fixture["name"] as? String)
            let body = try XCTUnwrap(fixture["body"] as? [String: Any])
            let expectedPrompt = try XCTUnwrap(fixture["prompt"] as? String)
            let expectedTokens = try XCTUnwrap(fixture["token_ids"] as? [NSNumber]).map(\.intValue)
            let tokens = try ProviderPromptContractPipeline.tokenizeProviderBody(
                JSONSerialization.data(withJSONObject: body), tokenizer: tokenizer, modelType: "nemotron_h")
            XCTAssertEqual(tokens, expectedTokens, name)
            XCTAssertEqual(tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false), expectedPrompt, name)
        }
    }

    func testOpenRouterBostonRequestMatchesTransformersReference() async throws {
        guard let path = ProcessInfo.processInfo.environment["NEMOTRON_TEMPLATE_MODEL_DIR"] else {
            throw XCTSkip("set NEMOTRON_TEMPLATE_MODEL_DIR for the local artifact parity gate")
        }
        let modelDirectory = URL(fileURLWithPath: path, isDirectory: true)
        let fixtureURL = try XCTUnwrap(Bundle.module.url(
            forResource: "nemotron-openrouter-boston-reference",
            withExtension: "json",
            subdirectory: "Fixtures"))
        let fixtureData = try Data(contentsOf: fixtureURL)
        let fixture = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixtureData) as? [String: Any])
        let messages = try XCTUnwrap(fixture["messages"] as? [[String: Any]])
        let tools = try XCTUnwrap(fixture["tools"] as? [[String: Any]])
        let typedTools = try JSONDecoder().decode(
            [OpenAITool].self, from: JSONSerialization.data(withJSONObject: tools))
        let expectedPrompt = try XCTUnwrap(fixture["prompt"] as? String)
        let tokenValues = try XCTUnwrap(fixture["token_ids"] as? [Any])
        let expectedTokens = try tokenValues.map { value in
            try XCTUnwrap((value as? NSNumber)?.intValue)
        }
        XCTAssertEqual(expectedTokens.count, 354)

        let templateSource = try String(
            contentsOf: modelDirectory.appendingPathComponent("chat_template.jinja"),
            encoding: .utf8)
        let template = try Template(
            NemotronTemplateFilters.bindingFilters(
                in: normalizeSwiftJinjaTemplate(templateSource), modelType: "nemotron_h"),
            with: .init(lstripBlocks: true, trimBlocks: true))
        let environment = Environment()
        NemotronTemplateFilters.install(in: environment, modelType: "nemotron_h")
        let context: [String: Value] = [
            "messages": .array(try messages.map { try Value(any: $0) }),
            "tools": .array(try typedTools.map { try Value(any: $0.toolSpec()) }),
            "enable_thinking": .boolean(false),
            "add_generation_prompt": .boolean(true),
        ]
        XCTAssertEqual(try template.render(context, environment: environment), expectedPrompt)

        let body: [String: Any] = [
            "model": "EigenLabs/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-MLX-4bit-mtp",
            "messages": messages,
            "tools": tools,
            "max_tokens": 32768,
            "stream": true,
            "stream_options": ["include_usage": true],
            "chat_template_kwargs": ["thinking": false, "enable_thinking": false],
            "reasoning": ["enabled": false],
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let tokenizer = try await LocalTokenizerLoader().load(from: modelDirectory)
        let actualTokens = try ProviderPromptContractPipeline.tokenizeProviderBody(
            bodyData, tokenizer: tokenizer, modelType: "nemotron_h")
        XCTAssertEqual(actualTokens, expectedTokens)
        XCTAssertEqual(tokenizer.decode(tokenIds: actualTokens, skipSpecialTokens: false), expectedPrompt)
    }
}
