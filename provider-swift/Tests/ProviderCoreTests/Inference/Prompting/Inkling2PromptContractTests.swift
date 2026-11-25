import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import Jinja
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore
@testable import ProviderCoreFoundation

/// Inkling 2 Mini's prompt contract, against the pinned upstream files in
/// `Fixtures/Inkling2` (thinkingmachines/Inkling-2-Mini @ 6e7c8248): the
/// template renders through the provider's template filters, the effort and
/// tool contracts, the configuration-derived cache layout and media policy.
@Suite("Inkling 2 prompt contract")
struct Inkling2PromptContractTests {
    static let type = Inkling2ModelIdentity.modelType
    static let templateSHA256 = "53a9035f3255945704b5857657cfb00c1165090c0641c4f782a0cbf268cc16dc"

    static func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/Inkling2"))
    }

    static func configuration() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture("config.json"))) as? [String: Any])
    }

    /// The template compiled and rendered as the provider's template check
    /// renders it: swift-jinja, normalized, with the family's filters bound.
    static func render(
        _ messages: [[String: Any]], tools: [[String: Any]]? = nil, effort: Value? = nil
    ) throws -> String {
        let source = try String(contentsOf: fixture("chat_template.jinja"), encoding: .utf8)
        let template = try Template(
            HFTemplateFilters.bindingFilters(in: normalizeSwiftJinjaTemplate(source), modelType: type),
            with: .init(lstripBlocks: true, trimBlocks: true))
        var context: [String: Value] = [
            "messages": .array(try messages.map { try Value(any: $0) }),
            "add_generation_prompt": .boolean(true),
            "bos_token": .string(""), "eos_token": .string("<|content_model_end_sampling|>"),
        ]
        if let tools { context["tools"] = .array(try tools.map { try Value(any: $0) }) }
        if let effort { context["reasoning_effort"] = effort }
        let environment = Environment()
        HFTemplateFilters.install(in: environment, modelType: type)
        return try template.render(context, environment: environment)
    }

    static let effortHigh = "<|message_system|><|content_text|>Thinking effort level: 0.9<|end_message|>"

    @Test func fixtureIsThePinnedTemplate() throws {
        let data = try Data(contentsOf: Self.fixture("chat_template.jinja"))
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == Self.templateSHA256)
    }

    // MARK: - Rendering

    /// System messages precede the effort message, which precedes the first
    /// other message; with no effort the template's default, 0.9, renders.
    @Test func plainChatRendersExactly() throws {
        let rendered = try Self.render([
            ["role": "system", "content": "You are a helpful assistant."],
            ["role": "user", "content": "Hi"],
        ])
        #expect(rendered == "<|message_system|><|content_text|>You are a helpful assistant.<|end_message|>"
            + Self.effortHigh + "<|message_user|><|content_text|>Hi<|end_message|>")
    }

    /// Every effort a client names renders the template's own level.
    @Test(arguments: [
        ("none", "0"), ("minimal", "0.1"), ("low", "0.2"), ("medium", "0.7"), ("high", "0.9"),
        ("xhigh", "0.99"), ("max", "0.99"),
    ])
    func everyEffortRendersItsLevel(name: String, level: String) throws {
        let rendered = try Self.render([["role": "user", "content": "Hi"]], effort: .string(name))
        #expect(rendered.hasPrefix("<|message_system|><|content_text|>Thinking effort level: \(level)<|end_message|>"))
        // The provider passes the canonical name for every spelling it accepts.
        #expect(Inkling2PromptContract.templateEffort(name, thinking: nil) == name)
    }

    /// The template reads names exactly: a spelling the provider accepts
    /// (`OFF`, ` High `) must reach it canonicalized, and an unknown one raises.
    @Test func templateRefusesUncanonicalEfforts() throws {
        #expect(throws: (any Error).self) { try Self.render([["role": "user", "content": "Hi"]], effort: .string("High")) }
        #expect(throws: (any Error).self) { try Self.render([["role": "user", "content": "Hi"]], effort: .string("off")) }
        #expect(Inkling2PromptContract.templateEffort(" High ", thinking: nil) == "high")
        #expect(Inkling2PromptContract.templateEffort("OFF", thinking: nil) == "none")
        #expect(Inkling2PromptContract.templateEffort("0", thinking: nil) == "none")
        #expect(Inkling2PromptContract.templateEffort("max", thinking: false) == "none")
        #expect(Inkling2PromptContract.templateEffort(nil, thinking: false) == "none")
        #expect(Inkling2PromptContract.templateEffort(nil, thinking: nil) == nil)
        #expect(ReasoningEffortPolicy.templateEffort("XHIGH", modelID: "m", modelType: Self.type, thinking: nil)
            == "xhigh")
        #expect(ReasoningEffortPolicy.templateEffort("medium", modelID: "m", modelType: Self.type, thinking: false)
            == "none")
        #expect(ReasoningEffortPolicy.reasons(modelID: "m", modelType: Self.type))
    }

    /// Declarations as compact sorted JSON, with non-ASCII text and `/` as
    /// written (Transformers' `tojson`); a history call as the body the
    /// model writes; a result under the function's name.
    @Test func toolFlowRendersExactly() throws {
        let tools: [[String: Any]] = [[
            "type": "function",
            "function": [
                "name": "get_weather",
                "description": "Météo via https://example.com/api",
                "parameters": [
                    "type": "object",
                    "properties": ["location": ["type": "string"], "unit": ["type": "string", "enum": ["c", "f"]]],
                    "required": ["location"],
                ] as [String: Any],
            ] as [String: Any],
        ]]
        let messages: [[String: Any]] = [
            ["role": "user", "content": "Weather in Paris?"],
            [
                "role": "assistant", "content": "", "reasoning_content": "Need the tool.",
                "tool_calls": [[
                    "id": "call_1", "type": "function",
                    "function": ["name": "get_weather",
                                 "arguments": ["unit": "c", "location": "Paris, France"] as [String: Any]],
                ] as [String: Any]],
            ],
            ["role": "tool", "tool_call_id": "call_1", "content": #"{"temperature": 21}"#],
        ]
        let rendered = try Self.render(messages, tools: tools)
        let declaration = #"[{"description":"Météo via https://example.com/api","name":"get_weather","#
            + #""parameters":{"properties":{"location":{"type":"string"},"unit":{"enum":["c","f"],"type":"string"}},"#
            + #""required":["location"],"type":"object"},"type":"function"}]"#
        #expect(rendered == "<|message_system|>tool_declare<|content_xml|>" + declaration + "<|end_message|>"
            + Self.effortHigh + "<|message_user|><|content_text|>Weather in Paris?<|end_message|>"
            + "<|message_model|><|content_thinking|>Need the tool.<|end_message|>"
            + #"<|message_model|>get_weather<|content_invoke_tool_json|>{"name":"get_weather","args":{"location":"Paris, France","unit":"c"}}<|end_message|>"#
            + "<|content_model_end_sampling|>"
            + #"<|message_tool|>get_weather<|content_text|>{"temperature": 21}<|end_message|>"#)
    }

    /// The template refuses arguments as a JSON string: history must carry
    /// parsed objects, as the provider's decoded history does.
    @Test func historyArgumentsMustBeObjects() throws {
        let messages: [[String: Any]] = [
            ["role": "user", "content": "x"],
            ["role": "assistant", "tool_calls": [[
                "id": "c", "type": "function", "function": ["name": "f", "arguments": #"{"a":1}"#],
            ] as [String: Any]]],
        ]
        #expect(throws: (any Error).self) { try Self.render(messages) }
    }

    /// An image part renders one placeholder the processor expands; the
    /// template refuses video and audio parts.
    @Test func imagePartsRenderAndVideoIsRefused() throws {
        let rendered = try Self.render([["role": "user", "content": [
            ["type": "image"], ["type": "text", "text": "Describe."],
        ] as [[String: Any]]]])
        #expect(rendered == Self.effortHigh
            + "<|message_user|><|content_image|><|unused_200054|><|end_message|>"
            + "<|message_user|><|content_text|>Describe.<|end_message|>")
        for type in ["video", "input_audio"] {
            #expect(throws: (any Error).self) {
                try Self.render([["role": "user", "content": [["type": type]] as [[String: Any]]]])
            }
        }
    }

    /// The scan-time check renders every fixture the policy selects: no video
    /// fixture for a still-image model, whose template refuses one.
    @Test func templateRenderCheckPasses() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inkling2-template-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["chat_template.jinja", "config.json", "tokenizer_config.json", "special_tokens_map.json"] {
            try FileManager.default.copyItem(at: Self.fixture(name), to: directory.appendingPathComponent(name))
        }
        #expect(TemplateRenderCheck.configDeclaresVision(at: directory, modelID: Inkling2ModelIdentity.upstreamModelID))
        #expect(!TemplateRenderCheck.configDeclaresVideo(at: directory, modelID: Inkling2ModelIdentity.upstreamModelID))
        #expect(TemplateRenderCheck.renderOK(at: directory, modelID: Inkling2ModelIdentity.upstreamModelID) == true)
    }

    // MARK: - Production input

    /// The provider's template input for a client body: decoded, prepared and
    /// normalized as the text path does (`ProviderPromptContractPipeline.templateInput`).
    static func productionInput(
        _ body: Data, planned: Bool = false
    ) throws -> ProviderPromptContractPipeline.NormalizedInput {
        let inbound = try ProviderLoop.decodeInboundChatRequest(body)
        let prepared = try ToolChoicePromptPolicy.prepare(inbound.request, modelType: type)
        return try ProviderPromptContractPipeline.templateInput(
            prepared: prepared, request: inbound.request, modelType: type,
            templateControls: inbound.extensions.templateControls.servingCoordinatorRequest(planned: planned))
    }

    /// `messages`, `tools` and `additionalContext` rendered as the tokenizer
    /// bridge renders them (`LocalTokenizerLoader`): the request's context,
    /// then the family's filter binding; `effort` overrides the context's.
    static func render(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?, effort: Value? = nil
    ) throws -> String {
        let source = try String(contentsOf: fixture("chat_template.jinja"), encoding: .utf8)
        let template = try Template(
            HFTemplateFilters.bindingFilters(in: normalizeSwiftJinjaTemplate(source), modelType: type),
            with: .init(lstripBlocks: true, trimBlocks: true))
        var context: [String: Value] = [
            "messages": .array(try messages.map { try Value(any: $0) }),
            "add_generation_prompt": .boolean(true),
            "bos_token": .string(""), "eos_token": .string("<|content_model_end_sampling|>"),
        ]
        if let tools { context["tools"] = .array(try tools.map { try Value(any: $0) }) }
        for (key, value) in additionalContext ?? [:] { context[key] = try Value(any: value) }
        for (key, value) in HFTemplateFilters.bindingContext(modelType: type) ?? [:] where context[key] == nil {
            context[key] = try Value(any: value)
        }
        if let effort { context["reasoning_effort"] = effort }
        let environment = Environment()
        HFTemplateFilters.install(in: environment, modelType: type)
        return try template.render(context, environment: environment)
    }

    static func render(_ input: ProviderPromptContractPipeline.NormalizedInput, effort: Value? = nil) throws -> String {
        try render(messages: input.messages, tools: input.tools, additionalContext: input.additionalContext,
                   effort: effort)
    }

    /// A client body: a declared tool, and an earlier call whose arguments
    /// the model wrote in its own order with a nested object, `null`s, a
    /// `1.0` and non-ASCII text. `arguments` is the call's JSON string as sent.
    static func historyBody(arguments: String, extra: String = "") -> Data {
        let encoded = String(decoding: try! JSONEncoder().encode(arguments), as: UTF8.self)
        return Data((#"{"model":"m","messages":[{"role":"user","content":"Weather?"},"#
            + #"{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","#
            + #""function":{"name":"get_weather","arguments":"# + encoded + "}}]},"
            + #"{"role":"tool","tool_call_id":"call_1","content":"24C"}],"#
            + #""tools":[{"type":"function","function":{"name":"get_weather","parameters":{"type":"object","#
            + #""properties":{"city":{"type":"string"}}}}}]"# + extra + "}").utf8)
    }

    static let sentArguments =
        #"{"unit": "c", "city": "São Paulo", "extra": {"z": 1, "a": [1, 2.5, null, true]}, "n": 1.0, "note": null}"#
    /// Transformers' render of `sentArguments`: top-level keys sorted by the
    /// template's `dictsort`, every value as sent.
    static let renderedCall = #"<|message_model|>get_weather<|content_invoke_tool_json|>{"name":"get_weather","#
        + #""args":{"city":"São Paulo","extra":{"z":1,"a":[1,2.5,null,true]},"n":1.0,"note":null,"unit":"c"}}"#
        + "<|end_message|>"

    /// Every Inkling request renders an earlier call's arguments as the
    /// caller's JSON, as Transformers does: asked or not, planned by the
    /// coordinator or not. The same JSON always renders the same bytes.
    @Test func historyArgumentsRenderAsSent() throws {
        let plain = try Self.render(Self.productionInput(Self.historyBody(arguments: Self.sentArguments)))
        #expect(plain.contains(Self.renderedCall), "\(plain)")
        #expect(try Self.render(Self.productionInput(Self.historyBody(arguments: Self.sentArguments), planned: true))
            == plain)
        #expect(try Self.render(Self.productionInput(Self.historyBody(
            arguments: Self.sentArguments, extra: #","_darkbloom_template_json":"transformers""#))) == plain)
        // Whitespace is not part of the JSON; member order is.
        let compact = #"{"unit":"c","city":"São Paulo","extra":{"z":1,"a":[1,2.5,null,true]},"n":1.0,"note":null}"#
        #expect(try Self.render(Self.productionInput(Self.historyBody(arguments: compact))) == plain)
        let reordered = #"{"unit":"c","city":"São Paulo","extra":{"a":[1,2.5,null,true],"z":1},"n":1.0,"note":null}"#
        #expect(try Self.render(Self.productionInput(Self.historyBody(arguments: reordered)))
            == plain.replacingOccurrences(of: #"{"z":1,"a":[1,2.5,null,true]}"#, with: #"{"a":[1,2.5,null,true],"z":1}"#))
        // Arguments that are no JSON object keep the provider's decoding.
        for arguments in ["{'city': 'Paris'}", #"{"city": "Paris""#, "[1, 2]"] {
            let body = Self.historyBody(arguments: arguments)
            let normalized = (try? ProviderLoop.decodeInboundChatRequest(body)).flatMap { inbound in
                try? ProviderPromptContractPipeline.normalizedInput(
                    prepared: ToolChoicePromptPolicy.prepare(inbound.request, modelType: Self.type),
                    request: inbound.request, modelType: Self.type,
                    templateControls: inbound.extensions.templateControls)
            }
            #expect((try? Self.render(Self.productionInput(body))) == normalized.flatMap { try? Self.render($0) },
                    "\(arguments)")
        }
    }

    /// A Pydantic-style declaration: an optional field with `"default": null`,
    /// a property without a `type`, a float default written `1.0`, `strict`.
    static let pydanticTools = #"[{"type":"function","function":{"name":"lookup","description":"Find a record.","#
        + #""strict":false,"parameters":{"type":"object","properties":{"#
        + #""id":{"anyOf":[{"type":"string"},{"type":"null"}],"default":null,"title":"Id"},"#
        + #""payload":{"description":"anything"},"limit":{"type":"number","default":1.0}},"#
        + #""required":["payload"]}}}]"#
    /// Transformers' render of `pydanticTools`: sorted keys, every member as sent.
    static let renderedDeclaration = "<|message_system|>tool_declare<|content_xml|>"
        + #"[{"description":"Find a record.","name":"lookup","parameters":{"properties":{"#
        + #""id":{"anyOf":[{"type":"string"},{"type":"null"}],"default":null,"title":"Id"},"#
        + #""limit":{"default":1.0,"type":"number"},"payload":{"description":"anything"}},"#
        + #""required":["payload"],"type":"object"},"type":"function"}]<|end_message|>"#

    /// Tool declarations render as the body sent them: `null` members kept,
    /// no `type` the provider's repairs infer, numbers as written; on the
    /// text path from the local API and as a planned request, and on the
    /// media path. The same JSON gives the same prompt; other families keep
    /// the provider's normalization.
    @Test func toolDeclarationsRenderAsSent() async throws {
        func body(_ tools: String, image: Bool = false) -> Data {
            let user = image
                ? #"{"role":"user","content":[{"type":"text","text":"Find it."},{"type":"image_url","image_url":{"url":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAF0lEQVR4nGP4z8BAEiJN9aiGUQ1DSgMAkPn/Afnh+ngAAAAASUVORK5CYII="}}]}"#
                : #"{"role":"user","content":"Find it."}"#
            return Data((#"{"model":"m","messages":["# + user + #"],"tools":"# + tools + "}").utf8)
        }
        let text = try Self.render(Self.productionInput(body(Self.pydanticTools)))
        #expect(text.hasPrefix(Self.renderedDeclaration), "\(text)")
        #expect(try Self.render(Self.productionInput(body(Self.pydanticTools), planned: true)) == text)
        // Whitespace and member order do not change a sorted declaration.
        let reordered = Self.pydanticTools
            .replacingOccurrences(of: #""title":"Id"}"#, with: #""title" : "Id" }"#)
            .replacingOccurrences(of: #"{"type":"number","default":1.0}"#, with: #"{"default":1.0,"type":"number"}"#)
        #expect(try Self.render(Self.productionInput(body(reordered))) == text)

        let media = body(Self.pydanticTools, image: true)
        let inbound = try ProviderLoop.decodeInboundChatRequest(media)
        let input = try await MediaIngest.buildUserInput(
            from: inbound.request, templateControls: inbound.extensions.templateControls,
            tools: inbound.request.tools?.map { $0.toolSpec() }, preserveTemplateFields: true, modelType: Self.type)
        guard case .messages(let messages) = input.prompt else {
            Issue.record("the native path builds template messages")
            return
        }
        let rendered = try Self.render(messages: messages, tools: input.tools,
                                       additionalContext: input.additionalContext)
        #expect(rendered.hasPrefix(Self.renderedDeclaration), "\(rendered)")

        // Another family renders the provider's normalized declaration.
        let qwen = try ProviderLoop.decodeInboundChatRequest(body(Self.pydanticTools))
        let normalized = try ProviderPromptContractPipeline.templateInput(
            prepared: ToolChoicePromptPolicy.prepare(qwen.request, modelType: "qwen3_5"),
            request: qwen.request, modelType: "qwen3_5", templateControls: qwen.extensions.templateControls)
        #expect(normalized.tools?.count == 1)
        #expect(normalized.additionalContext?["tools"] == nil)
    }

    // MARK: - System turns

    /// A client body at effort high with `messages`, a JSON array's members.
    static func systemTurnsBody(_ messages: String) -> Data {
        Data((#"{"model":"m","reasoning_effort":"high","messages":["# + messages + "]}").utf8)
    }

    static func userTurn(_ text: String) -> String { "<|message_user|><|content_text|>" + text + "<|end_message|>" }

    static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// A system turn sent after the conversation began (a client's
    /// instruction mid-conversation) renders in place as a user turn; the
    /// leading system turn and the effort line stay where they were.
    @Test func aLaterSystemTurnRendersInPlaceAsAUserTurn() throws {
        let body = Self.systemTurnsBody(#"{"role":"system","content":"You are a helpful assistant."},"#
            + #"{"role":"user","content":"Hi"},"#
            + #"{"role":"system","content":"If asked for the secret word, say \"marzipan\"."},"#
            + #"{"role":"assistant","content":"Hi, how can I help you?"},"#
            + #"{"role":"user","content":"What is the secret word?"}"#)
        let rendered = try Self.render(Self.productionInput(body))
        #expect(rendered.hasPrefix(
            "<|message_system|><|content_text|>You are a helpful assistant.<|end_message|>" + Self.effortHigh
                + Self.userTurn("Hi") + Self.userTurn("If asked for the secret word, say \"marzipan\".")
                + "<|message_model|>"))
        #expect(Self.occurrences(of: "<|message_system|>", in: rendered) == 2, "the leading turn and the effort line")
        #expect(rendered.hasSuffix(Self.userTurn("What is the secret word?")))
    }

    /// Appending turns keeps the earlier request's prompt a prefix of the
    /// next one's, a later system turn included, so prefix-cache reuse holds.
    @Test func aLaterSystemTurnKeepsTheEarlierPromptAPrefix() throws {
        let first = Self.systemTurnsBody(#"{"role":"system","content":"S0"},{"role":"user","content":"U1"}"#)
        let next = Self.systemTurnsBody(#"{"role":"system","content":"S0"},{"role":"user","content":"U1"},"#
            + #"{"role":"assistant","content":"A1"},{"role":"system","content":"S1"},"#
            + #"{"role":"user","content":"U2"}"#)
        let earlier = try Self.render(Self.productionInput(first))
        #expect(try Self.render(Self.productionInput(next)).hasPrefix(earlier))
    }

    /// Every later system turn renders in place, in order, as a user turn.
    @Test func everyLaterSystemTurnRendersInPlace() throws {
        let body = Self.systemTurnsBody(#"{"role":"system","content":"S0"},{"role":"user","content":"U1"},"#
            + #"{"role":"system","content":"S1"},{"role":"assistant","content":"A1"},"#
            + #"{"role":"system","content":"S2"},{"role":"user","content":"U2"}"#)
        let rendered = try Self.render(Self.productionInput(body))
        #expect(rendered.hasPrefix("<|message_system|><|content_text|>S0<|end_message|>" + Self.effortHigh
            + Self.userTurn("U1") + Self.userTurn("S1") + "<|message_model|>"))
        #expect(rendered.hasSuffix(Self.userTurn("S2") + Self.userTurn("U2")))
        #expect(Self.occurrences(of: "<|message_system|>", in: rendered) == 2)
    }

    /// Leading system turns, even several, render as the template renders
    /// the request's own messages.
    @Test func leadingSystemTurnsRenderAsTheTemplateDoes() throws {
        let body = Self.systemTurnsBody(#"{"role":"system","content":"You are a helpful assistant."},"#
            + #"{"role":"system","content":"Be brief."},{"role":"user","content":"Hi"},"#
            + #"{"role":"assistant","content":"Hello."},{"role":"user","content":"What is the secret word?"}"#)
        let template = try Self.render([
            ["role": "system", "content": "You are a helpful assistant."], ["role": "system", "content": "Be brief."],
            ["role": "user", "content": "Hi"], ["role": "assistant", "content": "Hello."],
            ["role": "user", "content": "What is the secret word?"],
        ], effort: .string("high"))
        #expect(try Self.render(Self.productionInput(body)) == template)
    }

    /// The media path's typed messages render later system turns the same way.
    @Test func theMediaPathRendersLaterSystemTurnsAsUserTurns() {
        let messages: [OpenAIChatMessage] = [
            .init(role: .system, content: .text("S0")), .init(role: .user, content: .text("Hi")),
            .init(role: .system, content: .text("S1")), .init(role: .user, content: .text("Q")),
        ]
        let normalized = ChatTemplateFixes.normalizeMessages(
            messages, context: ChatTemplateFixContext(modelId: "m", modelType: Self.type))
        #expect(normalized.map(\.role) == [.system, .user, .user, .user])
        guard case .text(let text) = normalized[2].content else {
            Issue.record("the later turn keeps its text")
            return
        }
        #expect(text == "S1")
    }

    /// The installed provider receives the off switch.
    @Test func theLaterSystemSwitchReachesTheInstalledProvider() {
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains("DARKBLOOM_INKLING_LATER_SYSTEM_AS_USER"))
    }

    /// A list renders each part as its own block, in order, for every role.
    @Test func textPartsRenderAsBlocks() throws {
        let body = Data((#"{"model":"m","messages":[{"role":"system","content":[{"type":"text","text":"S1"},"#
            + #"{"type":"text","text":"S2"}]},{"role":"user","content":[{"type":"text","text":"Part one."},"#
            + #"{"type":"text","text":"Part two."}]}]}"#).utf8)
        #expect(try Self.render(Self.productionInput(body))
            == "<|message_system|><|content_text|>S1<|end_message|><|message_system|><|content_text|>S2<|end_message|>"
            + Self.effortHigh + "<|message_user|><|content_text|>Part one.<|end_message|>"
            + "<|message_user|><|content_text|>Part two.<|end_message|>")
    }

    /// A media request takes the same arguments and parts through the
    /// native template fields the vision prefill selects for this model.
    @Test func mediaRequestsRenderTheSameHistory() async throws {
        let png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAF0lEQVR4nGP4z8BAEiJN9aiGUQ1DSgMAkPn/Afnh+ngAAAAASUVORK5CYII="
        let encoded = String(decoding: try JSONEncoder().encode(Self.sentArguments), as: UTF8.self)
        let body = Data((#"{"model":"m","messages":[{"role":"system","content":[{"type":"text","text":"S1"},"#
            + #"{"type":"text","text":"S2"}]},{"role":"user","content":"Weather?"},"#
            + #"{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","#
            + #""function":{"name":"get_weather","arguments":"# + encoded + "}}]},"
            + #"{"role":"tool","tool_call_id":"call_1","content":"24C"},"#
            + #"{"role":"user","content":[{"type":"text","text":"And this?"},{"type":"image_url","image_url":{"url":""#
            + png + #""}}]}]}"#).utf8)
        let request = try ProviderLoop.decodeOpenAIRequest(body, modelType: Self.type)
        let input = try await MediaIngest.buildUserInput(
            from: request, templateControls: ProviderLoop.extractChatTemplateControls(from: body),
            tools: request.tools?.map { $0.toolSpec() }, preserveTemplateFields: true, modelType: Self.type)
        guard case .messages(let messages) = input.prompt else {
            Issue.record("the native path builds template messages")
            return
        }
        let rendered = try Self.render(messages: messages, tools: input.tools,
                                       additionalContext: input.additionalContext)
        #expect(rendered.hasPrefix(
            "<|message_system|><|content_text|>S1<|end_message|><|message_system|><|content_text|>S2<|end_message|>"),
            "\(rendered)")
        #expect(rendered.contains(Self.effortHigh + "<|message_user|><|content_text|>Weather?<|end_message|>"
            + Self.renderedCall + "<|content_model_end_sampling|>"
            + "<|message_tool|>get_weather<|content_text|>24C<|end_message|>"), "\(rendered)")
        #expect(rendered.hasSuffix("<|message_user|><|content_text|>And this?<|end_message|>"
            + "<|message_user|><|content_image|><|unused_200054|><|end_message|>"))
        // Text requests render the same history.
        let text = try Self.render(Self.productionInput(Self.historyBody(arguments: Self.sentArguments)))
        #expect(text.contains(Self.renderedCall))
    }

    /// A PNG data URI of a solid `width` × `height` image.
    static func pngDataURI(width: Int, height: Int) throws -> String {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return "data:image/png;base64," + (data as Data).base64EncodedString()
    }

    /// A tool result's image runs through the tower like a user image: it
    /// keeps its place among the result's parts in the prompt, and the
    /// images reach the processor in prompt order. Other families still drop
    /// tool-result media.
    @Test func toolResultImagesKeepTheirPlace() async throws {
        let toolImage = try Self.pngDataURI(width: 32, height: 16)
        let userImage = try Self.pngDataURI(width: 16, height: 48)
        let body = Data((#"{"model":"m","messages":[{"role":"user","content":"Chart?"},"#
            + #"{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","#
            + #""function":{"name":"get_chart","arguments":"{}"}}]},"#
            + #"{"role":"tool","tool_call_id":"c1","content":[{"type":"text","text":"before"},"#
            + #"{"type":"image_url","image_url":{"url":""# + toolImage + #""}},{"type":"text","text":"after"}]},"#
            + #"{"role":"user","content":[{"type":"text","text":"And this?"},{"type":"image_url","image_url":{"url":""#
            + userImage + #""}}]}]}"#).utf8)
        let inbound = try ProviderLoop.decodeInboundChatRequest(body)
        try EngineV2VisionPrefill.validateInkling2ImageRoles(inbound.request)
        func ingest(_ modelType: String) async throws -> UserInput {
            try await MediaIngest.buildUserInput(
                from: inbound.request, templateControls: inbound.extensions.templateControls,
                tools: nil, preserveTemplateFields: true, modelType: modelType)
        }
        let input = try await ingest(Self.type)
        let sizes = input.images.compactMap { image -> CGSize? in
            if case .ciImage(let picture) = image.source { return picture.extent.size }
            return nil
        }
        #expect(sizes == [CGSize(width: 32, height: 16), CGSize(width: 16, height: 48)])
        guard case .messages(let messages) = input.prompt else {
            Issue.record("the native path builds template messages")
            return
        }
        let rendered = try Self.render(messages: messages, tools: input.tools,
                                       additionalContext: input.additionalContext)
        #expect(rendered == Self.effortHigh + "<|message_user|><|content_text|>Chart?<|end_message|>"
            + #"<|message_model|>get_chart<|content_invoke_tool_json|>{"name":"get_chart","args":{}}"#
            + "<|end_message|><|content_model_end_sampling|>"
            + "<|message_tool|>get_chart<|content_text|>before<|end_message|>"
            + "<|message_tool|>get_chart<|content_image|><|unused_200054|><|end_message|>"
            + "<|message_tool|>get_chart<|content_text|>after<|end_message|>"
            + "<|message_user|><|content_text|>And this?<|end_message|>"
            + "<|message_user|><|content_image|><|unused_200054|><|end_message|>", "\(rendered)")
        // Another family's native path still drops the result's image.
        #expect(try await ingest("qwen4_exp").images.count == 1)
    }

    /// Other families keep the provider's normalization unless they ask.
    @Test func otherFamiliesKeepTheirArguments() throws {
        #expect(TemplateJSONOrder.rendersCallerArguments(modelType: Self.type))
        for other in ["qwen3_5", "gemma4", "nemotron_h", "flint", "inkling2_loop_text", nil] as [String?] {
            #expect(!TemplateJSONOrder.rendersCallerArguments(modelType: other))
        }
        let inbound = try ProviderLoop.decodeInboundChatRequest(Self.historyBody(arguments: Self.sentArguments))
        let messages: [[String: any Sendable]] = inbound.request.messages.map { $0.templateMessageDict() }
        func calls(_ modelType: String) -> Any? {
            TemplateJSONOrder.apply(messages: messages, tools: nil, additionalContext: nil,
                request: inbound.request, evidence: inbound.extensions.templateControls.templateJSON,
                modelType: modelType, environment: [:]).messages[1]["tool_calls"]
        }
        #expect(calls("qwen3_5") is [[String: any Sendable]])
        #expect(calls(Self.type) is Value)
    }

    // MARK: - Oracle fixtures

    /// Reference Transformers renders of the pinned template
    /// (`apply_chat_template`), outside the repository: set
    /// `INKLING2_ORACLE_TEMPLATE_DIR` to their directory. Each rendered
    /// fixture becomes the OpenAI request a client sends (`oracleBody`) and
    /// must match byte for byte through the provider's own preparation: a
    /// text request through the text path (`productionInput`), from the local
    /// API and as a request the coordinator planned; an image request through
    /// the media ingest the vision prefill selects for this model. Every
    /// error fixture must raise at the template. Without the variable the
    /// test is skipped, never passed.
    static let oracleDirectory = ProcessInfo.processInfo.environment["INKLING2_ORACLE_TEMPLATE_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
    /// A verified checkpoint directory; only its tokenizer files are read.
    static let modelDirectory = ProcessInfo.processInfo.environment["INKLING2_MODEL_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

    static func oracleFixtureNames() throws -> [String] {
        let directory = try #require(oracleDirectory)
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix("MANIFEST") && $0 != "response_parsing.json"
                && $0 != "special_tokens.json" }
            .sorted()
    }

    struct UnrepresentableJSON: Error {}

    /// `value` as JSON text, members in their order.
    static func jsonText(_ value: Value) throws -> String {
        switch value {
        case .null: return "null"
        case .boolean(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .double(let number): return "\(number)"
        case .string(let text): return String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
        case .array(let items): return "[" + (try items.map(jsonText)).joined(separator: ",") + "]"
        case .object(let members):
            var fields: [String] = []
            for (key, member) in members { fields.append(try jsonText(.string(key)) + ":" + jsonText(member)) }
            return "{" + fields.joined(separator: ",") + "}"
        default: throw UnrepresentableJSON()
        }
    }

    /// A fixture as the OpenAI body a client sends, read in its own member
    /// order: each history call's arguments the JSON string of the fixture's
    /// object, image parts inline PNGs, `kwargs` as request members. A
    /// numeric effort, which the wire does not take (a client names its
    /// effort), is returned apart for the template context.
    static func oracleBody(_ data: Data, images: URL) throws -> (body: Data, numericEffort: Value?) {
        guard case .array(let messages)? = try NemotronSuperOrderedJSON.member("messages", of: data) else {
            throw UnrepresentableJSON()
        }
        let wire = try messages.map { message -> String in
            guard case .object(var members) = message else { throw UnrepresentableJSON() }
            if case .array(let calls)? = members["tool_calls"] {
                members["tool_calls"] = .array(try calls.map { call -> Value in
                    guard case .object(var fields) = call, case .object(var function)? = fields["function"],
                        let arguments = function["arguments"]
                    else { return call }
                    if case .string = arguments {} else { function["arguments"] = .string(try jsonText(arguments)) }
                    fields["function"] = .object(function)
                    return .object(fields)
                })
            }
            if case .array(let parts)? = members["content"] {
                members["content"] = .array(try parts.map { part -> Value in
                    guard case .object(let fields) = part, fields["type"] == .string("image"),
                        case .string(let file)? = fields["image"]
                    else { return part }
                    let png = try Data(contentsOf: images.appending(component: file))
                    return .object(["type": .string("image_url"), "image_url": .object([
                        "url": .string("data:image/png;base64," + png.base64EncodedString())])])
                })
            }
            return try jsonText(.object(members))
        }
        var body = #"{"model":"\#(Inkling2ModelIdentity.upstreamModelID)","messages":["# + wire.joined(separator: ",") + "]"
        var numericEffort: Value?
        if case .object(let kwargs)? = try NemotronSuperOrderedJSON.member("kwargs", of: data) {
            for (key, value) in kwargs {
                switch (key, value) {
                case ("reasoning_effort", .int), ("reasoning_effort", .double): numericEffort = value
                default: body += "," + (try jsonText(.string(key))) + ":" + (try jsonText(value))
                }
            }
        }
        return (Data((body + "}").utf8), numericEffort)
    }

    static func hasImageParts(_ fixture: [String: Any]) -> Bool {
        (fixture["messages"] as? [[String: Any]] ?? []).contains { message in
            (message["content"] as? [[String: Any]] ?? []).contains { $0["type"] as? String == "image" }
        }
    }

    @Test(.enabled(if: Inkling2PromptContractTests.oracleDirectory != nil, "INKLING2_ORACLE_TEMPLATE_DIR is unset"))
    func oracleTemplateFixturesRenderIdentically() async throws {
        let directory = try #require(Self.oracleDirectory)
        let names = try Self.oracleFixtureNames()
        #expect(names.count >= 27)
        var rendered = 0
        var refused = 0
        for name in names {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            guard fixture["status"] as? String == "ok" else {
                // The reference raised: so must the template, given the fixture as sent.
                let messages = try #require(fixture["messages"] as? [[String: Any]])
                let kwargs = fixture["kwargs"] as? [String: Any] ?? [:]
                let tools = (kwargs["tools"] as? [[String: Any]])?.compactMap { sanitizeForJinja($0) as? [String: Any] }
                let effort = try kwargs["reasoning_effort"].map { try Value(any: $0) }
                let input = messages.compactMap { sanitizeForJinja($0) as? [String: Any] }
                #expect((try? Self.render(input, tools: tools, effort: effort)) == nil,
                        "\(name) rendered but the reference raised")
                refused += 1
                continue
            }
            let expected = try #require(fixture["rendered_text"] as? String)
            let (body, numericEffort) = try Self.oracleBody(data, images: directory.appending(component: "images"))
            if Self.hasImageParts(fixture) {
                let request = try ProviderLoop.decodeOpenAIRequest(body, modelType: Self.type)
                let input = try await MediaIngest.buildUserInput(
                    from: request, templateControls: ProviderLoop.extractChatTemplateControls(from: body),
                    tools: request.tools?.map { $0.toolSpec() }, preserveTemplateFields: true, modelType: Self.type)
                guard case .messages(let messages) = input.prompt else {
                    Issue.record("\(name): the native path builds template messages")
                    continue
                }
                let output = Result { try Self.render(messages: messages, tools: input.tools,
                                                      additionalContext: input.additionalContext) }
                #expect((try? output.get()) == expected, "\(name): \(output)")
            } else {
                for planned in [false, true] {
                    let output = Result {
                        try Self.render(Self.productionInput(body, planned: planned), effort: numericEffort)
                    }
                    #expect((try? output.get()) == expected, "\(name) planned=\(planned): \(output)")
                }
            }
            rendered += 1
        }
        #expect(rendered >= 22)
        #expect(refused >= 6)
    }

    /// The text fixtures' token ids through the provider's tokenizer bridge
    /// (`LocalTokenizerLoader`, the checkpoint's tokenizer and template) and
    /// its production tokenize call. The image fixtures' ids are
    /// `Inkling2ImagePromptOracleTests`'. Needs both directories.
    @Test(.enabled(if: Inkling2PromptContractTests.oracleDirectory != nil
                    && Inkling2PromptContractTests.modelDirectory != nil,
                   "INKLING2_ORACLE_TEMPLATE_DIR and INKLING2_MODEL_DIR are required"))
    func oracleTextFixturesTokenizeIdentically() async throws {
        let directory = try #require(Self.oracleDirectory)
        let tokenizer = try await LocalTokenizerLoader().load(from: try #require(Self.modelDirectory))
        var compared = 0
        for name in try Self.oracleFixtureNames() {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            guard fixture["status"] as? String == "ok", !Self.hasImageParts(fixture) else { continue }
            let expected = try #require(fixture["input_ids"] as? [Int])
            let (body, numericEffort) = try Self.oracleBody(data, images: directory.appending(component: "images"))
            let inbound = try ProviderLoop.decodeInboundChatRequest(body)
            let prepared = try ToolChoicePromptPolicy.prepare(inbound.request, modelType: Self.type)
            let tokens: [Int]
            if let numericEffort {
                var input = try ProviderPromptContractPipeline.templateInput(
                    prepared: prepared, request: inbound.request, modelType: Self.type,
                    templateControls: inbound.extensions.templateControls)
                var context = input.additionalContext ?? [:]
                context["reasoning_effort"] = numericEffort
                input = .init(messages: input.messages, tools: input.tools, additionalContext: context)
                tokens = try tokenizer.applyChatTemplate(
                    messages: input.messages, tools: input.tools, additionalContext: input.additionalContext)
            } else {
                tokens = try ProviderPromptContractPipeline.tokenize(
                    prepared: prepared, request: inbound.request, tokenizer: tokenizer, modelType: Self.type,
                    templateControls: inbound.extensions.templateControls)
            }
            #expect(tokens == expected, "\(name)")
            compared += 1
        }
        #expect(compared >= 19)
    }

    /// The reference's `parse_response` samples read the same through the
    /// output lexer: reasoning, content and calls.
    @Test(.enabled(if: Inkling2PromptContractTests.oracleDirectory != nil, "INKLING2_ORACLE_TEMPLATE_DIR is unset"))
    func oracleResponseSamplesReadIdentically() throws {
        let directory = try #require(Self.oracleDirectory)
        let document = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appendingPathComponent("response_parsing.json"))) as? [String: Any])
        let samples = try #require(document["samples"] as? [String: [String: Any]])
        #expect(!samples.isEmpty)
        for (name, sample) in samples.sorted(by: { $0.key < $1.key }) {
            let text = try #require(sample["text"] as? String)
            let parsed = try #require(sample["parsed_prefix_empty"] as? [String: Any])
            var lexer = Inkling2OutputChannels()
            var reasoning = "", content = ""
            var calls: [[String: Any]] = []
            for piece in lexer.parse(text) + lexer.finish() {
                switch piece {
                case .reasoning(let text): reasoning += text
                case .content(let text): content += text
                case .toolCall(let call):
                    let arguments = try JSONSerialization.jsonObject(
                        with: JSONEncoder().encode(call.function.arguments))
                    calls.append(["name": call.function.name, "arguments": arguments])
                }
            }
            #expect(reasoning == (parsed["reasoning_content"] as? String ?? ""), "\(name)")
            #expect(content == (parsed["content"] as? String ?? ""), "\(name)")
            let expectedCalls = (parsed["tool_calls"] as? [[String: Any]] ?? []).compactMap {
                $0["function"] as? [String: Any]
            }
            #expect(calls.count == expectedCalls.count, "\(name)")
            for (call, expected) in zip(calls, expectedCalls) {
                #expect(call["name"] as? String == expected["name"] as? String, "\(name)")
                #expect(NSDictionary(dictionary: call["arguments"] as? [String: Any] ?? [:])
                    .isEqual(to: expected["arguments"] as? [String: Any] ?? [:]), "\(name)")
            }
            #expect(lexer.toolFailures.isEmpty, "\(name)")
        }
    }

    // MARK: - Policy

    @Test func identityIsTheExactTypeAndGeometry() throws {
        var configuration = try Self.configuration()
        #expect(Inkling2ModelIdentity.declaresNativeTextTower(configuration))
        #expect(Inkling2ModelIdentity.declaresNativeVision(configuration))
        #expect(Inkling2PromptContract.applies(modelType: "inkling2_loop"))
        for other in ["inkling2", "Inkling2_Loop", " inkling2_loop", "inkling2_loop_text", nil] as [String?] {
            #expect(!Inkling2PromptContract.applies(modelType: other), "\(String(describing: other))")
        }
        configuration["language_model_only"] = true
        #expect(!Inkling2ModelIdentity.declaresNativeVision(configuration))
        #expect(!ModelMediaPolicy.advertisesMedia(configuration))
        configuration["language_model_only"] = nil
        var vision = try #require(configuration["vision_config"] as? [String: Any])
        vision["model_type"] = "siglip"
        configuration["vision_config"] = vision
        #expect(!ModelMediaPolicy.advertisesMedia(configuration))
        configuration["model_type"] = "Inkling2_Loop"
        #expect(!ModelMediaPolicy.advertisesMedia(configuration))
    }

    @Test func mediaPolicyIsStillImagesOnly() throws {
        let configuration = try Self.configuration()
        #expect(ModelMediaPolicy.advertisesMedia(configuration))
        #expect(!ModelMediaPolicy.advertisesVideo(configuration))
        // Other families keep video with their media.
        let qwen: [String: Any] = ["model_type": "qwen3_5", "vision_config": ["hidden_size": 64]]
        #expect(ModelMediaPolicy.advertisesVideo(qwen))
    }

    /// 24 stored layers, the loop's core (6..<18) run twice more: 48 slots,
    /// full attention at layers 5, 11, 17 and 23 (8 slots), sliding-1024
    /// elsewhere (40 slots), and 3 FP32 rows of four convolution states each.
    @Test func cacheLayoutFollowsTheLoop() throws {
        let text = try #require(Self.configuration()["text_config"] as? [String: Any])
        let layout = try #require(Inkling2ModelIdentity.CacheLayout(textConfiguration: text))
        #expect(layout.slots.count == 48)
        #expect(layout.slotLayers == Array(0..<24) + Array(6..<18) + Array(6..<18))
        #expect(layout.fullSlotCount == 8)
        #expect(layout.slidingSlotCount == 40)
        let fullLayers = zip(layout.slotLayers, layout.slots).filter { $0.1 == .full }.map(\.0)
        #expect(fullLayers == [5, 11, 17, 23, 11, 17, 11, 17])
        #expect(layout.kvBytesPerToken() == 32_768)
        #expect(layout.slidingWindowBytes() == 40 * 1_024 * 4_096)
        #expect(layout.convolutionStateBytes() == 3_833_856)
        #expect(layout.convolutionStateBytes(bytesPerElement: 2) == 1_916_928)
        #expect(layout.maximumContext == 1_048_576)
    }

    @Test func malformedGeometryIsNoLayout() throws {
        let cases: [(String, Any?)] = [
            ("loop_config", nil), ("local_layer_ids", [0, 0]), ("local_layer_ids", [24]),
            ("swa_num_key_value_heads", 4), ("sconv_kernel_size", 1), ("num_hidden_layers", true),
        ]
        for (key, value) in cases {
            var text = try #require(Self.configuration()["text_config"] as? [String: Any])
            text[key] = value
            #expect(Inkling2ModelIdentity.CacheLayout(textConfiguration: text) == nil, "\(key)")
            var root = try Self.configuration()
            root["text_config"] = text
            #expect(!Inkling2ModelIdentity.declaresNativeTextTower(root), "\(key)")
        }
    }

    /// Every file the load path reads is in the integrity set the weight hash
    /// and the published manifest cover (`ModelScanner.collectWeightFiles`),
    /// the drafter and the `tiktoken/` subfolder included. The quantization
    /// sidecar, which the loader does not read, and repository metadata are not.
    @Test func integritySetCoversTheLoadPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inkling2-integrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("tiktoken", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let read = [
            "config.json", "chat_template.jinja", "tokenizer.json", "tiktoken/tokenizer.model",
            "tokenizer_config.json", "special_tokens_map.json", "processor_config.json", "generation_config.json",
            "model.safetensors.index.json", "model-00001-of-00001.safetensors", "mtp.safetensors",
        ]
        let unread = ["hf_quant_config.json", "README.md", ".gitattributes"]
        for name in read + unread {
            try Data(repeating: 1, count: name.hasSuffix(".safetensors") ? 64 : 4)
                .write(to: directory.appendingPathComponent(name))
        }
        let (size, paths) = ModelScanner.collectWeightFiles(in: directory)
        // Relative to the snapshot, whichever spelling of the temporary root
        // (`/var` or `/private/var`) the enumerator returns.
        let marker = directory.lastPathComponent + "/"
        let hashed = Set(paths.compactMap { url in
            url.path.range(of: marker).map { String(url.path[$0.upperBound...]) }
        })
        #expect(hashed == Set(read))
        #expect(size == 128)
        #expect(ModelScanner.roleFor(filename: "mtp.safetensors") == "weight")
        #expect(ModelScanner.roleFor(filename: "tokenizer.model") == "tokenizer")
    }

    /// The pre-load KV estimate counts the full slots of every pass, not 24
    /// uniform layers (3x too many) and not the sliding slots' plateau.
    @Test func preloadKVEstimateUsesTheSlotLayout() throws {
        let architecture = KVEstimation.parseModelArchitecture(at: try Self.fixture("config.json"))
        #expect(architecture.numLayers == 48)
        #expect(architecture.maxContextLength == 524_288)
        #expect(KVEstimation.resolvedKVBytesPerToken(architecture: architecture, weightBytes: 19_526_019_168)
            == 32_768)
    }

    /// The upstream download serves on paged KV with the complete prefix
    /// cache by default; other ids keep the generic defaults.
    @Test func servedIdentityDefaults() {
        let id = Inkling2ModelIdentity.upstreamModelID
        #expect(EngineV2KVBackendPolicy.preferredBackend(selection: .auto, modelID: id) == .paged)
        #expect(PrefixCachePolicy.isEnabled(modelId: id, environment: [:]))
        #expect(!PrefixCachePolicy.isEnabled(modelId: id, environment: [PrefixCachePolicy.environmentFlag: "0"]))
        for other in ["thinkingmachines/Inkling-2-Small", "inkling-2-mini-copy"] {
            #expect(EngineV2KVBackendPolicy.preferredBackend(selection: .auto, modelID: other) == .contiguous)
            #expect(!PrefixCachePolicy.isEnabled(modelId: other, environment: [:]))
        }
    }

    @Test func forcedChoicesArePromptForcedAndChecked() throws {
        let context = ChatTemplateFixContext(modelId: Inkling2ModelIdentity.upstreamModelID, modelType: Self.type)
        #expect(try ToolChoiceEnforcementPolicy.forcedStrategy(mode: .required, modelContext: context)
            == .structuredPostValidation)
        #expect(try ToolChoiceEnforcementPolicy.forcedStrategy(mode: .named("f"), modelContext: context)
            == .structuredPostValidation)
        #expect(try ToolChoiceEnforcementPolicy.forcedStrategy(mode: .auto, modelContext: context) == .none)
    }

    /// Client stop strings match only answer text.
    @Test func stopStringsApplyToTheAnswer() {
        #expect(ModelEOSPolicy.stopStringScope(modelId: "m", modelType: Self.type)
            == CBv2StopStringScope(opener: "<|content_text|>",
                closers: ["<|end_message|>", "<|content_model_end_sampling|>", "<|message_model|>"]))
        #expect(ModelEOSPolicy.stopStringScope(modelId: "m", modelType: "qwen3_5") == nil)
    }

    /// Another role's turn stops generation as EOS does.
    @Test func otherTurnsStopGeneration() {
        let ids = ["<|message_user|>": 200000, "<|message_system|>": 200002, "<|message_tool|>": 200003,
                   "<|endoftext|>": 199999]
        let stops = ModelEOSPolicy.effectiveEOSTokenIds(modelId: "m", modelType: Self.type, base: [200006],
            tokenToId: { ids[$0] })
        #expect(stops == [200006, 200000, 200002, 200003, 199999])
        // Other families keep their own stops.
        #expect(ModelEOSPolicy.effectiveEOSTokenIds(modelId: "m", modelType: "qwen3_5", base: [1],
            tokenToId: { ids[$0] }) == [1])
    }

    /// Thinking off, by the template context's precedence, withholds whatever
    /// the model still thinks at effort 0; nothing else does.
    @Test func declinedThinkingIsWithheld() throws {
        func request(_ json: String) throws -> (OpenAIChatCompletionRequest, ChatTemplateControls) {
            let body = Data((#"{"model":"m","messages":[{"role":"user","content":"hi"}]"# + json + "}").utf8)
            return (try ProviderLoop.decodeOpenAIRequest(body, modelType: Self.type),
                    ProviderLoop.extractChatTemplateControls(from: body))
        }
        for (json, withheld) in [
            ("", false), (#","reasoning_effort":"none""#, true), (#","reasoning_effort":"OFF""#, true),
            (#","reasoning_effort":"minimal""#, false), (#","reasoning":{"enabled":false}"#, true),
            (#","chat_template_kwargs":{"enable_thinking":false}"#, true),
            (#","reasoning":{"enabled":true},"reasoning_effort":"none""#, false),
        ] {
            let (decoded, controls) = try request(json)
            #expect(Inkling2PromptContract.withholdsReasoning(decoded, controls: controls, modelType: Self.type)
                == withheld, "\(json)")
            #expect(!Inkling2PromptContract.withholdsReasoning(decoded, controls: controls, modelType: "gemma4"))
        }
    }
}
