// Copyright © 2026 Eigen Labs Inc.
//
// Live, end-to-end proof for issue #249 against the real
// `mlx-community/gemma-4-26b-a4b-it-8bit` model + its real downloaded
// `chat_template.jinja` (rendered by swift-jinja).
//
// Gated:
//   DARKBLOOM_LIVE_MLX_TESTS=1 DARKBLOOM_LIVE_MLX_GEMMA=1
//   (generation additionally needs mlx.metallib — set MLX_METALLIB_SOURCE
//    or have it under .build; see LiveInferenceFixtures).

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

    /// run_terminal tool spec in the shape the chat template + parser expect.
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

    /// The multi-turn history that triggers the bug: a prior, well-formed
    /// assistant `tool_calls` step (OpenAI shape — arguments is a JSON string),
    /// its `tool` result, then a fresh user turn that should produce a second
    /// tool call.
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

    /// Hand-built message dicts identical to `templateMessageDict()` output but
    /// with the prior tool call's arguments left as the raw OpenAI JSON *string*
    /// — i.e. the pre-fix behavior, used to demonstrate the double brace.
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

    // MARK: - A. Prompt rendering against the REAL template (no GPU needed)

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

        // FIXED path: the production code under test.
        let fixedDicts = conversation().map { $0.templateMessageDict() }
        let fixedIDs = try tokenizer.applyChatTemplate(
            messages: fixedDicts, tools: toolSpecs, additionalContext: nil)
        let fixedPrompt = tokenizer.decode(tokenIds: fixedIDs, skipSpecialTokens: false)

        // PRE-FIX path: arguments forwarded as the raw JSON string.
        let buggyIDs = try tokenizer.applyChatTemplate(
            messages: rawStringDicts(), tools: toolSpecs, additionalContext: nil)
        let buggyPrompt = tokenizer.decode(tokenIds: buggyIDs, skipSpecialTokens: false)

        print("\n=== issue #249: rendered prior tool_call (FIXED) ===")
        print(snippet(fixedPrompt, around: "call:run_terminal"))
        print("=== rendered prior tool_call (RAW STRING / pre-fix) ===")
        print(snippet(buggyPrompt, around: "call:run_terminal"))
        print("====================================================\n")

        // Pre-fix double brace is present...
        #expect(buggyPrompt.contains(#"{{"command""#))
        // ...and the fix removes it, emitting the mapping branch instead.
        #expect(!fixedPrompt.contains(#"{{"command""#))
        #expect(fixedPrompt.contains("call:run_terminal{command:"))
    }

    // MARK: - B. Real generation on the real model (needs metallib + ~28 GB)

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

        // Build the prompt via the production translation (templateMessageDict).
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

        // No double-brace poison in the generated tool call.
        #expect(!text.contains("{{"))

        // Parse the tool call the same way the server does.
        let parsed = GemmaFunctionParser().parse(content: text, tools: toolSpecs)
        let call = try #require(parsed, "model did not emit a parseable Gemma tool call")
        #expect(call.function.name == "run_terminal")

        // The corruption symptom is a key like `{"command"` (object split at the
        // first colon). Assert every key is clean.
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
