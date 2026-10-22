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

    private func chatBody(_ fields: String) -> Data {
        Data((#"{"model":"RecursiveSI/flint-int4","messages":[{"role":"user","content":"hello"}]"#
            + (fields.isEmpty ? "" : "," + fields) + "}").utf8)
    }

    private func responsesBody(_ fields: String) -> Data {
        Data((#"{"model":"RecursiveSI/flint-int4","input":"hello""#
            + (fields.isEmpty ? "" : "," + fields) + "}").utf8)
    }

    /// The production chat and Responses decodes of one control spelling.
    private func decoded(_ fields: String) throws
        -> [(request: OpenAIChatCompletionRequest, controls: ChatTemplateControls)]
    {
        let chat = try JSONDecoder().decode(LocalChatRequest.self, from: chatBody(fields))
        let responses = try JSONDecoder().decode(LocalResponseRequest.self, from: responsesBody(fields))
        return [(chat.request, chat.templateControls),
                (responses.request.chatCompletionRequest, responses.templateControls)]
    }

    /// Flint always decides whether to reason; these are accepted with no
    /// prompt effect (see FlintTemplateReplayTests).
    private static let acceptedControls = [
        #""enable_thinking":true"#, #""enable_thinking":false"#,
        #""chat_template_kwargs":{"enable_thinking":false}"#,
        #""chat_template_kwargs":{"thinking":true}"#,
        #""chat_template_kwargs":{"thinking":false,"enable_thinking":true}"#,
        #""reasoning":{"enabled":true}"#, #""reasoning":{"enabled":false}"#,
        #""reasoning":{"exclude":true}"#, #""reasoning":{"exclude":false}"#,
        #""reasoning":{"effort":"high","enabled":true,"exclude":false}"#,
        #""include_reasoning":true"#, #""include_reasoning":false"#, #""reasoning":null"#,
    ] + FlintRequestPolicy.acceptedEfforts.sorted().flatMap {
        [#""reasoning_effort":"\#($0)""#, #""reasoning":{"effort":"\#($0)"}"#]
    }

    @Test func reasoningControlsAreAcceptedButMixedOutputIsRejected() throws {
        for fields in Self.acceptedControls {
            for (request, controls) in try decoded(fields) {
                try FlintRequestPolicy.validate(request, controls: controls, modelType: "flint")
            }
        }
        for controls in [
            ChatTemplateControls(enableThinking: false), .init(enableThinking: true),
            .init(reasoningEffort: "none"), .init(reasoningEffort: "xhigh"),
        ] {
            try FlintRequestPolicy.validateControls(controls, modelType: "flint")
        }
        // Typed values outside the accepted set, without raw evidence.
        for controls in [ChatTemplateControls(reasoningEffort: "max"), .init(preserveThinking: false)] {
            #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                try FlintRequestPolicy.validateControls(controls, modelType: "flint")
            }
        }
        for fields in [#""reasoning":{"effort":"max"}"#] {
            let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: chatBody(fields))
            #expect(throws: MultiModelBatchSchedulerEngineError.self) {
                try FlintRequestPolicy.validate(request, controls: .init(), modelType: "flint")
            }
        }
        // Recursive's contract: tools plus a response format get only the
        // response format (FlintResponseFormatTests covers the effective policy).
        try FlintRequestPolicy.validate(
            JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: chatBody(
                #""response_format":{"type":"json_object"},"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object"}}}]"#)),
            controls: .init(), modelType: "flint")
        try FlintRequestPolicy.validateControls(.init(), modelType: "flint")
    }

    @Test func onlyDeclinedReasoningIsWithheldAndOnlyForExactFlint() throws {
        let cases: [(String, Bool)] = [
            (#""reasoning":{"exclude":true}"#, true), (#""include_reasoning":false"#, true),
            (#""reasoning":{"enabled":false}"#, true),
            (#""reasoning":{"enabled":true,"exclude":true}"#, true),
            (#""include_reasoning":true,"reasoning":{"enabled":false}"#, true),
            (#""reasoning":{"exclude":false}"#, false), (#""include_reasoning":true"#, false),
            (#""reasoning":{"enabled":true}"#, false),
            // Flint cannot skip reasoning; effort and template switches stay no-ops.
            (#""reasoning":{"effort":"none"}"#, false), (#""reasoning_effort":"none""#, false),
            (#""enable_thinking":false"#, false), (#""chat_template_kwargs":{"thinking":false}"#, false),
            ("", false),
        ]
        for (fields, expected) in cases {
            for (request, controls) in try decoded(fields) {
                #expect(FlintRequestPolicy.withholdsReasoning(
                    request, controls: controls, modelType: "flint") == expected, "\(fields)")
                for type in [nil, "qwen3_5", "Flint", " flint ", "flint_mtp"] as [String?] {
                    #expect(!FlintRequestPolicy.withholdsReasoning(request, controls: controls, modelType: type))
                }
            }
        }
        // The typed request alone also declines (e.g. a programmatic caller).
        let typed = OpenAIChatCompletionRequest(
            model: "RecursiveSI/flint-int4", messages: [.init(role: .user, content: .text("hi"))],
            reasoning: .init(enabled: false))
        #expect(FlintRequestPolicy.withholdsReasoning(typed, controls: .init(), modelType: "flint"))
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

    @Test func malformedEvidenceCannotBeDiscardedByPermissiveDecoding() throws {
        for fields in [
            #""enable_thinking":"false""#, #""enable_thinking":null"#,
            #""reasoning_effort":"   ""#, #""reasoning_effort":false"#,
            #""reasoning_effort":"max""#, #""reasoning_effort":"HIGH""#, #""reasoning_effort":" high""#,
            #""preserve_thinking":false"#, #""preserve_thinking":null"#,
            #""chat_template_kwargs":{"enable_thinking":0}"#,
            #""chat_template_kwargs":{"thinking":"true"}"#,
            #""chat_template_kwargs":{"reasoning_effort":"high"}"#,
            #""chat_template_kwargs":null"#,
            #""reasoning":{"enabled":"false"}"#,
            #""reasoning":{"effort":null}"#, #""reasoning":{"effort":"extreme"}"#,
            #""reasoning":{"exclude":"true"}"#, #""reasoning":{"exclude":1}"#,
            #""reasoning":{"exclude":null}"#, #""reasoning":{"max_tokens":1024}"#,
            #""reasoning":"high""#,
            #""include_reasoning":"false""#, #""include_reasoning":null"#, #""include_reasoning":0"#,
        ] {
            let controls = try JSONDecoder().decode(
                ChatTemplateControls.self, from: Data(("{" + fields + "}").utf8))
            #expect(throws: MultiModelBatchSchedulerEngineError.self, "\(fields)") {
                try FlintRequestPolicy.validateControls(controls, modelType: "flint")
            }
            // The refusal must not extend to another family's controls.
            try FlintRequestPolicy.validateControls(controls, modelType: "qwen3_5")
            try FlintRequestPolicy.validateControls(controls, modelType: nil)
            // Responses bodies carry the same evidence when their typed decode
            // accepts the field at all.
            if let responses = try? JSONDecoder().decode(
                LocalResponseRequest.self, from: responsesBody(fields)) {
                #expect(throws: MultiModelBatchSchedulerEngineError.self, "\(fields)") {
                    try FlintRequestPolicy.validateControls(responses.templateControls, modelType: "flint")
                }
            }
        }
        // Another family's control evidence is not Flint's contract.
        var responseThinking = MiMoV26RawControlEvidence()
        responseThinking.responseEnableThinking = false
        responseThinking.invalid = true
        try FlintRequestPolicy.validateControls(
            .init().withRawMiMoControls(responseThinking), modelType: "flint")
        let mediaOnly = try JSONDecoder().decode(
            ChatTemplateControls.self, from: Data(#"{"logprobs":true}"#.utf8))
        try FlintRequestPolicy.validateControls(mediaOnly, modelType: "flint")
    }

    @Test func withheldReasoningKeepsContentAndCallsAtEverySplit() throws {
        let frame = "<tool_call>f<arg_key>s</arg_key><arg_value>raw <think>x</think></arg_value></tool_call>"
        let thought = "Example: <tool_call>never_execute</tool_call>"
        let text = "<think>" + thought + "</think>Answer." + frame
        let scalars = Array(text.unicodeScalars)
        for withhold in [false, true] {
            for split in 0 ... scalars.count {
                let handler = BatchedToolStreamHandler(format: .flint, tools: stringTools)
                var router = NativeToolStreamRouter(
                    handler: handler, requiresToolCall: false, nativePrefix: "",
                    tools: stringTools, withholdReasoning: withhold)
                var reasoning = "", content = "", withheld = ""
                func collect(_ events: [MLXServerGenerationEvent]) {
                    for event in events {
                        if case .parsed(let part) = event {
                            content += part.content
                            reasoning += part.reasoningContent ?? ""
                        }
                    }
                    withheld += router.takeWithheldReasoning()
                }
                for part in [scalars[..<split], scalars[split...]] {
                    collect(try router.process(String(String.UnicodeScalarView(part))))
                }
                collect(try router.finishText())
                let calls = handler.finish()
                content += handler.takeResidualText() ?? "" // As the engine's auto-mode flush.
                #expect(calls.count == 1 && calls.first?.function.name == "f")
                #expect(calls.first?.function.arguments["s"] == .string("raw <think>x</think>"))
                #expect(content == "Answer.")
                #expect(reasoning == (withhold ? "" : thought))
                #expect(withheld == (withhold ? thought : ""))
                #expect(router.takeWithheldReasoning().isEmpty)
            }
        }
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
