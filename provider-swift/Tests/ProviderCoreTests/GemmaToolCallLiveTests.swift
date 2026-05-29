// Copyright © 2026 Eigen Labs Inc.
//
// Live end-to-end coverage for #249 against the real gemma-4-26b model.
// Gated by DARKBLOOM_LIVE_MLX_TESTS=1 + DARKBLOOM_LIVE_MLX_GEMMA=1.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMServer
import Testing
import Tokenizers

@testable import ProviderCore

@Suite("issue #249: Gemma multi-turn tool-calling against the real model", .serialized)
struct GemmaToolCallLiveTests {

    // MARK: - Scenario

    private var toolSpecs: [[String: any Sendable]] {
        [[
            "type": "function",
            "function": [
                "name": "run_terminal",
                "description": "Run a shell command and return its stdout.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "command": [
                            "type": "string",
                            "description": "The shell command to run.",
                        ] as [String: any Sendable]
                    ] as [String: any Sendable],
                    "required": ["command"],
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ]]
    }

    private let systemPrompt =
        "You are a terminal assistant. You have one tool, run_terminal(command), "
        + "which runs a shell command and returns its stdout. Always call the tool "
        + "to inspect files; never guess file contents."

    /// Multi-turn history with a prior tool call, its result, and a new user turn.
    private func conversation() -> [OpenAIChatMessage] {
        [
            OpenAIChatMessage(role: .system, content: .text(systemPrompt)),
            OpenAIChatMessage(role: .user, content: .text("List the files here.")),
            OpenAIChatMessage(
                role: .assistant,
                content: .text(""),
                toolCalls: [
                    OpenAIToolCall(
                        id: "call_1",
                        function: .init(name: "run_terminal", arguments: #"{"command":"ls -la"}"#)
                    )
                ]
            ),
            OpenAIChatMessage(
                role: .tool,
                content: .text("total 8\n-rw-r--r--  1 user  staff  12 hello.txt"),
                toolCallID: "call_1"
            ),
            OpenAIChatMessage(role: .user, content: .text("Print the contents of hello.txt")),
        ]
    }

    /// Same history but with the prior tool call's arguments left as a raw JSON
    /// string (the pre-fix shape).
    private func rawStringDicts() -> [[String: any Sendable]] {
        let assistant: [String: any Sendable] = [
            "role": "assistant",
            "content": "",
            "tool_calls": [
                [
                    "id": "call_1",
                    "type": "function",
                    "function": [
                        "name": "run_terminal",
                        "arguments": #"{"command":"ls -la"}"#,  // raw string == pre-fix
                    ] as [String: any Sendable],
                ] as [String: any Sendable]
            ] as [[String: any Sendable]],
        ]
        return [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": "List the files here."],
            assistant,
            [
                "role": "tool", "content": "total 8\n-rw-r--r--  1 user  staff  12 hello.txt",
                "tool_call_id": "call_1",
            ],
            ["role": "user", "content": "Print the contents of hello.txt"],
        ]
    }

    // MARK: - Prompt rendering

    @Test(
        "real Gemma template: fixed translation renders single brace, raw string double-braces",
        .enabled(if: LiveInferenceFixtures.gemmaTestsEnabled)
    )
    func realTemplateRendersSingleBrace() async throws {
        guard let dir = ModelScanner.resolveLocalPath(modelID: LiveInferenceFixtures.gemmaModelID)
        else {
            Issue.record("gemma model not in local cache")
            return
        }
        let tokenizer = try await LocalTokenizerLoader().load(from: dir)

        let fixedDicts = conversation().map { $0.templateMessageDict() }
        let fixedIDs = try tokenizer.applyChatTemplate(
            messages: fixedDicts, tools: toolSpecs, additionalContext: nil)
        let fixedPrompt = tokenizer.decode(tokenIds: fixedIDs, skipSpecialTokens: false)

        let buggyIDs = try tokenizer.applyChatTemplate(
            messages: rawStringDicts(), tools: toolSpecs, additionalContext: nil)
        let buggyPrompt = tokenizer.decode(tokenIds: buggyIDs, skipSpecialTokens: false)

        print("\n=== issue #249: rendered prior tool_call (FIXED) ===")
        print(snippet(fixedPrompt, around: "call:run_terminal"))
        print("=== rendered prior tool_call (RAW STRING / pre-fix) ===")
        print(snippet(buggyPrompt, around: "call:run_terminal"))
        print("====================================================\n")

        #expect(buggyPrompt.contains(#"{{"command""#))
        #expect(!fixedPrompt.contains(#"{{"command""#))
        #expect(fixedPrompt.contains("call:run_terminal{command:"))
    }

    // MARK: - Generation

    @Test(
        "real Gemma generation: multi-turn tool call comes back clean",
        .enabled(if: LiveInferenceFixtures.gemmaTestsEnabled)
    )
    func realModelEmitsCleanToolCall() async throws {
        let loaded: (scheduler: BatchScheduler, container: ModelContainer, modelDirectory: URL)
        do {
            loaded = try await LiveInferenceFixtures.loadScheduler(
                modelID: LiveInferenceFixtures.gemmaModelID,
                maxConcurrentRequests: 2,
                memoryBudgetBytes: 64 * 1024 * 1024 * 1024
            )
        } catch let skip as LiveFixtureSkip {
            Issue.record("skipping: \(skip)")
            return
        }
        let scheduler = loaded.scheduler
        defer { Task { await scheduler.unloadModel() } }

        let dicts = conversation().map { $0.templateMessageDict() }
        let promptTokens: [Int] = try await loaded.container.perform { ctx in
            try ctx.tokenizer.applyChatTemplate(
                messages: dicts, tools: toolSpecs, additionalContext: nil)
        }

        var text = ""
        let stream = await scheduler.submitTokenized(
            promptTokens: promptTokens, maxTokens: 96, temperature: 0.0)
        for await event in stream {
            switch event {
            case .chunk(let t): text += t
            case .info, .error: break
            }
        }

        print("\n=== issue #249: real Gemma generation (raw) ===\n\(text)\n===========================\n")

        #expect(!text.contains("{{"))

        let parsed = GemmaFunctionParser().parse(content: text, tools: toolSpecs)
        let call = try #require(parsed, "model did not emit a parseable Gemma tool call")
        #expect(call.function.name == "run_terminal")

        // Keys must be clean (the bug produced keys like `{"command"`).
        for key in call.function.arguments.keys {
            #expect(!key.hasPrefix("{"), "corrupted key: \(key)")
            #expect(!key.contains("\""), "corrupted key: \(key)")
        }
        #expect(call.function.arguments["command"] != nil, "expected a clean `command` argument")
        if case .string(let cmd)? = call.function.arguments["command"] {
            print("=== parsed tool call: run_terminal(command: \(cmd)) ===")
            #expect(cmd.contains("hello.txt"))
        }
    }

    // MARK: - helpers

    /// A readable window of `text` centered on the first occurrence of `needle`.
    private func snippet(_ text: String, around needle: String, pad: Int = 60) -> String {
        guard let r = text.range(of: needle) else { return "(\(needle) not found)" }
        let lo = text.index(r.lowerBound, offsetBy: -pad, limitedBy: text.startIndex) ?? text.startIndex
        let hi = text.index(r.upperBound, offsetBy: pad, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[lo..<hi])
    }
}
