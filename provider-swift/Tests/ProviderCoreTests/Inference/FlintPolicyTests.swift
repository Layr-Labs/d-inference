import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("Flint request and stream policy")
struct FlintPolicyTests {
    private let stringTools: [[String: any Sendable]] = [
        [
            "type": "function",
            "function": [
                "name": "f",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "s": ["type": "string"], "v": ["type": "object"],
                    ] as [String: any Sendable],
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ]
    ]

    @Test func unsupportedControlsAndMixedOutputAreRejected() throws {
        for controls in [
            ChatTemplateControls(enableThinking: false), .init(enableThinking: true),
            .init(reasoningEffort: "none"), .init(reasoningEffort: "high"),
        ] {
            #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                try FlintRequestPolicy.validateControls(controls, modelType: "flint")
            }
        }
        func request(_ fields: String) throws -> OpenAIChatCompletionRequest {
            let data = Data(
                (#"{"model":"RecursiveSI/flint-int4","messages":[{"role":"user","content":"hello"}],"#
                    + fields + "}").utf8)
            return try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: data)
        }
        for fields in [#""reasoning":{"enabled":false}"#, #""reasoning":{"effort":"high"}"#] {
            let request = try request(fields)
            #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                try FlintRequestPolicy.validate(request, controls: .init(), modelType: "flint")
            }
        }
        // Recursive's contract: tools plus a response format get only the
        // response format (FlintResponseFormatTests covers the effective policy).
        try FlintRequestPolicy.validate(
            request(#""response_format":{"type":"json_object"},"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object"}}}]"#),
            controls: .init(), modelType: "flint")
        try FlintRequestPolicy.validateControls(.init(), modelType: "flint")
    }

    @Test func nativeKVOnlyAndExactArchitectureAdmission() throws {
        #expect(EngineV2SupportedModels.isSupported(modelType: "flint"))
        #expect(!EngineV2SupportedModels.isSupported(modelType: "flint_mtp"))
        for purpose in [EngineV2KVQuantizationPolicy.Purpose.live, .checkpoint] {
            #expect(
                try EngineV2KVQuantizationPolicy.resolve(
                    modelType: "flint", modelID: "arbitrary", environment: [:], purpose: purpose)
                    == .native)
            for value in ["balanced", "k8v8", "k8v4"] {
                #expect(throws: EngineV2KVQuantizationPolicy.Failure.flintRequiresNative) {
                    try EngineV2KVQuantizationPolicy.resolve(
                        modelType: "flint", global: value, modelID: "arbitrary", environment: [:],
                        purpose: purpose)
                }
            }
        }
    }

    @Test func reasoningExamplesAndToolValueTagsStayInTheirOwnChannels() throws {
        let frame =
            "<tool_call>f<arg_key>s</arg_key><arg_value>雪 </tool_call><think>literal</think></arg_value></tool_call>"
        let text = "<think>Example: <tool_call>never_execute</tool_call></think>" + frame
        for width in [1, 3, text.count] {
            let handler = BatchedToolStreamHandler(format: .flint, tools: nil)
            var router = NativeToolStreamRouter(
                handler: handler, requiresToolCall: true, nativePrefix: "")
            var reasoning = ""
            let chars = Array(text)
            for start in stride(from: 0, to: chars.count, by: width) {
                let events = try router.process(
                    String(chars[start ..< min(start + width, chars.count)]))
                for event in events {
                    if case .parsed(let part) = event {
                        #expect(part.content.isEmpty)
                        reasoning += part.reasoningContent ?? ""
                    }
                }
            }
            _ = try router.finishText()
            let calls = handler.finish()
            #expect(calls.count == 1 && calls.first?.function.name == "f")
            #expect(
                calls.first?.function.arguments["s"]
                    == .string("雪 </tool_call><think>literal</think>"))
            #expect(reasoning == "Example: <tool_call>never_execute</tool_call>")
        }
    }

    @Test func rawThinkingEvidenceCannotBeDiscardedByPermissiveDecoding() throws {
        for fields in [
            #""enable_thinking":"false""#, #""enable_thinking":null"#,
            #""reasoning_effort":"   ""#, #""reasoning_effort":false"#,
            #""preserve_thinking":false"#, #""preserve_thinking":null"#,
            #""chat_template_kwargs":{"thinking":false}"#,
            #""chat_template_kwargs":{"thinking":true}"#,
            #""chat_template_kwargs":{"enable_thinking":0}"#,
            #""chat_template_kwargs":{"reasoning_effort":"high"}"#,
            #""reasoning":{"enabled":"false"}"#,
            #""reasoning":{"effort":null}"#,
        ] {
            let controls = try JSONDecoder().decode(
                ChatTemplateControls.self, from: Data(("{" + fields + "}").utf8))
            #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                try FlintRequestPolicy.validateControls(controls, modelType: "flint")
            }
            // The new refusal must not extend to another family's controls.
            try FlintRequestPolicy.validateControls(controls, modelType: "qwen3_5")
            try FlintRequestPolicy.validateControls(controls, modelType: nil)
        }
        var responseThinking = MiMoV26RawControlEvidence()
        responseThinking.responseEnableThinking = false
        var responseEffort = MiMoV26RawControlEvidence()
        responseEffort.responseEffortDisablesThinking = false
        for evidence in [responseThinking, responseEffort] {
            #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                try FlintRequestPolicy.validateControls(
                    .init().withRawMiMoControls(evidence), modelType: "flint")
            }
        }
        let mediaOnly = try JSONDecoder().decode(
            ChatTemplateControls.self, from: Data(#"{"logprobs":true}"#.utf8))
        try FlintRequestPolicy.validateControls(mediaOnly, modelType: "flint")
    }

    @Test func rawStringsAndJSONRemainOpaqueToReasoningAtEverySplit() throws {
        for raw in [
            "{", " [todo\n", "\t{雪 </tool_call><think>literal</think>  ", " [\"unterminated",
        ] {
            let frame =
                "<tool_call>f<arg_key>s</arg_key><arg_value>\(raw)</arg_value>"
                + #"<arg_key>v</arg_key><arg_value>{"tag":"</arg_value></tool_call><think>literal"}</arg_value></tool_call>"#
            let text = "<think>thought</think>" + frame + "<think>after</think>"
            let scalars = Array(text.unicodeScalars)
            for split in 0 ... scalars.count {
                let handler = BatchedToolStreamHandler(format: .flint, tools: stringTools)
                var router = NativeToolStreamRouter(
                    handler: handler, requiresToolCall: true,
                    nativePrefix: "", tools: stringTools)
                var reasoning = ""
                for part in [scalars[..<split], scalars[split...]] {
                    for event in try router.process(String(String.UnicodeScalarView(part))) {
                        if case .parsed(let value) = event {
                            #expect(value.content.isEmpty)
                            reasoning += value.reasoningContent ?? ""
                        }
                    }
                }
                _ = try router.finishText()
                let calls = handler.finish()
                #expect(calls.count == 1)
                #expect(calls.first?.function.arguments["s"] == .string(raw))
                #expect(
                    calls.first?.function.arguments["v"]
                        == .object(["tag": .string("</arg_value></tool_call><think>literal")]))
                #expect(reasoning == "thoughtafter")
                #expect(handler.parseFailureCount == 0)
            }
        }
    }

    @Test func malformedAndIncompleteFramesFailClosedInAutoAndForcedModes() throws {
        let complete =
            "<tool_call>f<arg_key>s</arg_key><arg_value> [raw </arg_value> tail</arg_value></tool_call>"
        let incomplete = "<tool_call>f<arg_key>s</arg_key><arg_value> {unclosed"
        for required in [false, true] {
            for frame in [complete, incomplete] {
                for width in [1, 3, frame.count] {
                    let handler = BatchedToolStreamHandler(format: .flint, tools: stringTools)
                    var router = NativeToolStreamRouter(
                        handler: handler, requiresToolCall: required,
                        nativePrefix: "", tools: stringTools)
                    let chars = Array(frame)
                    #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                        for offset in stride(from: 0, to: chars.count, by: width) {
                            let events = try router.process(
                                String(chars[offset ..< min(offset + width, chars.count)]))
                            #expect(events.isEmpty)
                        }
                        _ = try router.finishText()
                    }
                    #expect(handler.finish().isEmpty)
                    #expect(handler.parseFailureCount > 0)
                }
            }
        }
    }

    @Test func historicalRawDelimiterIsRejectedButNestedJSONDelimiterIsAllowed() throws {
        for arguments in [#"{"s":"[before </arg_value> after"}"#, #"{"v":{"s":"</arg_value>"}}"#] {
            let body: [String: Any] = [
                "model": "RecursiveSI/flint-int4",
                "messages": [
                    [
                        "role": "assistant",
                        "tool_calls": [
                            [
                                "id": "call_1", "type": "function",
                                "function": [
                                    "name": "f", "arguments": arguments,
                                ],
                            ]
                        ],
                    ]
                ],
            ]
            let request = try JSONDecoder().decode(
                OpenAIChatCompletionRequest.self,
                from: JSONSerialization.data(withJSONObject: body))
            if arguments.hasPrefix(#"{"s""#) {
                #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                    try FlintRequestPolicy.validate(request, controls: .init(), modelType: "flint")
                }
            } else {
                try FlintRequestPolicy.validate(request, controls: .init(), modelType: "flint")
            }
            try FlintRequestPolicy.validate(request, controls: .init(), modelType: "qwen3_5")
        }
    }

    @Test func flintStructuredAdmissionRequiresCanonicalArchitecture() throws {
        for type in ["Flint", " flint ", "flint_mtp"] {
            #expect(!ToolChoiceEnforcementPolicy.nativeStructuredTarget(.init(modelType: type)))
        }
        #expect(ToolChoiceEnforcementPolicy.nativeStructuredTarget(.init(modelType: "flint")))
    }
}
