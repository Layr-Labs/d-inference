import Foundation
import Testing

@testable import ProviderCore

/// `JSONNestingLimit` refuses a body before any recursive parser reads it.
/// The provider decodes on Swift concurrency's 512 KiB task stacks, where a
/// few KB nested a few hundred levels (128 in a debug build) crashed the
/// process with SIGBUS.
@Suite("Inbound JSON nesting limit")
struct InboundJSONDepthTests {
    /// A chat body whose one tool parameter nests `depth` arrays.
    static func body(nesting depth: Int) -> Data {
        var schema = #"{"type":"string"}"#
        for _ in 0 ..< depth { schema = #"{"type":"array","items":"# + schema + "}" }
        return Data((#"{"model":"m","messages":[{"role":"user","content":"hi"}],"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"x":"#
            + schema + "}}}}]}").utf8)
    }

    @Test("the scan counts open containers and skips brackets inside strings")
    func scanCountsContainers() {
        func nested(_ depth: Int) -> Data {
            Data((String(repeating: "[", count: depth) + String(repeating: "]", count: depth)).utf8)
        }
        #expect(!JSONNestingLimit.exceeds(nested(JSONNestingLimit.maximumDepth)))
        #expect(JSONNestingLimit.exceeds(nested(JSONNestingLimit.maximumDepth + 1)))
        // Brackets and an escaped quote inside a string are text.
        let quoted = #"{"a":"\#(String(repeating: "[{", count: 500))\"]}"}"#
        #expect(!JSONNestingLimit.exceeds(Data(quoted.utf8)))
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

    @Test("ordinary nesting still decodes on a task's stack")
    func ordinaryNestingDecodes() async throws {
        let body = Self.body(nesting: 40)
        let decoded = try await Task.detached { try ProviderLoop.decodeInboundChatRequest(body) }.value
        #expect(decoded.request.tools?.count == 1)
    }
}
