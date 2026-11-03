// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("Reasoning stop scope")
struct ReasoningStopScopeTests {
    private func run(_ output: String, stops: [String], scope: CBv2StopStringScope?) -> String {
        let holdback = StopHoldback(stopStrings: stops, scope: scope)
        let scan = holdback.ingest(output)
        return scan.stopped ? scan.text : scan.text + holdback.flush()
    }

    @Test("think parsers exclude reasoning and tool calls from where the prompt left off")
    func thinkParsers() {
        for parser in [ReasoningParserFormat.qwen3, .deepseekR1] {
            #expect(
                ReasoningStopScope.scope(reasoningParser: parser, reasoningPrefix: "<think>", parsesToolCalls: true)
                    == CBv2StopStringScope(
                        excluding: [ReasoningStopScope.think, ReasoningStopScope.thinkToolCall],
                        startingInside: true))
            for prefix in ["<think></think>", nil] {
                #expect(
                    ReasoningStopScope.scope(reasoningParser: parser, reasoningPrefix: prefix, parsesToolCalls: true)
                        == CBv2StopStringScope(
                            excluding: [ReasoningStopScope.think, ReasoningStopScope.thinkToolCall]))
            }
        }
    }

    @Test("Gemma 4 excludes its thought channel and tool calls")
    func gemma() {
        #expect(
            ReasoningStopScope.scope(reasoningParser: .gemma4, reasoningPrefix: nil, parsesToolCalls: true)
                == CBv2StopStringScope(excluding: [
                    .init(opener: "<|channel>", closers: ["<channel|>"]),
                    .init(opener: "<|tool_call>", closers: ["<tool_call|>"]),
                ]))
    }

    @Test("without declared tools a literal tool tag in an answer is text, so stops still apply")
    func toolTagsWithoutTools() {
        let qwen = ReasoningStopScope.scope(reasoningParser: .qwen3, reasoningPrefix: nil, parsesToolCalls: false)
        #expect(qwen == CBv2StopStringScope(excluding: [ReasoningStopScope.think]))
        #expect(
            run("Use the <tool_call> tag. Close it. Done.", stops: ["."], scope: qwen)
                == "Use the <tool_call> tag")
        let gemma = ReasoningStopScope.scope(reasoningParser: .gemma4, reasoningPrefix: nil, parsesToolCalls: false)
        #expect(gemma == CBv2StopStringScope(excluding: [ReasoningStopScope.gemmaThought]))
        #expect(
            run("Use the <|tool_call> tag. Close it. Done.", stops: ["."], scope: gemma)
                == "Use the <|tool_call> tag")
        // Reasoning still never matches, with or without tools.
        #expect(
            run("<think>One. Two.</think>Three. Four.", stops: ["."], scope: qwen)
                == "<think>One. Two.</think>Three")
    }

    @Test("with declared tools a stop never cuts a tool frame")
    func toolTagsWithTools() {
        let qwen = ReasoningStopScope.scope(reasoningParser: .qwen3, reasoningPrefix: nil, parsesToolCalls: true)
        #expect(
            run("<tool_call>{\"a\": \"b.c\"}</tool_call>Done. More.", stops: ["."], scope: qwen)
                == "<tool_call>{\"a\": \"b.c\"}</tool_call>Done")
    }

    @Test("Harmony keeps the model's scope; no parser keeps whole-output matching")
    func otherParsers() {
        for parser in [ReasoningParserFormat.harmony, ReasoningParserFormat.none, nil] {
            for parsesToolCalls in [true, false] {
                #expect(
                    ReasoningStopScope.scope(
                        reasoningParser: parser, reasoningPrefix: "<think>", parsesToolCalls: parsesToolCalls) == nil)
            }
        }
    }

    @Test("a stop in a Qwen thinking prompt's reasoning no longer ends the request")
    func qwenThinking() {
        // The template prefilled "<think>\n"; the model writes "\n\n" after "</think>".
        let output =
            "Capital of Australia. Canberra.\n\nKeep it short.\n</think>\n\n"
            + "The capital of Australia is Canberra.\n\nIt is in the ACT."
        let scope = ReasoningStopScope.scope(reasoningParser: .qwen3, reasoningPrefix: "<think>", parsesToolCalls: true)
        #expect(run(output, stops: ["."], scope: nil) == "Capital of Australia")
        #expect(
            run(output, stops: ["."], scope: scope)
                == "Capital of Australia. Canberra.\n\nKeep it short.\n</think>\n\n"
                + "The capital of Australia is Canberra")
        #expect(
            run(output, stops: ["\n\n"], scope: scope)
                == "Capital of Australia. Canberra.\n\nKeep it short.\n</think>\n\n"
                + "The capital of Australia is Canberra.")
    }

    @Test("a stop in a Gemma 4 thought no longer ends the request")
    func gemmaThinking() {
        let output =
            "<|channel>thought\nCapital of Australia. Canberra.\n\nKeep it short.<channel|>"
            + "The capital of Australia is Canberra.\n\nIt is in the ACT."
        let scope = ReasoningStopScope.scope(reasoningParser: .gemma4, reasoningPrefix: nil, parsesToolCalls: true)
        #expect(run(output, stops: ["."], scope: nil) == "<|channel>thought\nCapital of Australia")
        #expect(
            run(output, stops: ["\n\n"], scope: scope)
                == "<|channel>thought\nCapital of Australia. Canberra.\n\nKeep it short.<channel|>"
                + "The capital of Australia is Canberra.")
    }
}
