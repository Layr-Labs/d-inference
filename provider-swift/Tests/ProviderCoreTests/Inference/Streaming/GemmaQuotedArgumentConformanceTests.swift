// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("Gemma quoted numeric argument conformance")
struct GemmaQuotedArgumentConformanceTests {
    private let enabled = ProcessInfo.processInfo.environment["DARKBLOOM_GEMMA_SCHEMA_COERCION"] == "1"

    @Test("strict validation sees the completed numeric conversion", arguments: [false, true])
    func validatesCompletedCall(stream: Bool) throws {
        let (prepared, handler) = try setup(schema: #"{"type":"integer"}"#, stream: stream)
        let frame = #"<|tool_call>call:count_items{count:<|"|>3<|"|>}<tool_call|>"#
        func streamedCalls() throws -> [ToolCall] {
            var router = NativeToolStreamRouter(handler: handler, requiresToolCall: false, nativePrefix: nil,
                streamedCalls: prepared)
            var events: [MLXServerGenerationEvent] = []
            for character in frame { events += try router.process(String(character)) }
            events += try router.finishText()
            events += try router.finishToolCalls(truncated: false)
            let deltas = events.compactMap { if case .toolCallDelta(let delta) = $0 { delta } else { nil } }
            let completed = try #require(deltas.last?.completed)
            let json = Data(deltas.map(\.arguments).joined().utf8)
            #expect(try JSONDecoder().decode([String: MLXLMCommon.JSONValue].self, from: json)
                == completed.function.arguments)
            return router.completedToolCalls
        }
        if stream && !enabled {
            #expect(throws: MultiModelBatchSchedulerEngineError.toolChoiceViolation(ToolNoncomplianceCheck.schemaViolation)) {
                _ = try streamedCalls()
            }
            return
        }
        let calls: [ToolCall]
        if stream {
            calls = try streamedCalls()
        } else {
            _ = handler.processChunk(frame)
            calls = handler.finish()
        }
        #expect(calls.count == 1)
        #expect(calls.first?.function.arguments["count"] == (enabled ? .int(3) : .string("3")))
        if enabled {
            try ToolConstraintValidation.validate(calls, prepared: prepared)
        } else {
            #expect(throws: MultiModelBatchSchedulerEngineError.toolChoiceViolation(ToolNoncomplianceCheck.schemaViolation)) {
                try ToolConstraintValidation.validate(calls, prepared: prepared)
            }
        }
    }

    @Test("render types do not erase caller-admitted strings", arguments: [false, true])
    func unionStrings(stream: Bool) throws {
        for schema in [
            #"{"anyOf":[{"type":"integer"},{"type":"string"}]}"#,
            #"{"anyOf":[{"type":"string"},{"type":"integer"}]}"#,
            #"{"type":["integer","string"]}"#,
            #"{"type":["string","integer"]}"#,
        ] {
            let (prepared, handler) = try setup(schema: schema, stream: stream)
            let frame = #"<|tool_call>call:count_items{count:<|"|>003<|"|>}<tool_call|>"#
            let calls: [ToolCall]
            if stream {
                var router = NativeToolStreamRouter(handler: handler, requiresToolCall: false, nativePrefix: nil,
                    streamedCalls: prepared)
                for character in frame { _ = try router.process(String(character)) }
                _ = try router.finishText()
                _ = try router.finishToolCalls(truncated: false)
                calls = router.completedToolCalls
            } else {
                _ = handler.processChunk(frame)
                calls = handler.finish()
            }
            #expect(calls.count == 1)
            #expect(calls.first?.function.arguments["count"] == .string("003"))
            try ToolConstraintValidation.validate(calls, prepared: prepared)
        }
    }

    @Test("invalid numeric text fails before completed-call exposure")
    func rejectsFractionBeforeResponseStarts() throws {
        let (prepared, handler) = try setup(schema: #"{"type":"integer"}"#, stream: true)
        var router = NativeToolStreamRouter(handler: handler, requiresToolCall: false, nativePrefix: nil,
            streamedCalls: prepared)
        // Deliberately leave responseStarted false: post-start leniency is a separate policy.
        let before = try router.process(#"<|tool_call>call:count_items{count:<|"|>3.5<|"|>}"#)
        for event in before {
            if case .toolCallDelta(let delta) = event {
                #expect(delta.completed == nil)
                if enabled { #expect(delta.arguments.isEmpty) }
            }
        }
        #expect(throws: MultiModelBatchSchedulerEngineError.toolChoiceViolation(ToolNoncomplianceCheck.schemaViolation)) {
            _ = try router.process("<tool_call|>")
        }
        #expect(router.completedToolCalls.isEmpty)
    }

    private func setup(schema: String, stream: Bool) throws
        -> (ToolChoicePromptPolicy.Prepared, BatchedToolStreamHandler) {
        let body = Data("""
            {"model":"gemma-4-26b-qat-4bit","messages":[{"role":"user","content":"Count it."}],"stream":true,
             "tools":[{"type":"function","function":{"name":"count_items","strict":true,"parameters":{
               "type":"object","properties":{"count":\(schema)},"required":["count"],"additionalProperties":false}}}]}
            """.utf8)
        var request = try ProviderLoop.decodeOpenAIRequest(body)
        request.streamToolCallDeltas = stream
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "gemma4")
        let handler = try #require(try ToolStreamPreparation.makeHandler(
            request: request, prepared: prepared, modelType: "gemma4", streamToolCalls: stream))
        return (prepared, handler)
    }
}
