// Copyright © 2026 Eigen Labs.

import Foundation
import Hummingbird
import HummingbirdTesting
import MLXLMCommon
import MLXLMServer
import NIOCore
import Testing

@testable import ProviderCore

/// What the template receives records each render through a test tokenizer.
private final class RenderRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var renders: [(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?)] = []

    func add(_ messages: [[String: any Sendable]], _ tools: [[String: any Sendable]]?) {
        lock.withLock { renders.append((messages, tools)) }
    }

    var last: (messages: [[String: any Sendable]], tools: [[String: any Sendable]]?)? {
        lock.withLock { renders.last }
    }
}

private struct RecordingTokenizer: MLXLMCommon.Tokenizer {
    let base = MuseGlimmerTestTokenizer()
    let record: RenderRecord

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { base.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        base.decode(tokenIds: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
    var bosToken: String? { base.bosToken }
    var eosToken: String? { base.eosToken }
    var unknownToken: String? { base.unknownToken }
    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        record.add(messages, tools)
        return try base.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}

/// Muse Glimmer's prompt as its reference servers render it
/// (`MuseGlimmerReferencePrompt`): the caller's declarations, vLLM's system
/// merge, and injected instructions appended. The rendered prompts and their
/// token IDs are pinned against the reference in `MuseGlimmerPromptGoldenTests`.
@Suite("Muse Glimmer reference prompt")
struct MuseGlimmerReferencePromptTests {
    private static let modelType = MuseGlimmerModelPolicy.modelType
    private static let modelID = MuseGlimmerModelPolicy.catalogModelID

    private static var reservation: [String: Any] {
        [
            "type": "function", "function": [
                "name": "book_reservation", "description": "Book a reservation.",
                "parameters": [
                    "$defs": ["Passenger": ["type": "object", "properties": ["name": ["type": "string"]]]],
                    "type": "object", "required": ["lead"],
                    "properties": [
                        "lead": ["$ref": "#/$defs/Passenger"],
                        "companion": ["anyOf": [["$ref": "#/$defs/Passenger"], ["type": "null"]]],
                        "metadata": [String: Any](),
                        "notes": ["description": "Free-form notes."],
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ]
    }
    private static var weather: [String: Any] {
        [
            "type": "function", "function": [
                "name": "get_weather", "description": "Weather for a city.",
                "parameters": ["type": "object", "required": ["city"],
                               "properties": ["city": ["type": "string"], "notes": ["description": "Any notes."]]],
            ] as [String: Any],
        ]
    }

    private struct Body {
        let data: Data
        let request: OpenAIChatCompletionRequest
        let controls: ChatTemplateControls

        init(_ messages: [[String: Any]], tools: [[String: Any]]? = nil, extra: [String: Any] = [:]) throws {
            var body: [String: Any] = ["model": MuseGlimmerReferencePromptTests.modelID, "messages": messages]
            if let tools { body["tools"] = tools }
            body.merge(extra) { _, new in new }
            data = try JSONSerialization.data(withJSONObject: body)
            request = try ProviderLoop.decodeOpenAIRequest(data)
            controls = ProviderLoop.extractChatTemplateControls(from: data)
        }

        /// As the scheduler receives it from the service, which adds the JSON
        /// `response_format` instruction.
        var serviced: OpenAIChatCompletionRequest {
            get throws { try OpenAIResponseFormatSupport.preparedRequest(request) }
        }

        func restored(
            _ request: OpenAIChatCompletionRequest? = nil, modelType: String? = MuseGlimmerReferencePromptTests.modelType,
            enabled: Bool = true
        ) throws -> OpenAIChatCompletionRequest {
            try controls.restoringOriginalRequest(request ?? self.request, modelType: modelType, museReferencePrompt: enabled)
        }
    }

    private static func message(_ role: String, _ content: Any) -> [String: Any] { ["role": role, "content": content] }

    private static func shape(_ messages: [OpenAIChatMessage]) -> [String] {
        messages.map { "\($0.role.rawValue): \($0.content.text)" }
    }

    private static func json(_ value: Any) throws -> MLXLMCommon.JSONValue {
        try JSONDecoder().decode(MLXLMCommon.JSONValue.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private static let jsonInstruction = "You must respond with a single valid JSON object. Do not include markdown, "
        + "code fences, comments, explanations, or extra text. The first non-whitespace character must be \"{\" and "
        + "the final non-whitespace character must be \"}\"."
    private static let noTool = "Do not call any tool. Answer the user directly without emitting a tool call."

    @Test("on by default, with a kill switch the launch agent passes through")
    func killSwitch() {
        #expect(MuseGlimmerReferencePrompt.enabled(environment: [:]))
        #expect(MuseGlimmerReferencePrompt.enabled(environment: [MuseGlimmerReferencePrompt.environmentKey: "1"]))
        for off in ["0", "off", "OFF", " false "] {
            #expect(!MuseGlimmerReferencePrompt.enabled(environment: [MuseGlimmerReferencePrompt.environmentKey: off]))
        }
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(MuseGlimmerReferencePrompt.environmentKey))
        #expect(MuseGlimmerReferencePrompt.appendsInstructions(modelType: Self.modelType, enabled: true))
        #expect(!MuseGlimmerReferencePrompt.appendsInstructions(modelType: Self.modelType, enabled: false))
        #expect(!MuseGlimmerReferencePrompt.appendsInstructions(modelType: "gpt_oss", enabled: true))
    }

    @Test("the caller's declarations replace the ingress repair's render types")
    func callerDeclarations() throws {
        let body = try Body([Self.message("user", "Book it.")], tools: [Self.reservation])
        // The ingress repair types the reference as a string and marks the allow-all value.
        let repaired = try #require(body.request.tools?.first?.function.parameters)
        let rendered = String(decoding: try JSONEncoder().encode(repaired), as: UTF8.self)
        #expect(rendered.contains(ToolSchemaNormalization.originalBooleanSchemaKey))
        let restored = try body.restored()
        let raw = try Self.json(try #require((Self.reservation["function"] as? [String: Any])?["parameters"]))
        #expect(restored.tools?.first?.function.parameters == raw)
        #expect(restored.tools?.count == 1)
        // The auto path accepts them; nothing reserved reaches the template.
        let prepared = try ToolChoicePromptPolicy.prepare(restored, modelType: Self.modelType, allowInternalSchemaMetadata: false)
        #expect(prepared.tools?.first?.function.parameters == raw)
        // Switched off, or another model: the repaired declarations, as before.
        #expect(try body.restored(enabled: false).tools == body.request.tools)
        #expect(try body.restored(modelType: "llama").tools == body.request.tools)
    }

    @Test("declarations that carry reserved metadata stay as decoded, and admission still decides")
    func reservedMetadataIsNotTrusted() throws {
        let marked: [String: Any] = [
            "type": "function", "function": [
                "name": "lookup",
                "parameters": ["type": "object", "properties": [
                    "value": ["type": "string", ToolSchemaNormalization.originalBooleanSchemaKey: true]]],
            ] as [String: Any],
        ]
        let body = try Body([Self.message("user", "Look it up.")], tools: [marked])
        let restored = try body.restored()
        #expect(restored.tools == body.request.tools)
        // A body that did not come from a coordinator declaring the metadata protocol is refused, as before.
        #expect(throws: (any Error).self) {
            _ = try ToolChoicePromptPolicy.prepare(restored, modelType: Self.modelType, allowInternalSchemaMetadata: false)
        }
    }

    @Test("a forced choice over the caller's declarations compiles, or is a typed 400, never a 500")
    func forcedChoiceOverCallerDeclarations() throws {
        let named = try Body([Self.message("user", "Weather?")], tools: [Self.weather],
            extra: ["tool_choice": ["type": "function", "function": ["name": "get_weather"]]])
        let prepared = try ToolChoicePromptPolicy.prepare(try named.restored(), modelType: Self.modelType)
        #expect(prepared.compiledTools?.count == 1)
        let reference = try Body([Self.message("user", "Book it.")], tools: [Self.reservation],
            extra: ["tool_choice": "required"])
        do {
            _ = try ToolChoicePromptPolicy.prepare(try reference.restored(), modelType: Self.modelType)
            Issue.record("a local reference is outside the forced grammar's subset")
        } catch {
            guard case .invalidToolPayload(_, let refusal) = error as? MultiModelBatchSchedulerEngineError else {
                Issue.record("\(error)")
                return
            }
            #expect(refusal == .unsupportedForcedToolChoice)
            #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 400)
        }
    }

    @Test("with a developer message, system messages merge as vLLM merges them")
    func developerMerge() throws {
        let merged = try Body([
            Self.message("system", "You are an agent."), Self.message("developer", "Follow the policy."),
            Self.message("user", "Hi"), Self.message("system", [["type": "text", "text": "Late"], ["type": "text", "text": "rule."]]),
            Self.message("system", ""),
        ]).restored()
        #expect(Self.shape(merged.messages) == ["system: You are an agent.\n\nFollow the policy.\n\nLate\nrule.", "user: Hi"])
        // A developer message alone stays where it is, as a system message.
        let alone = try Body([Self.message("developer", "Be terse."), Self.message("user", "Hi")]).restored()
        #expect(Self.shape(alone.messages) == ["system: Be terse.", "user: Hi"])
        // Without a developer message vLLM merges nothing, and neither does this.
        let two = try Body([Self.message("system", "First."), Self.message("system", "Second."), Self.message("user", "Hi")])
        #expect(try two.restored().messages == two.request.messages)
        // Switched off: two blocks, as before.
        let off = try Body([Self.message("system", "A."), Self.message("developer", "B."), Self.message("user", "Hi")])
        #expect(Self.shape(try off.restored(enabled: false).messages) == ["system: A.", "system: B.", "user: Hi"])
        #expect(Self.shape(try off.restored(modelType: "qwen3").messages) == ["system: A.", "system: B.", "user: Hi"])
    }

    @Test("the JSON response_format instruction joins the caller's system message or the last user turn")
    func responseFormatInstruction() throws {
        let format: [String: Any] = ["response_format": ["type": "json_object"]]
        let bare = try Body([Self.message("user", "Colors?"), Self.message("assistant", "Which?"),
                             Self.message("user", "Two.")], extra: format)
        // The service inserts a system message, which would replace the default block.
        #expect(try bare.serviced.messages.first?.role == .system)
        #expect(Self.shape(try bare.restored(try bare.serviced).messages)
            == ["user: Colors?", "assistant: Which?", "user: Two.\n\n" + Self.jsonInstruction])
        let system = try Body([Self.message("system", "Be brief."), Self.message("user", "Two.")], extra: format)
        #expect(Self.shape(try system.restored(try system.serviced).messages)
            == ["system: Be brief.\n\n" + Self.jsonInstruction, "user: Two."])
        let merged = try Body([Self.message("system", "Be brief."), Self.message("developer", "English."),
                               Self.message("user", "Two.")], extra: format)
        #expect(Self.shape(try merged.restored(try merged.serviced).messages)
            == ["system: Be brief.\n\nEnglish.\n\n" + Self.jsonInstruction, "user: Two."])
        // List content renders its parts joined: the instruction keeps its blank line.
        let parts = try Body([Self.message("user", [["type": "text", "text": "Two."]])], extra: format)
        #expect(Self.shape(try parts.restored(try parts.serviced).messages) == ["user: Two.\n\n" + Self.jsonInstruction])
        // A body read without the service (token counts) has no instruction to move.
        #expect(try bare.restored().messages == bare.request.messages)
        // Switched off: the service's system message stays.
        #expect(try bare.restored(try bare.serviced, enabled: false).messages == (try bare.serviced).messages)
    }

    @Test("tool_choice none and a forced choice append their instructions")
    func toolChoiceInstructions() throws {
        let none = try Body([Self.message("user", "Weather?")], tools: [Self.weather], extra: ["tool_choice": "none"])
        let prepared = try ToolChoicePromptPolicy.prepare(try none.restored(), modelType: Self.modelType)
        #expect(Self.shape(prepared.messages) == ["user: Weather?\n\n" + Self.noTool])
        #expect(prepared.tools == nil)
        let withSystem = try Body([Self.message("system", "Be brief."), Self.message("user", "Weather?")],
                                  tools: [Self.weather], extra: ["tool_choice": "none"])
        #expect(Self.shape(try ToolChoicePromptPolicy.prepare(try withSystem.restored(), modelType: Self.modelType).messages)
            == ["system: Be brief.\n\n" + Self.noTool, "user: Weather?"])
        let forced = try Body([Self.message("user", "Weather?"), Self.message("assistant", "Where?"),
                               Self.message("user", "Paris.")], tools: [Self.weather], extra: ["tool_choice": "required"])
        let forcedMessages = try ToolChoicePromptPolicy.prepare(try forced.restored(), modelType: Self.modelType).messages
        #expect(forcedMessages.map(\.role) == [.user, .assistant, .user])
        #expect(forcedMessages.last?.content.text.hasPrefix("Paris.\n\nCall the declared function 'get_weather' now.") == true)
        #expect(forcedMessages.first?.content.text == "Weather?")
        // Switched off, and for every other model: a new leading system message, as before.
        let earlier = try ToolChoicePromptPolicy.prepare(
            try none.restored(enabled: false), modelType: Self.modelType, museReferencePrompt: false)
        #expect(Self.shape(earlier.messages) == ["system: " + Self.noTool, "user: Weather?"])
        let other = try ToolChoicePromptPolicy.prepare(none.request, modelType: "qwen3")
        #expect(Self.shape(other.messages) == ["system: " + Self.noTool, "user: Weather?"])
        let otherForced = try ToolChoicePromptPolicy.prepare(forced.request, modelType: "qwen3")
        #expect(otherForced.messages.first?.role == .system)
    }

    @Test("an instruction with neither a system message nor a user turn leads, as for every other model")
    func instructionWithoutAUserTurn() {
        let assistant = OpenAIChatMessage(role: .assistant, content: .text("Earlier."))
        #expect(Self.shape(MuseGlimmerReferencePrompt.appendingInstruction("Do X.", to: [assistant]))
            == ["system: Do X.", "assistant: Earlier."])
        #expect(Self.shape(MuseGlimmerReferencePrompt.forcingInstruction("Do X.", in: [assistant]))
            == ["system: Do X.", "assistant: Earlier."])
        let empty = OpenAIChatMessage(role: .user, content: .null)
        #expect(Self.shape(MuseGlimmerReferencePrompt.appendingInstruction("Do X.", to: [empty])) == ["user: Do X."])
    }

    #if DEBUG
    /// The scheduler's own preparation, behind the service, over a scripted engine.
    private func render(_ body: Body, reference: Bool = true) async throws -> (messages: [[String: any Sendable]], tools: [[String: any Sendable]]?) {
        let record = RenderRecord()
        let handle = TokenizerHandle(RecordingTokenizer(record: record))
        let engine = MuseGlimmerLoopTestEngine(.answers)
        let bridge = EngineV2Bridge(engine: engine, modelId: Self.modelID, tokenizer: handle,
            eosTokenIds: MuseGlimmerTestTokenizer.stops, stopStringScope: MuseGlimmerTemplateFix.answerStopScope,
            defaultMaxTokens: 64, maxConcurrentRequests: 1)
        var scheduler = MultiModelBatchSchedulerEngine(
            registryProvider: { [Self.modelID: .init(tokenizer: handle, modelType: Self.modelType, engineV2Bridge: bridge)] },
            templateControls: body.controls)
        scheduler.museGlimmerReferencePrompt = reference
        let service = MLXOpenAIService(engine: scheduler)
        // The scripted answer is no JSON; only what was rendered matters here.
        do { for try await _ in try await service.streamChatCompletionFrames(request: body.request) {} } catch {}
        await bridge.shutdown()
        return try #require(record.last)
    }

    private static func roles(_ messages: [[String: any Sendable]]) -> [String] {
        messages.map { "\($0["role"] as? String ?? "?"): \($0["content"] as? String ?? "")" }
    }

    @Test("the serving path renders the merged system message and the appended instruction")
    func servingPath() async throws {
        let body = try Body([Self.message("system", "Be brief."), Self.message("developer", "English."),
                             Self.message("user", "Two colors.")], tools: [Self.reservation],
                            extra: ["response_format": ["type": "json_object"]])
        let served = try await render(body)
        #expect(Self.roles(served.messages) == ["system: Be brief.\n\nEnglish.\n\n" + Self.jsonInstruction,
                                                "user: Two colors."])
        #expect(!"\(try #require(served.tools))".contains(ToolSchemaNormalization.originalBooleanSchemaKey))
        // Switched off: the earlier prompt, three system blocks and the repair's marker.
        let earlier = try await render(body, reference: false)
        #expect(Self.roles(earlier.messages).filter { $0.hasPrefix("system:") }.count == 3)
        #expect("\(try #require(earlier.tools))".contains(ToolSchemaNormalization.originalBooleanSchemaKey))
    }

    /// The local API's own decode (`LocalChatUploadResponder`), over the same scheduler and scripted engine. A
    /// `developer` message fails the strict decode, so the request is decoded again from the repaired body.
    @Test("the local API renders the merged system message too", arguments: [false, true])
    func localAPIPath(stream: Bool) async throws {
        let body = try Body([Self.message("system", "Be brief."), Self.message("developer", "English."),
                             Self.message("user", "Two colors.")], tools: [Self.reservation],
                            extra: ["response_format": ["type": "json_object"], "stream": stream])
        let record = RenderRecord()
        let handle = TokenizerHandle(RecordingTokenizer(record: record))
        let bridge = EngineV2Bridge(engine: MuseGlimmerLoopTestEngine(.answers), modelId: Self.modelID,
            tokenizer: handle, eosTokenIds: MuseGlimmerTestTokenizer.stops,
            stopStringScope: MuseGlimmerTemplateFix.answerStopScope, defaultMaxTokens: 64, maxConcurrentRequests: 1)
        let registry: @Sendable () async -> MultiModelBatchSchedulerEngine.Registry = {
            [Self.modelID: .init(tokenizer: handle, modelType: Self.modelType, engineV2Bridge: bridge)]
        }
        let upload = LocalChatUploadResponder(
            inner: Router<BasicRequestContext>().buildResponder(),
            service: MLXOpenAIService(engine: MultiModelBatchSchedulerEngine(registryProvider: registry)),
            serviceForTemplateControls: { controls in
                var scheduler = MultiModelBatchSchedulerEngine(registryProvider: registry, templateControls: controls)
                scheduler.museGlimmerReferencePrompt = true
                return MLXOpenAIService(engine: scheduler)
            })
        let app = Application(responder: CORSResponder(inner: upload),
            configuration: .init(address: .hostname("127.0.0.1", port: 0)))
        // The scripted answer is no JSON; only what was rendered matters here.
        try await app.test(.router) { client in
            _ = try await client.execute(uri: "/v1/chat/completions", method: .post,
                headers: [.contentType: "application/json"], body: ByteBuffer(data: body.data))
        }
        await bridge.shutdown()
        #expect(Self.roles(try #require(record.last).messages)
            == ["system: Be brief.\n\nEnglish.\n\n" + Self.jsonInstruction, "user: Two colors."])
    }
    #endif
}
