import Foundation
import Testing

@testable import ProviderCore

/// `JSONNestingLimit` refuses a body before any recursive parser reads it.
/// The provider decodes on Swift concurrency's 512 KiB task stacks, where a
/// few KB nested a few hundred levels (128 in a debug build) crashed the
/// process with SIGBUS.
@Suite("Inbound JSON nesting limit")
struct InboundJSONDepthTests {
    /// A `"tools"` member whose one tool parameter nests `depth` arrays.
    static func toolsField(nesting depth: Int) -> String {
        var schema = #"{"type":"string"}"#
        for _ in 0 ..< depth { schema = #"{"type":"array","items":"# + schema + "}" }
        return #""tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"x":"#
            + schema + "}}}}]"
    }

    /// A `"messages"` member whose assistant turn calls a tool with `depth`
    /// nested arrays as its JSON-encoded `arguments` string.
    static func messagesField(argumentNesting depth: Int) -> String {
        messagesField(arguments: String(repeating: "[", count: depth) + String(repeating: "]", count: depth))
    }

    /// A `"messages"` member whose assistant turn calls a tool with
    /// `arguments`, written as the inside of a JSON string.
    static func messagesField(arguments: String) -> String {
        #""messages":[{"role":"user","content":"hi"},{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"f","arguments":"\#(arguments)"}}]},{"role":"tool","tool_call_id":"c1","content":"ok"}]"#
    }

    /// A chat body whose one tool parameter nests `depth` arrays.
    static func body(nesting depth: Int) -> Data {
        Data((#"{"model":"m","messages":[{"role":"user","content":"hi"}],"# + toolsField(nesting: depth) + "}").utf8)
    }

    @Test("the scan counts open containers and skips brackets inside strings")
    func scanCountsContainers() {
        func nested(_ depth: Int) -> Data {
            Data((String(repeating: "[", count: depth) + String(repeating: "]", count: depth)).utf8)
        }
        #expect(!JSONNestingLimit.refuses(nested(JSONNestingLimit.maximumDepth)))
        #expect(JSONNestingLimit.refuses(nested(JSONNestingLimit.maximumDepth + 1)))
        // Brackets and an escaped quote inside a string are text.
        let quoted = #"{"a":"\#(String(repeating: "[{", count: 500))\"]}"}"#
        #expect(!JSONNestingLimit.refuses(Data(quoted.utf8)))
        // An escaped backslash leaves the quote after it unescaped: the string
        // ends there, so the brackets that follow count.
        let afterBackslash = Data(#"["\\","#.utf8) + nested(JSONNestingLimit.maximumDepth) + Data("]".utf8)
        #expect(JSONNestingLimit.refuses(afterBackslash))
    }

    @Test("a UTF-16 or UTF-32 body, whose bytes the scan cannot count, is refused")
    func nonUTF8BodiesAreRefused() async throws {
        // The escaped quote's backslash escapes a NUL byte in these encodings,
        // so the scan's string state inverts at the quote and it counts none of
        // the schema's levels: only the NUL refuses these bodies.
        let text = #"{"model":"m","messages":[{"role":"user","content":"\""}],"# + Self.toolsField(nesting: 400) + "}"
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian] {
            let body = try #require(text.data(using: encoding))
            let refused = JSONNestingLimit.refuses(body)
            #expect(refused, "\(encoding)")
            // Decoding a body the scan let through would end the test process.
            guard refused else { continue }
            let failure = await Task.detached { () -> (any Error)? in
                do {
                    _ = try ProviderLoop.decodeInboundChatRequest(body)
                    return nil
                } catch {
                    return error
                }
            }.value
            #expect(failure.map { InferenceRefusalReason(chatDecodeFailure: $0) } == .malformedBody, "\(encoding)")
        }
    }

    @Test("tool-call arguments nested past the limit are refused, not left to the renderer")
    func deepToolCallArgumentsAreRefused() throws {
        // The second's bytes nest one level, but for its NULs Foundation reads
        // it as UTF-16: `["\"",[[[…`, 400 levels deep.
        let utf16 = #"[\u0000\"\u0000\\\u0000\"\u0000\"\u0000,\u0000"# + String(repeating: #"[\u0000"#, count: 400)
        for messages in [Self.messagesField(argumentNesting: 400), Self.messagesField(arguments: utf16)] {
            let deep = Data(("{\"model\":\"m\"," + messages + "}").utf8)
            #expect(!JSONNestingLimit.refuses(deep), "the body itself is shallow; the depth is inside a string")
            let error = #expect(throws: (any Error).self) { _ = try ProviderLoop.decodeInboundChatRequest(deep) }
            #expect(error.map { InferenceRefusalReason(chatDecodeFailure: $0) } == .invalidToolArguments)
        }
        let ordinary = Data(("{\"model\":\"m\"," + Self.messagesField(argumentNesting: 8) + "}").utf8)
        #expect(try ProviderLoop.decodeInboundChatRequest(ordinary).request.messages.count == 3)
    }

    @Test("a body nested past the limit is refused before parsing, on a task's stack")
    func deepBodyIsRefusedOnTaskStack() async throws {
        let body = Self.body(nesting: 400)
        let failure = await Task.detached { () -> (any Error)? in
            do {
                _ = try ProviderLoop.decodeInboundChatRequest(body)
                return nil
            } catch {
                return error
            }
        }.value
        let error = try #require(failure)
        #expect(InferenceRefusalReason(chatDecodeFailure: error) == .malformedBody)
    }

    @Test("the deepest body the limit accepts still decodes on a task's stack")
    func deepestAcceptedBodyDecodes() async throws {
        let nesting = try #require((0 ... JSONNestingLimit.maximumDepth).last(where: {
            !JSONNestingLimit.refuses(Self.body(nesting: $0))
        }))
        #expect(JSONNestingLimit.refuses(Self.body(nesting: nesting + 1)))
        let body = Self.body(nesting: nesting)
        let decoded = try await Task.detached { try ProviderLoop.decodeInboundChatRequest(body) }.value
        #expect(decoded.request.tools?.count == 1)
    }
}
