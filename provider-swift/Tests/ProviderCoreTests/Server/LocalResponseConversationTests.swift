import Foundation
import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("Local Responses previous_response_id")
struct LocalResponseConversationTests {
    private static let weatherCall = OpenAIToolCall(
        id: "call_1", function: .init(name: "weather", arguments: #"{"city":"Paris"}"#))

    private struct NotPrepared: Error { let preparation: LocalResponseConversation.Preparation }

    /// Prepares `body` against `store`; fails the test unless it is `.prepared`.
    private func prepared(_ body: String, _ store: LocalResponseConversationStore) throws -> (body: Data?, items: Data) {
        let preparation = LocalResponseConversation.prepare(
            body: Data(body.utf8), conversation: store.conversation(for:))
        guard case .prepared(let rewritten, let items) = preparation else { throw NotPrepared(preparation: preparation) }
        return (rewritten, items)
    }

    private func messages(_ body: Data) throws -> [OpenAIChatMessage] {
        try JSONDecoder().decode(LocalResponseRequest.self, from: body).request.input.messages(instructions: nil)
    }

    private func frame(_ type: String, _ response: OpenAIResponse) throws -> String {
        struct Event: Encodable { let type: String; let response: OpenAIResponse }
        let json = try JSONEncoder().encode(Event(type: type, response: response))
        return "event: \(type)\ndata: \(String(decoding: json, as: UTF8.self))\n\n"
    }

    @Test("a request naming no previous response is decoded from its own bytes")
    func requestWithoutPreviousResponseIsDecodedAsSent() throws {
        let store = LocalResponseConversationStore()
        let first = try prepared(#"{"model":"m","input":"My name is Ada."}"#, store)
        #expect(first.body == nil)
        let items = try JSONSerialization.jsonObject(with: first.items) as? [[String: String]]
        #expect(items == [["role": "user", "content": "My name is Ada."]])
    }

    @Test("a follow-up remembers the earlier turn and keeps its own fields")
    func continuationPrependsTheStoredConversation() throws {
        let store = LocalResponseConversationStore()
        let first = try prepared(#"{"model":"m","input":"My name is Ada.","instructions":"Be brief."}"#, store)
        store.record(
            responseID: "resp_1", output: [.message(id: "msg_1", text: "Nice to meet you, Ada.")],
            inputItems: first.items)

        let second = try prepared(
            #"{"model":"m","previous_response_id":"resp_1","input":"What is my name?","temperature":0.5,"stream":true}"#,
            store)
        let body = try #require(second.body)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(!object.keys.contains("previous_response_id"))
        let request = try JSONDecoder().decode(LocalResponseRequest.self, from: body).request
        #expect(request.model == "m")
        #expect(request.temperature == 0.5)
        #expect(request.stream == true)
        // Instructions belong to the request that sent them, as with OpenAI.
        #expect(request.instructions == nil)
        #expect(try messages(body) == [
            .init(role: .user, content: .text("My name is Ada.")),
            .init(role: .assistant, content: .text("Nice to meet you, Ada.")),
            .init(role: .user, content: .text("What is my name?")),
        ])
    }

    @Test("a function_call_output alone continues the stored tool call")
    func functionCallOutputContinuesTheToolCall() throws {
        let store = LocalResponseConversationStore()
        let first = try prepared(#"{"model":"m","input":[{"role":"user","content":"Weather in Paris?"}]}"#, store)
        store.record(
            responseID: "resp_1",
            output: [
                .reasoning(id: "rs_1", text: "Need the tool."),
                .functionCall(id: "fc_1", toolCall: Self.weatherCall),
            ],
            inputItems: first.items)

        let second = try prepared(
            #"{"model":"m","previous_response_id":"resp_1","input":[{"type":"function_call_output","call_id":"call_1","output":"Sunny"}]}"#,
            store)
        #expect(try messages(try #require(second.body)) == [
            .init(role: .user, content: .text("Weather in Paris?")),
            .init(role: .assistant, content: .text(""), toolCalls: [Self.weatherCall], reasoningContent: "Need the tool."),
            .init(role: .tool, content: .text("Sunny"), toolCallID: "call_1"),
        ])
    }

    @Test("an unknown previous_response_id is refused")
    func unknownPreviousResponseIsRefused() {
        let preparation = LocalResponseConversation.prepare(
            body: Data(#"{"model":"m","previous_response_id":"resp_missing","input":"hi"}"#.utf8),
            conversation: LocalResponseConversationStore().conversation(for:))
        #expect(preparation == .previousResponseNotFound)
    }

    @Test("a body the rewrite cannot read is left to the decoder")
    func unreadableBodyIsLeftToTheDecoder() {
        for body in ["not json", "[1]", #"{"model":"m","input":5}"#] {
            let preparation = LocalResponseConversation.prepare(body: Data(body.utf8), conversation: { _ in nil })
            #expect(preparation == .opaque, "\(body)")
        }
    }

    @Test("only completed and incomplete frames carry a response to continue")
    func finalResponseIsReadFromTerminalFramesOnly() throws {
        let response = OpenAIResponse(
            id: "resp_1", status: .completed, model: "m",
            output: [.message(id: "msg_1", text: "Hi")], outputText: "Hi",
            usage: .init(inputTokens: 3, outputTokens: 1))
        for type in ["response.completed", "response.incomplete"] {
            #expect(LocalResponseConversation.finalResponse(inFrame: try frame(type, response))
                == LocalResponseConversation.FinalResponse(id: "resp_1", output: response.output))
        }
        for type in ["response.created", "response.in_progress", "response.failed"] {
            #expect(LocalResponseConversation.finalResponse(inFrame: try frame(type, response)) == nil)
        }
    }

    @Test("the store drops the least recently used response first")
    func storeDropsLeastRecentlyUsedResponse() {
        let store = LocalResponseConversationStore(maxResponses: 2)
        store.save(responseID: "a", conversation: Data("[1]".utf8))
        store.save(responseID: "b", conversation: Data("[2]".utf8))
        #expect(store.conversation(for: "a") != nil)
        store.save(responseID: "c", conversation: Data("[3]".utf8))
        #expect(store.conversation(for: "a") == Data("[1]".utf8))
        #expect(store.conversation(for: "b") == nil)
        #expect(store.conversation(for: "c") == Data("[3]".utf8))
    }

    @Test("the store stays within its byte budget")
    func storeStaysWithinItsByteBudget() {
        let store = LocalResponseConversationStore(maxBytes: 10)
        store.save(responseID: "a", conversation: Data("[\"aaaa\"]".utf8))
        store.save(responseID: "b", conversation: Data("[\"bbbb\"]".utf8))
        #expect(store.conversation(for: "a") == nil)
        #expect(store.conversation(for: "b") != nil)
        store.save(responseID: "c", conversation: Data("[\"cccccccc\"]".utf8))
        #expect(store.conversation(for: "c") == nil)
        #expect(store.conversation(for: "b") != nil)
    }

    @Test("a recorded stream passes every frame through and remembers its response")
    func recordingPassesFramesThroughAndRemembersTheCompletedResponse() async throws {
        let store = LocalResponseConversationStore()
        let first = try prepared(#"{"model":"m","input":"My name is Ada.","stream":true}"#, store)
        let inProgress = OpenAIResponse(id: "resp_1", status: .inProgress, model: "m", output: [], outputText: "", usage: nil)
        let completed = OpenAIResponse(
            id: "resp_1", status: .completed, model: "m",
            output: [.message(id: "msg_1", text: "Hello Ada.")], outputText: "Hello Ada.", usage: nil)
        let frames = [try frame("response.created", inProgress), try frame("response.completed", completed)]
        let source = AsyncThrowingStream<String, Error> { continuation in
            for frame in frames { continuation.yield(frame) }
            continuation.finish()
        }
        var passed: [String] = []
        for try await frame in store.recording(source, inputItems: first.items) { passed.append(frame) }
        #expect(passed == frames)

        let second = try prepared(#"{"model":"m","previous_response_id":"resp_1","input":"What is my name?"}"#, store)
        #expect(try messages(try #require(second.body)) == [
            .init(role: .user, content: .text("My name is Ada.")),
            .init(role: .assistant, content: .text("Hello Ada.")),
            .init(role: .user, content: .text("What is my name?")),
        ])
    }
}
