// Copyright © 2026 Eigen Labs.

import Foundation
import Jinja
import Testing
@testable import ProviderCoreFoundation

/// A JSON null in an earlier tool call's arguments, or in a tool's parameter
/// schema, must reach the model as `null`. The blocks below are copied
/// verbatim from the served templates and rendered through the same
/// normalization (`normalizeSwiftJinjaTemplate`) and sanitizer the runtime uses.
struct ToolArgumentNullRenderTests {
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
                    "name": "clear_project_deadline",
                    "arguments": [
                        "deadline": NSNull(),
                        "owner": "ops",
                        "labels": ["a", NSNull()] as [Any],
                    ] as [String: Any],
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

    private func render(_ source: String, _ context: [String: Value], modelType: String? = nil) throws -> String {
        var full = context
        for (key, value) in HFTemplateFilters.bindingContext(modelType: modelType, environment: [:]) ?? [:] {
            full[key] = try Value(any: value)
        }
        let template = try Template(
            HFTemplateFilters.bindingFilters(
                in: normalizeSwiftJinjaTemplate(source), modelType: modelType, environment: [:]),
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
        #expect(arguments["owner"] as? String == "ops")
        let labels = try #require(arguments["labels"] as? [Any])
        #expect(labels.count == 2)
        #expect(labels[1] as? Value == .null)
        #expect(throws: Never.self) { try Value(any: message) }
    }

    @Test func parameterSchemaKeepsNullsAndToolMetadataDropsThem() throws {
        let tool = try #require(sanitizeToolForJinja(Self.tool) as? [String: Any])
        let function = try #require(tool["function"] as? [String: Any])
        #expect(function["description"] == nil)
        let unit = try #require(
            ((function["parameters"] as? [String: Any])?["properties"] as? [String: Any])?["unit"] as? [String: Any])
        #expect((unit["enum"] as? [Any])?.count == 3)
        #expect(unit["default"] as? Value == .null)
        #expect(throws: Never.self) { try Value(any: tool) }
    }

    @Test func stringArgumentsAndMessagesWithoutCallsAreUnchanged() throws {
        let plain: [String: Any] = ["role": "user", "content": "hi", "name": NSNull()]
        let sanitized = try #require(sanitizeMessageForJinja(plain) as? [String: Any])
        #expect(sanitized.count == 2)
        let raw: [String: Any] = [
            "role": "assistant",
            "tool_calls": [["function": ["name": "f", "arguments": "{\"a\":1}"]]],
        ]
        let call = try #require(
            ((sanitizeMessageForJinja(raw) as? [String: Any])?["tool_calls"] as? [Any])?.first as? [String: Any])
        #expect((call["function"] as? [String: Any])?["arguments"] as? String == "{\"a\":1}")
    }

    // MARK: - Served templates

    /// Gemma 4 (`gemma-4-26b-a4b-it-qat-4bit`): `format_argument` and the
    /// assistant tool-call block.
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
        {%- for tool in tools -%}enum:{{ format_argument(tool['function']['parameters']['properties']['unit']['enum']) }}{%- endfor -%}
        """#

    @Test func gemmaRendersNullArgumentsAndEnumMembers() throws {
        let source = Self.gemmaCall
        let rendered = try render(source, [
            "messages": try messages(),
            "tools": .array([try Value(any: sanitizeToolForJinja(Self.tool))]),
        ], modelType: "gemma4")
        #expect(rendered.contains(
            #"<|tool_call>call:clear_project_deadline{deadline:null,labels:[<|"|>a<|"|>,null],owner:<|"|>ops<|"|>}<tool_call|>"#),
            "\(rendered)")
        #expect(rendered.contains(#"enum:[<|"|>celsius<|"|>,<|"|>fahrenheit<|"|>,null]"#), "\(rendered)")
    }

    /// Qwen 3.5 / 3.6 (Qwen3.5-9B) and Nemotron 3.5 Lightning: the XML parameter value.
    private static let qwenXMLCall = #"""
        {%- for message in messages -%}
        {%- for tool_call in message.tool_calls -%}
        {%- set tool_call = tool_call.function -%}
        {{- '<function=' + tool_call.name + '>\n' }}
        {%- for args_name, args_value in tool_call.arguments|items -%}
        {{- '<parameter=' + args_name + '>\n' }}
        {%- set args_value = args_value | tojson | safe if args_value is mapping or (args_value is sequence and args_value is not string) else args_value | string %}
        {{- args_value }}
        {{- '\n</parameter>\n' }}
        {%- endfor -%}
        {%- endfor -%}
        {%- endfor -%}
        """#

    @Test(arguments: ["qwen3_5", "qwen3_5_moe", "nemotron_h"])
    func qwenXMLRendersNullParameters(modelType: String) throws {
        let rendered = try render(Self.qwenXMLCall, ["messages": try messages()], modelType: modelType)
        #expect(rendered.contains("<parameter=deadline>\nnull\n</parameter>"), "\(rendered)")
        #expect(rendered.contains("<parameter=labels>\n[\"a\",null]\n</parameter>")
            || rendered.contains("<parameter=labels>\n[\"a\", null]\n</parameter>"), "\(rendered)")
        #expect(rendered.contains("<parameter=owner>\nops\n</parameter>"), "\(rendered)")
    }

    /// Qwen 3.8 27B: non-string values are written with `tojson`.
    @Test func qwen38RendersNullParameters() throws {
        let source = #"""
            {%- for message in messages -%}{%- for tool_call in message.tool_calls -%}{%- set tool_call = tool_call.function -%}
            {%- for args_name, args_value in tool_call.arguments|items -%}
            {%- set args_value = args_value | string if args_value is string else args_value | tojson | safe %}
            {{- args_name + '=' + args_value + ';' }}
            {%- endfor -%}{%- endfor -%}{%- endfor -%}
            """#
        let rendered = try render(source, ["messages": try messages()], modelType: "qwen3_5")
        #expect(rendered.contains("deadline=null;"), "\(rendered)")
    }

    /// GPT-OSS (harmony fixture): `tool_call.arguments|tojson`.
    @Test func gptOSSRendersNullArguments() throws {
        let source = "{%- for message in messages -%}{%- for tool_call in message.tool_calls -%}{{- tool_call.function.arguments|tojson }}{%- endfor -%}{%- endfor -%}"
        let rendered = try render(source, ["messages": try messages()], modelType: "gpt_oss")
        #expect(rendered.contains(#""deadline":null"#) || rendered.contains(#""deadline": null"#), "\(rendered)")
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
        let rendered = try Template(normalizeSwiftJinjaTemplate(source), with: .init(lstripBlocks: true, trimBlocks: true))
            .render(context)
        #expect(rendered.contains(#""deadline":null"#), "\(rendered)")
    }

    // MARK: - Unchanged bytes

    /// Without a null, the rewritten blocks render byte for byte as served.
    @Test func templatesWithoutNullsRenderAsServed() throws {
        let turn: [String: Any] = [
            "role": "assistant",
            "tool_calls": [["function": ["name": "f", "arguments": ["a": 1, "b": "x", "c": true, "d": [1, 2]]]]],
        ]
        let context: [String: Value] = ["messages": .array([try Value(any: sanitizeMessageForJinja(turn))]), "tools": .array([])]
        for (source, modelType) in [(Self.gemmaCall, "gemma4"), (Self.qwenXMLCall, "qwen3_5")] {
            let served = try Template(
                HFTemplateFilters.bindingFilters(in: source, modelType: modelType, environment: [:]),
                with: .init(lstripBlocks: true, trimBlocks: true))
            var full = context
            for (key, value) in HFTemplateFilters.bindingContext(modelType: modelType, environment: [:]) ?? [:] {
                full[key] = try Value(any: value)
            }
            #expect(try served.render(full) == render(source, context, modelType: modelType))
        }
    }

    @Test func rewritesMatchTheServedBlocksOnce() {
        let gemma = Self.gemmaCall
        #expect(renderingToolArgumentNulls(gemma).components(separatedBy: "argument is none").count == 2)
        #expect(renderingToolArgumentNulls(Self.qwenXMLCall).components(separatedBy: "args_value is none").count == 2)
        #expect(renderingToolArgumentNulls("{{ x }}") == "{{ x }}")
    }
}
