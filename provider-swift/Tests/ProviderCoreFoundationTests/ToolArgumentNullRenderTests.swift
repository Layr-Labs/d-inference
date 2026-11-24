// Copyright © 2026 Eigen Labs.

import Foundation
import Jinja
import Testing
@testable import ProviderCoreFoundation

/// A JSON null in an earlier tool call's arguments must reach the model as
/// `null`, at the key or array position where the call had it; nulls in a
/// tool's parameter schema keep the drop policy. The template blocks below are
/// copied verbatim from the served templates and rendered through the same
/// rewrites, normalization and sanitizer the serving tokenizer uses.
struct ToolArgumentNullRenderTests {
    /// The decoded arguments of the earlier call: a top-level null, a null map
    /// value under a key that is not an identifier, a deep object member, array
    /// elements (positions kept, a trailing one included) and an object inside
    /// an array.
    private static var arguments: [String: Any] { [
        "deadline": NSNull(),
        "flags": ["dark-mode": NSNull()] as [String: Any],
        "entry": ["details": ["profile": ["nickname": NSNull()] as [String: Any]] as [String: Any]] as [String: Any],
        "rows": [[false, "Total", -150] as [Any], NSNull()] as [Any],
        "payload": ["data": [NSNull(), [:] as [String: Any]] as [Any]] as [String: Any],
        "sheet": ["rows": [["Coupon Code": NSNull(), "qty": 2] as [String: Any]] as [Any]] as [String: Any],
        "owner": "ops",
    ] }

    /// An assistant turn as `templateMessageDict` builds it, with `content`
    /// null and a call whose decoded arguments carry nulls.
    private static var assistantTurn: [String: Any] { [
        "role": "assistant",
        "content": NSNull(),
        "tool_calls": [
            [
                "id": "call_0",
                "type": "function",
                "function": [
                    "name": "update_record",
                    "arguments": arguments,
                ] as [String: Any],
            ] as [String: Any]
        ] as [Any],
    ] }

    private static var tool: [String: Any] { [
        "type": "function",
        "function": [
            "name": "set_unit",
            "description": NSNull(),
            "parameters": [
                "type": "object",
                "properties": [
                    "unit": [
                        "type": "string",
                        "enum": ["celsius", "fahrenheit", NSNull()] as [Any],
                        "default": NSNull(),
                    ] as [String: Any]
                ] as [String: Any],
            ] as [String: Any],
        ] as [String: Any],
    ] }

    /// The serving tokenizer's compile path (`LocalTokenizerLoader`).
    private func render(_ source: String, _ context: [String: Value], modelType: String? = nil) throws -> String {
        var full = context
        for (key, value) in HFTemplateFilters.bindingContext(modelType: modelType, environment: [:]) ?? [:] {
            full[key] = try Value(any: value)
        }
        let template = try Template(
            HFTemplateFilters.bindingFilters(
                in: normalizeSwiftJinjaTemplate(renderingToolArgumentNulls(source)),
                modelType: modelType, environment: [:]),
            with: .init(lstripBlocks: true, trimBlocks: true))
        return try template.render(full)
    }

    private func messages() throws -> Value {
        .array([try Value(any: sanitizeMessageForJinja(Self.assistantTurn))])
    }

    // MARK: - Sanitizer

    @Test func callArgumentsKeepNullsAndOtherFieldsDropThem() throws {
        let message = try #require(sanitizeMessageForJinja(Self.assistantTurn) as? [String: Any])
        #expect(message["content"] == nil)
        let call = try #require((message["tool_calls"] as? [Any])?.first as? [String: Any])
        let function = try #require(call["function"] as? [String: Any])
        let arguments = try #require(function["arguments"] as? [String: Any])
        #expect(arguments["deadline"] as? Value == .null)
        #expect((arguments["flags"] as? [String: Any])?["dark-mode"] as? Value == .null)
        let rows = try #require(arguments["rows"] as? [Any])
        try #require(rows.count == 2)
        #expect(rows[1] as? Value == .null)
        let data = try #require((arguments["payload"] as? [String: Any])?["data"] as? [Any])
        try #require(data.count == 2)
        #expect(data[0] as? Value == .null)
        #expect(arguments["owner"] as? String == "ops")
        #expect(throws: Never.self) { try Value(any: message) }
    }

    @Test func parameterSchemaNullsAreStillDropped() throws {
        let tool = try #require(sanitizeForJinja(Self.tool) as? [String: Any])
        let unit = try #require(
            (((tool["function"] as? [String: Any])?["parameters"] as? [String: Any])?["properties"] as? [String: Any])?["unit"]
                as? [String: Any])
        #expect((unit["enum"] as? [Any])?.count == 2)
        #expect(unit["default"] == nil)
    }

    @Test func stringArgumentsAndMessagesWithoutCallsAreUnchanged() throws {
        let plain: [String: Any] = ["role": "user", "content": "hi", "name": NSNull()]
        let sanitized = try #require(sanitizeMessageForJinja(plain) as? [String: Any])
        #expect(sanitized.count == 2)
        let raw: [String: Any] = [
            "role": "assistant",
            "tool_calls": [["function": ["name": "f", "arguments": "{\"a\":null}"]]],
        ]
        let call = try #require(
            ((sanitizeMessageForJinja(raw) as? [String: Any])?["tool_calls"] as? [Any])?.first as? [String: Any])
        #expect((call["function"] as? [String: Any])?["arguments"] as? String == "{\"a\":null}")
    }

    // MARK: - Which requests carry a history null

    @Test(arguments: [
        #"{"deadline":null}"#,
        #"{"flags":{"dark-mode":null}}"#,
        #"{"entry":{"details":{"profile":{"nickname":null}}}}"#,
        #"{"rows":[[false,"Total",-150],null]}"#,
        #"{"payload":{"data":[null,{}]}}"#,
        #"{"sheet":{"rows":[{"Coupon Code":null}]}}"#,
        " { \"a\" : null } ",
    ])
    func argumentsWithANullAnywhereCarryOne(arguments: String) {
        #expect(toolCallArgumentsCarryNull(arguments))
    }

    /// No null, a bare `null` or array (not an object, so the template sees
    /// the string), the text "null", or a body that is not JSON: the template
    /// input is the same as before.
    @Test(arguments: [
        #"{}"#, "", "  ", #"{"a":1,"b":"null","c":[1,{"d":false}]}"#, "null", "[null]", #"{"a":nul"#, "not json",
    ])
    func otherArgumentsCarryNone(arguments: String) {
        #expect(!toolCallArgumentsCarryNull(arguments))
    }

    // MARK: - Served templates

    /// Gemma 4 (`gemma-4-26b-a4b-it-qat-4bit`, `-8bit`): `format_argument` and
    /// the assistant tool-call block. Keys are written unescaped.
    private static let gemmaCall = #"""
        {%- macro format_argument(argument, escape_keys=True) -%}
            {%- if argument is string -%}
                {{- '<|"|>' + argument + '<|"|>' -}}
            {%- elif argument is boolean -%}
                {{- 'true' if argument else 'false' -}}
            {%- elif argument is mapping -%}
                {{- '{' -}}
                {%- set ns = namespace(found_first=false) -%}
                {%- for key, value in argument | dictsort -%}
                    {%- if ns.found_first %},{% endif -%}
                    {%- set ns.found_first = true -%}
                    {%- if escape_keys -%}
                        {{- '<|"|>' + key + '<|"|>' -}}
                    {%- else -%}
                        {{- key -}}
                    {%- endif -%}
                    :{{- format_argument(value, escape_keys=escape_keys) -}}
                {%- endfor -%}
                {{- '}' -}}
            {%- elif argument is sequence -%}
                {{- '[' -}}
                {%- for item in argument -%}
                    {{- format_argument(item, escape_keys=escape_keys) -}}
                    {%- if not loop.last %},{% endif -%}
                {%- endfor -%}
                {{- ']' -}}
            {%- else -%}
                {{- argument -}}
            {%- endif -%}
        {%- endmacro -%}
        {%- for message in messages -%}
                    {%- for tool_call in message['tool_calls'] -%}
                        {%- set function = tool_call['function'] -%}
                        {{- '<|tool_call>call:' + function['name'] + '{' -}}
                        {%- if function['arguments'] is mapping -%}
                            {%- set ns_args = namespace(found_first=false) -%}
                            {%- for key, value in function['arguments'] | dictsort -%}
                                {%- if ns_args.found_first %},{% endif -%}
                                {%- set ns_args.found_first = true -%}
                                {{- key -}}:{{- format_argument(value, escape_keys=False) -}}
                            {%- endfor -%}
                        {%- elif function['arguments'] is string -%}
                            {{- function['arguments'] -}}
                        {%- endif -%}
                        {{- '}<tool_call|>' -}}
                    {%- endfor -%}
        {%- endfor -%}
        """#

    @Test func gemmaRendersNullArguments() throws {
        let rendered = try render(Self.gemmaCall, ["messages": try messages()], modelType: "gemma4")
        let q = #"<|"|>"#
        let expected = "<|tool_call>call:update_record{deadline:null,entry:{details:{profile:{nickname:null}}},"
            + "flags:{dark-mode:null},owner:\(q)ops\(q),payload:{data:[null,{}]},"
            + "rows:[[false,\(q)Total\(q),-150],null],sheet:{rows:[{Coupon Code:null,qty:2}]}}<tool_call|>"
        #expect(rendered.contains(expected), "\(rendered)")
    }

    /// Qwen 3.5 (`Qwen3.5-9B`, `qwen3.5-35b-a3b`) and Nemotron 3.5 Lightning:
    /// the XML parameter value.
    private static let qwenXMLCall = #"""
        {%- set content = '' %}
        {%- for message in messages %}
                {%- if message.tool_calls and message.tool_calls is iterable and message.tool_calls is not mapping %}
                    {%- for tool_call in message.tool_calls %}
                        {%- if tool_call.function is defined %}
                            {%- set tool_call = tool_call.function %}
                        {%- endif %}
                        {%- if loop.first %}
                            {%- if content|trim %}
                                {{- '\n\n<tool_call>\n<function=' + tool_call.name + '>\n' }}
                            {%- else %}
                                {{- '<tool_call>\n<function=' + tool_call.name + '>\n' }}
                            {%- endif %}
                        {%- else %}
                            {{- '\n<tool_call>\n<function=' + tool_call.name + '>\n' }}
                        {%- endif %}
                        {%- if tool_call.arguments is defined %}
                            {%- for args_name, args_value in tool_call.arguments|items %}
                                {{- '<parameter=' + args_name + '>\n' }}
                                {%- set args_value = args_value | tojson | safe if args_value is mapping or (args_value is sequence and args_value is not string) else args_value | string %}
                                {{- args_value }}
                                {{- '\n</parameter>\n' }}
                            {%- endfor %}
                        {%- endif %}
                        {{- '</function>\n</tool_call>' }}
                    {%- endfor %}
                {%- endif %}
        {%- endfor %}
        """#

    private func compactJSON(_ text: String) -> String {
        text.replacingOccurrences(of: ", ", with: ",").replacingOccurrences(of: ": ", with: ":")
    }

    @Test(arguments: ["qwen3_5", "qwen3_5_moe", "nemotron_h"])
    func qwenXMLRendersNullParameters(modelType: String) throws {
        let rendered = compactJSON(try render(Self.qwenXMLCall, ["messages": try messages()], modelType: modelType))
        #expect(rendered.contains("<parameter=deadline>\nnull\n</parameter>"), "\(rendered)")
        #expect(rendered.contains("<parameter=flags>\n{\"dark-mode\":null}\n</parameter>"), "\(rendered)")
        #expect(rendered.contains("<parameter=rows>\n[[false,\"Total\",-150],null]\n</parameter>"), "\(rendered)")
        #expect(rendered.contains("<parameter=payload>\n{\"data\":[null,{}]}\n</parameter>"), "\(rendered)")
        #expect(rendered.contains("<parameter=owner>\nops\n</parameter>"), "\(rendered)")
    }

    /// Qwen 3.6 (`qwen3.6-35b-a3b-vl-mtp-mxfp8`) and Qwen 3.8 27B: non-string
    /// values are written with `tojson`.
    @Test(arguments: [
        ("qwen3_5_moe", "{%- if tool_call.arguments is defined %}"),
        ("qwen4_exp", "{%- if tool_call.arguments is defined and tool_call.arguments != '' %}"),
    ])
    func qwenTojsonRendersNullParameters(modelType: String, guardLine: String) throws {
        let source = """
            {%- for message in messages -%}{%- for tool_call in message.tool_calls -%}{%- set tool_call = tool_call.function -%}
            \(guardLine)
            {%- for args_name, args_value in tool_call.arguments|items %}
            {%- set args_value = args_value | string if args_value is string else args_value | tojson | safe %}
            {{- args_name + '=' + args_value + ';' }}
            {%- endfor %}{%- endif %}{%- endfor -%}{%- endfor -%}
            """
        let rendered = compactJSON(try render(source, ["messages": try messages()], modelType: modelType))
        #expect(rendered.contains("deadline=null;"), "\(rendered)")
        #expect(rendered.contains(#"entry={"details":{"profile":{"nickname":null}}};"#), "\(rendered)")
        #expect(rendered.contains(#"sheet={"rows":[{"Coupon Code":null,"qty":2}]};"#), "\(rendered)")
    }

    /// GPT-OSS (`gpt-oss-20b`): `tool_call.arguments|tojson`.
    @Test func gptOSSRendersNullArguments() throws {
        let source = "{%- for message in messages -%}{%- for tool_call in message.tool_calls -%}{%- set tool_call = tool_call.function -%}{{- tool_call.arguments|tojson }}{%- endfor -%}{%- endfor -%}"
        let rendered = compactJSON(try render(source, ["messages": try messages()], modelType: "gpt_oss"))
        #expect(rendered.contains(#""deadline":null"#), "\(rendered)")
        #expect(rendered.contains(#""rows":[[false,"Total",-150],null]"#), "\(rendered)")
    }

    /// Inkling 2 (fixture): each value with Transformers' `tojson`.
    @Test func inklingRendersNullArguments() throws {
        let source = #"""
            {%- for message in messages -%}{%- for tool_call in message.tool_calls -%}{%- set args = tool_call.function.arguments -%}
            {%- for key, value in args | dictsort(case_sensitive=true) -%}{{- (key | tojson) ~ ":" ~ (value | tojson(separators=(",", ":"))) -}}{%- if not loop.last -%},{%- endif -%}{%- endfor -%}
            {%- endfor -%}{%- endfor -%}
            """#
        var context: [String: Value] = ["messages": try messages()]
        for (key, value) in HFTemplateFilters.requestContext() { context[key] = try Value(any: value) }
        let rendered = try Template(
            normalizeSwiftJinjaTemplate(renderingToolArgumentNulls(source)), with: .init(lstripBlocks: true, trimBlocks: true)
        ).render(context)
        #expect(rendered.contains(#""deadline":null"#), "\(rendered)")
        #expect(rendered.contains(#""payload":{"data":[null,{}]}"#), "\(rendered)")
    }

    // MARK: - Unchanged bytes

    /// Without a null, the rewritten blocks render byte for byte as served.
    @Test func templatesWithoutNullsRenderAsServed() throws {
        let turn: [String: Any] = [
            "role": "assistant",
            "tool_calls": [["function": ["name": "f", "arguments": ["a": 1, "b": "x", "c": true, "d": [1, 2], "e": ["f": "g"]]]]],
        ]
        let context: [String: Value] = ["messages": .array([try Value(any: sanitizeMessageForJinja(turn))]), "tools": .array([])]
        for (source, modelType) in [(Self.gemmaCall, "gemma4"), (Self.qwenXMLCall, "qwen3_5"), (Self.qwenXMLCall, "nemotron_h")] {
            let served = try Template(
                HFTemplateFilters.bindingFilters(in: normalizeSwiftJinjaTemplate(source), modelType: modelType, environment: [:]),
                with: .init(lstripBlocks: true, trimBlocks: true))
            var full = context
            for (key, value) in HFTemplateFilters.bindingContext(modelType: modelType, environment: [:]) ?? [:] {
                full[key] = try Value(any: value)
            }
            #expect(try served.render(full) == render(source, context, modelType: modelType))
        }
    }

    @Test func rewritesMatchTheServedBlocksOnceAndAreIdempotent() {
        let gemma = renderingToolArgumentNulls(Self.gemmaCall)
        #expect(gemma.components(separatedBy: "argument is none").count == 2)
        #expect(renderingToolArgumentNulls(gemma) == gemma)
        let qwen = renderingToolArgumentNulls(Self.qwenXMLCall)
        #expect(qwen.components(separatedBy: "args_value is none").count == 2)
        #expect(renderingToolArgumentNulls(qwen) == qwen)
        #expect(renderingToolArgumentNulls("{{ x }}") == "{{ x }}")
        // Only the shared path applies them: the plain normalization (used by
        // the managed Nemotron Super contract) leaves the blocks as served.
        #expect(!normalizeSwiftJinjaTemplate(Self.qwenXMLCall).contains("args_value is none"))
    }
}
