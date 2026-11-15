import Foundation
import Testing

@testable import ProviderCore

/// Hostile `$ref` shapes on the local API (review of #2041, B1 and B2): a
/// reference whose target is not a schema object must not abort the process,
/// and reference chains must not recurse or work without bound. The
/// cooperative pool runs request tasks on 512 KiB stacks, so the chains run on
/// one.
@Suite("tool-schema $ref resolution: hostile shapes")
struct ToolSchemaRefResolutionSafetyTests {
    private static func body(_ parameters: String) -> Data {
        Data(##"{"model":"gemma-4-26b-qat-4bit","messages":[{"role":"user","content":"hi"}],"tools":[{"type":"function","function":{"name":"f","parameters":"## + parameters + "}}]}")
    }

    private static func parameters(of data: Data) throws -> [String: Any] {
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tools = try #require(root["tools"] as? [Any])
        let tool = try #require(tools.first as? [String: Any])
        let function = try #require(tool["function"] as? [String: Any])
        return try #require(function["parameters"] as? [String: Any])
    }

    /// `n` aliases `a0 -> a1 -> ... -> a(n-1)`, the last an object; property
    /// `x` references `a0`.
    private static func aliasChain(_ n: Int) -> String {
        var defs: [String] = []
        defs.reserveCapacity(n)
        for index in 0..<(n - 1) { defs.append(##""a\##(index)":{"$ref":"#/$defs/a\##(index + 1)"}"##) }
        defs.append(##""a\##(n - 1)":{"type":"object","properties":{"v":{"type":"string"}}}"##)
        return ##"{"type":"object","properties":{"x":{"$ref":"#/$defs/a0"}},"$defs":{"## + defs.joined(separator: ",") + "}}"
    }

    /// `n` definitions, each an object whose property `next` references the
    /// following one at nesting `width`: inlining would build `n * width`
    /// levels.
    private static func nestedChain(_ n: Int, width: Int) -> String {
        var defs: [String] = []
        for index in 0..<n {
            let inner = index + 1 < n ? ##"{"$ref":"#/$defs/d\##(index + 1)"}"## : ##"{"type":"string"}"##
            var node = inner
            for _ in 0..<width { node = ##"{"type":"object","properties":{"next":"## + node + "}}" }
            defs.append(##""d\##(index)":"## + node)
        }
        return ##"{"type":"object","properties":{"x":{"$ref":"#/$defs/d0"}},"$defs":{"## + defs.joined(separator: ",") + "}}"
    }

    /// Runs `body` on a thread with the cooperative pool's 512 KiB stack.
    private static func onSmallStack(_ body: @escaping @Sendable () -> Data) async -> Data {
        await withCheckedContinuation { continuation in
            let thread = Thread { continuation.resume(returning: body()) }
            thread.stackSize = 512 * 1024
            thread.start()
        }
    }

    @Test("a reference whose target is not a schema object leaves the schema typed, not an aborted process",
          arguments: [
              (##"{"$ref":"#/$ref"}"##, "#/$ref"),
              (##"{"$ref":"#/$defs/b","$defs":{"b":true}}"##, "#/$defs/b"),
              (##"{"$ref":"#/$defs/s","$defs":{"s":"text"}}"##, "#/$defs/s"),
              (##"{"$ref":"#/$defs/n","$defs":{"n":[1,2]}}"##, "#/$defs/n"),
          ])
    func nonObjectRootTargets(parameters: String, ref: String) throws {
        for mode in [ToolSchemaRefMode.inline, .typed] {
            let out = ToolSchemaRefResolution.resolveBody(Self.body(parameters), mode: mode)
            let resolved = try Self.parameters(of: out)
            #expect(resolved["$ref"] as? String == ref)
            #expect(resolved["type"] as? String == "object")
        }
    }

    @Test("a non-object target below the root is kept, typed object", .timeLimit(.minutes(1)))
    func nonObjectInnerTarget() throws {
        let parameters = ##"{"type":"object","properties":{"x":{"$ref":"#/$defs/s"}},"$defs":{"s":"text"}}"##
        let out = ToolSchemaRefResolution.resolveBody(Self.body(parameters), mode: .inline)
        let resolved = try Self.parameters(of: out)
        let x = try #require((resolved["properties"] as? [String: Any])?["x"] as? [String: Any])
        #expect(x["$ref"] as? String == "#/$defs/s")
        #expect(x["type"] as? String == "object")
    }

    @Test("long alias chains finish on a 512 KiB stack, kept and typed", .timeLimit(.minutes(1)),
          arguments: [2_000, 20_000])
    func aliasChainsOnTheCooperativeStack(length: Int) async throws {
        for mode in [ToolSchemaRefMode.inline, .typed] {
            let input = Self.body(Self.aliasChain(length))
            let start = ContinuousClock.now
            let out = await Self.onSmallStack { ToolSchemaRefResolution.resolveBody(input, mode: mode) }
            #expect(ContinuousClock.now - start < .seconds(5))
            let resolved = try Self.parameters(of: out)
            let x = try #require((resolved["properties"] as? [String: Any])?["x"] as? [String: Any])
            #expect(x["$ref"] as? String == "#/$defs/a0")
            #expect(x["type"] as? String == "object")
        }
    }

    @Test("a short alias chain still inlines", .timeLimit(.minutes(1)))
    func shortAliasChainInlines() throws {
        let out = ToolSchemaRefResolution.resolveBody(Self.body(Self.aliasChain(8)), mode: .inline)
        let resolved = try Self.parameters(of: out)
        let x = try #require((resolved["properties"] as? [String: Any])?["x"] as? [String: Any])
        #expect(x["$ref"] == nil)
        #expect(x["type"] as? String == "object")
        #expect((x["properties"] as? [String: Any])?["v"] != nil)
    }

    @Test("a chain of nested targets finishes on a 512 KiB stack", .timeLimit(.minutes(1)))
    func nestedChainOnTheCooperativeStack() async throws {
        let input = Self.body(Self.nestedChain(200, width: 20))
        let out = await Self.onSmallStack { ToolSchemaRefResolution.resolveBody(input, mode: .inline) }
        let resolved = try Self.parameters(of: out)
        let x = try #require((resolved["properties"] as? [String: Any])?["x"] as? [String: Any])
        #expect(x["$ref"] as? String == "#/$defs/d0")
    }

    @Test("one reference into a 4,000-alias chain types quickly", .timeLimit(.minutes(1)))
    func aliasChainWorkIsBounded() throws {
        let input = Self.body(Self.aliasChain(4_000))
        let start = ContinuousClock.now
        _ = ToolSchemaRefResolution.resolveBody(input, mode: .typed)
        _ = ToolSchemaRefResolution.resolveBody(input, mode: .inline)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test("the mode setting reaches the installed provider job")
    func modeSettingIsForwardedToTheService() {
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(ToolSchemaRefPolicy.environmentKey))
    }
}
