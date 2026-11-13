// Copyright © 2026 Eigen Labs.

import Foundation
import Jinja
import MLXLMServer
import Testing
@testable import ProviderCore
@testable import ProviderCoreFoundation

struct TemplateJSONOrderTests {
    /// A body as a client sends it: declaration members in OpenAI's order, a
    /// `null` schema default, and an earlier call whose arguments the model
    /// wrote in its own order, with a `null`, a `1.0`, non-ASCII text and a
    /// slash.
    private static func body(asking: Bool) -> Data {
        let flag = asking ? #","_darkbloom_template_json":"transformers""# : ""
        return Data((#"""
            {"model":"m","messages":[{"role":"user","content":"Fly me"},{"role":"assistant","content":null,\#
            "tool_calls":[{"id":"call_1","type":"function","function":{"name":"search","arguments":\#
            "{\"origin\": \"IAH\", \"destination\": \"São Paulo/GRU\", \"date\": \"2024-05-19\", \"note\": null, \#
            \"n\": 1.0, \"flags\": [true, null, 2], \"pax\": {\"last\": \"Li\", \"first\": \"Mia\"}}"}}]},\#
            {"role":"tool","tool_call_id":"call_1","content":"[]"}],"tools":[{"type":"function","function":\#
            {"name":"search","description":"Search flights.","parameters":{"type":"object","properties":\#
            {"origin":{"type":"string"},"destination":{"type":"string","description":"IATA, e.g. 'SFO'"},\#
            "date":{"type":"string","default":null}},"required":["origin","destination"]}}}]
            """# + flag + "}").utf8)
    }

    /// The declaration and the call as Qwen-family templates print them.
    private static let source = """
        {% for tool in tools %}{{ tool | tojson }}
        {% endfor %}{% for m in messages %}{% for c in m.tool_calls or [] %}\
        {% for k, v in c.function.arguments|items %}{{ k }}={{ v | string if v is string else v | tojson }};{% endfor %}|\
        {% for k, v in c.function.arguments|items %}{{ v | string }};{% endfor %}{% endfor %}{% endfor %}
        """

    /// transformers 5.22.2 `apply_chat_template`'s Jinja environment over the
    /// body, with arguments decoded by `json.loads` as vLLM does.
    private static let transformers = """
        {"type": "function", "function": {"name": "search", "description": "Search flights.", "parameters": \
        {"type": "object", "properties": {"origin": {"type": "string"}, "destination": {"type": "string", \
        "description": "IATA, e.g. 'SFO'"}, "date": {"type": "string", "default": null}}, "required": \
        ["origin", "destination"]}}}
        origin=IAH;destination=São Paulo/GRU;date=2024-05-19;note=null;n=1.0;flags=[true, null, 2];\
        pax={"last": "Li", "first": "Mia"};|IAH;São Paulo/GRU;2024-05-19;None;1.0;[True, None, 2];\
        {'last': 'Li', 'first': 'Mia'};
        """

    /// The provider's text path up to the tokenizer, rendered as the
    /// tokenizer bridge renders (its load-time binding under the request's
    /// context).
    private func render(_ body: Data, modelType: String = "qwen3_5",
                        environment: [String: String] = [:]) throws -> String {
        let inbound = try ProviderLoop.decodeInboundChatRequest(body)
        let controls = inbound.extensions.templateControls
        let prepared = try ToolChoicePromptPolicy.prepare(inbound.request, modelType: modelType)
        let normalized = try ProviderPromptContractPipeline.normalizedInput(
            prepared: prepared, request: inbound.request, modelType: modelType, templateControls: controls)
        // The local API's capture, under `environment`.
        let evidence = TemplateJSONOrder.Evidence(requested: controls.templateJSON.requested)
            .askingLocally(environment: environment).capturing(body: body, environment: environment)
        let input = TemplateJSONOrder.apply(
            messages: normalized.messages, tools: normalized.tools,
            additionalContext: normalized.additionalContext, request: inbound.request,
            evidence: evidence, modelType: modelType, environment: environment)
        var context: [String: Value] = try [
            "messages": .array(input.messages.map { try Value(any: $0) }),
            "add_generation_prompt": .boolean(true),
        ]
        if let tools = input.tools { context["tools"] = try .array(tools.map { try Value(any: $0) }) }
        for (key, value) in input.additionalContext ?? [:] { context[key] = try Value(any: value) }
        for (key, value) in HFTemplateFilters.bindingContext(modelType: modelType, environment: environment) ?? [:]
        where context[key] == nil {
            context[key] = try Value(any: value)
        }
        let template = try Template(
            HFTemplateFilters.bindingFilters(in: Self.source, modelType: modelType, environment: environment),
            with: .init(lstripBlocks: true, trimBlocks: true))
        return try template.render(context)
    }

    @Test func anAskingRequestRendersAsTransformers() throws {
        #expect(try render(Self.body(asking: true)) == Self.transformers)
        #expect(try render(Self.body(asking: false), environment: [TemplateJSONOrder.environmentKey: "transformers"])
            == Self.transformers)
    }

    @Test func otherRequestsRenderAsBefore() throws {
        let before = try render(Self.body(asking: false))
        #expect(before != Self.transformers)
        #expect(before.hasPrefix(#"{"function":{"description":"Search flights.","name":"search""#))
        #expect(try render(Self.body(asking: true), environment: [HFTemplateFilters.legacyEnvironmentKey: "1"]) == before)
        let request = try ProviderLoop.decodeInboundChatRequest(Self.body(asking: true))
        func apply(_ modelType: String) -> (tools: [[String: any Sendable]]?, context: [String: any Sendable]?) {
            let input = TemplateJSONOrder.apply(
                messages: [["role": "user", "content": "x"]], tools: [["type": "function"]], additionalContext: nil,
                request: request.request, evidence: request.extensions.templateControls.templateJSON,
                modelType: modelType, environment: [:])
            return (input.tools, input.additionalContext)
        }
        // Gemma sorts in its template; Super's owner renders the body itself.
        for modelType in ["gemma4", "nemotron_h_omni", "flint"] {
            let input = apply(modelType)
            #expect(input.tools?.count == 1 && input.context == nil)
        }
        // Nemotron-H takes the order, with its own filters.
        let nemotron = apply("nemotron_h")
        #expect(nemotron.tools == nil && nemotron.context?["tools"] != nil && nemotron.context?["tojson"] == nil)
        let qwen = apply("qwen3_5")
        #expect(qwen.tools == nil && qwen.context?["tools"] != nil && qwen.context?["tojson"] != nil)
    }

    @Test func evidenceIsCapturedOnlyForAnAskingRequest() throws {
        let asked = try ProviderLoop.decodeInboundChatRequest(Self.body(asking: true)).extensions.templateControls
        #expect(asked.templateJSON.requested && asked.templateJSON.captured)
        #expect(asked.templateJSON.tools?.count == 1)
        #expect(asked == ProviderLoop.extractChatTemplateControls(from: Self.body(asking: true)))
        let plain = try ProviderLoop.decodeInboundChatRequest(Self.body(asking: false)).extensions.templateControls
        #expect(!plain.templateJSON.requested && !plain.templateJSON.captured)
        #expect(plain.templateJSON.tools == nil)
    }

    /// The coordinator's prompt sidecar plans a request's cache use for the
    /// prompt as rendered before, and a coordinator that forwards unknown
    /// fields would carry a caller's own. A planned request renders the
    /// prompt of its plan; the environment asks only on the local API.
    @Test func onlyAnUnplannedCoordinatorRequestAsks() throws {
        let asked = try ProviderLoop.decodeInboundChatRequest(Self.body(asking: true)).extensions.templateControls
        #expect(TemplateJSONOrder.asks(asked.templateJSON, environment: [:]))
        #expect(asked.servingCoordinatorRequest(planned: false) == asked)
        let planned = asked.servingCoordinatorRequest(planned: true)
        #expect(planned.templateJSON == TemplateJSONOrder.Evidence())
        #expect(!TemplateJSONOrder.asks(planned.templateJSON, environment: [:]))

        let environment = [TemplateJSONOrder.environmentKey: "transformers"]
        let plain = try ProviderLoop.decodeInboundChatRequest(Self.body(asking: false)).extensions.templateControls
        #expect(!TemplateJSONOrder.asks(plain.templateJSON, environment: environment))
        let local = plain.capturingLocalTemplateJSON(from: Self.body(asking: false), environment: environment)
        #expect(TemplateJSONOrder.asks(local.templateJSON, environment: environment))
        #expect(local.templateJSON.tools?.count == 1)
        let off = plain.capturingLocalTemplateJSON(from: Self.body(asking: false), environment: [:])
        #expect(off == plain)
    }

    /// Only a path that read the body renders Transformers' JSON: the local
    /// batch route decodes the field without its bytes, and `tools` beyond
    /// the ordered parser's bounds are not read. Either renders as before,
    /// never Transformers' filters over sorted members.
    @Test func aRequestWhoseBodyWasNotReadRendersAsBefore() throws {
        let unread = try JSONDecoder().decode(ChatTemplateControls.self, from: Self.body(asking: true))
        #expect(unread.templateJSON.requested && !unread.templateJSON.captured)
        #expect(!TemplateJSONOrder.asks(unread.templateJSON, environment: [:]))

        let deep = String(repeating: "[", count: 80) + String(repeating: "]", count: 80)
        let beyond = Data(
            #"{"model":"m","messages":[],"_darkbloom_template_json":"transformers","tools":\#(deep)}"#.utf8)
        let refused = TemplateJSONOrder.Evidence(requested: true).capturing(body: beyond, environment: [:])
        #expect(refused.requested && !refused.captured)
        #expect(!TemplateJSONOrder.asks(refused, environment: [:]))

        // Without tools the body is still read: earlier calls keep their order.
        let none = TemplateJSONOrder.Evidence(requested: true)
            .capturing(body: Data(#"{"model":"m","messages":[],"tools":null}"#.utf8), environment: [:])
        #expect(none.captured && none.tools == nil)
        #expect(TemplateJSONOrder.asks(none, environment: [:]))
        // The kill switch reads nothing.
        let legacy = TemplateJSONOrder.Evidence(requested: true)
            .capturing(body: Self.body(asking: true), environment: [HFTemplateFilters.legacyEnvironmentKey: "1"])
        #expect(!legacy.captured)
    }

    /// A media request's prompt is prepared outside the text path, as before,
    /// so its recounts (usage floor, admission forecast) render that prompt.
    @Test func aMediaRequestRendersAsBefore() throws {
        let body = Data(#"""
            {"model":"m","messages":[{"role":"user","content":[{"type":"text","text":"What is this?"},\#
            {"type":"image_url","image_url":{"url":"https://example.com/a.png"}}]}],\#
            "tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object"}}}],\#
            "_darkbloom_template_json":"transformers"}
            """#.utf8)
        let inbound = try ProviderLoop.decodeInboundChatRequest(body)
        #expect(MediaIngest.hasMedia(inbound.request))
        #expect(TemplateJSONOrder.asks(inbound.extensions.templateControls.templateJSON, environment: [:]))
        let input = TemplateJSONOrder.apply(
            messages: [["role": "user", "content": "x"]], tools: [["type": "function"]], additionalContext: nil,
            request: inbound.request, evidence: inbound.extensions.templateControls.templateJSON,
            modelType: "qwen3_5", environment: [:])
        #expect(input.tools?.count == 1 && input.additionalContext == nil)
    }

    @Test func overlayKeepsContentAndTakesOrderNullsAndNumberTypes() throws {
        let sent = try NemotronSuperOrderedJSON.parse(#"{"z": 1.0, "drop": null, "a": [null, 2, null], "k": "v", "gone": 3}"#)
        // Content as the sanitizer and a schema repair leave it.
        let normalized: [String: any Sendable] = ["a": [2], "k": "repaired", "z": 1, "added": true]
        let ordered = TemplateJSONOrder.overlay(normalized, order: sent)
        #expect(ordered == .object([
            "z": .double(1.0), "drop": .null, "a": .array([.null, .int(2), .null]), "k": .string("repaired"),
            "added": .boolean(true),
        ]))
        #expect(TemplateJSONOrder.overlay(normalized, order: nil) == .object([
            "a": .array([.int(2)]), "added": .boolean(true), "k": .string("repaired"), "z": .int(1),
        ]))
    }

    @Test func callsWithoutUniqueIDsMatchByNameAndPosition() throws {
        let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data(#"""
            {"model":"m","messages":[{"role":"assistant","content":"","tool_calls":[
            {"id":"","type":"function","function":{"name":"f","arguments":"{\"b\": 1, \"a\": 2}"}},
            {"id":"","type":"function","function":{"name":"f","arguments":"{\"d\": 3, \"c\": 4}"}}]}]}
            """#.utf8))
        func call(_ arguments: [String: any Sendable]) -> [String: any Sendable] {
            let function: [String: any Sendable] = ["name": "f", "arguments": arguments]
            return ["id": "", "type": "function", "function": function]
        }
        let calls: [any Sendable] = [call(["a": 2, "b": 1]), call(["c": 4, "d": 3])]
        let messages: [[String: any Sendable]] = [["role": "assistant", "content": "", "tool_calls": calls]]
        let ordered = TemplateJSONOrder.orderingToolCalls(in: messages, request: request)
        guard case .array(let calls)? = ordered[0]["tool_calls"] as? Value, calls.count == 2,
            case .object(let first) = calls[0], case .object(let second) = calls[1],
            case .object(let firstFunction)? = first["function"], case .object(let secondFunction)? = second["function"]
        else { Issue.record("tool_calls were not ordered values"); return }
        #expect(Array(first.keys) == ["id", "type", "function"])
        #expect(firstFunction["arguments"] == .object(["b": .int(1), "a": .int(2)]))
        #expect(secondFunction["arguments"] == .object(["d": .int(3), "c": .int(4)]))
    }
}
