import Foundation
import Testing

@testable import ProviderCore

/// Hostile `$ref` shapes on the local API: a
/// reference whose target is not a schema object must not abort the process,
/// and reference chains must not recurse or work without bound. The
/// cooperative pool runs request tasks on 512 KiB stacks, so the chains run on
/// one.
@Suite("tool-schema $ref resolution: hostile shapes")
struct ToolSchemaRefResolutionSafetyTests {
    private static func body(_ parameters: String) -> Data {
        body(tools: [##"{"type":"function","function":{"name":"f","parameters":"## + parameters + "}}"])
    }

    private static func body(tools: [String]) -> Data {
        let text = ##"{"model":"gemma-4-26b-qat-4bit","messages":[{"role":"user","content":"hi"}],"tools":["##
            + tools.joined(separator: ",") + "]}"
        return Data(text.utf8)
    }

    private static func parameters(of data: Data) throws -> [String: Any] {
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tools = try #require(root["tools"] as? [Any])
        let tool = try #require(tools.first as? [String: Any])
        let function = try #require(tool["function"] as? [String: Any])
        return try #require(function["parameters"] as? [String: Any])
    }

    /// The schema of property `name` in the resolved parameters.
    private static func property(_ name: String, of data: Data) throws -> [String: Any] {
        let resolved = try parameters(of: data)
        return try #require((resolved["properties"] as? [String: Any])?[name] as? [String: Any])
    }

    /// `n` aliases `a0 -> a1 -> ... -> a(n-1)`, the last an object; property
    /// `x` references `a0`.
    private static func aliasChain(_ n: Int, end: String = ##"{"type":"object","properties":{"v":{"type":"string"}}}"##)
        -> String
    {
        var defs: [String] = []
        defs.reserveCapacity(n)
        for index in 0..<(n - 1) { defs.append(##""a\##(index)":{"$ref":"#/$defs/a\##(index + 1)"}"##) }
        defs.append(##""a\##(n - 1)":"## + end)
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

    @Test("a root reference to a boolean schema inlines as a conjunction in an object, or is typed")
    func booleanRootTarget() throws {
        let parameters = ##"{"$ref":"#/$defs/b","$defs":{"b":true}}"##
        let inlined = try Self.parameters(of: ToolSchemaRefResolution.resolveBody(Self.body(parameters), mode: .inline))
        #expect((inlined["allOf"] as? [Any])?.count == 1)
        #expect(inlined["$ref"] == nil)
        let typed = try Self.parameters(of: ToolSchemaRefResolution.resolveBody(Self.body(parameters), mode: .typed))
        #expect(typed["$ref"] as? String == "#/$defs/b")
        #expect(typed["type"] as? String == "object")
    }

    @Test("a non-object target below the root is kept, typed object", .timeLimit(.minutes(1)))
    func nonObjectInnerTarget() throws {
        let parameters = ##"{"type":"object","properties":{"x":{"$ref":"#/$defs/s"}},"$defs":{"s":"text"}}"##
        let out = ToolSchemaRefResolution.resolveBody(Self.body(parameters), mode: .inline)
        let x = try Self.property("x", of: out)
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
            let x = try Self.property("x", of: out)
            #expect(x["$ref"] as? String == "#/$defs/a0")
            #expect(x["type"] as? String == "object")
        }
    }

    @Test("a short alias chain still inlines", .timeLimit(.minutes(1)))
    func shortAliasChainInlines() throws {
        let out = ToolSchemaRefResolution.resolveBody(Self.body(Self.aliasChain(8)), mode: .inline)
        let x = try Self.property("x", of: out)
        #expect(x["$ref"] == nil)
        #expect(x["type"] as? String == "object")
        #expect((x["properties"] as? [String: Any])?["v"] != nil)
    }

    @Test("a chain of nested targets finishes on a 512 KiB stack", .timeLimit(.minutes(1)))
    func nestedChainOnTheCooperativeStack() async throws {
        let input = Self.body(Self.nestedChain(200, width: 20))
        let out = await Self.onSmallStack { ToolSchemaRefResolution.resolveBody(input, mode: .inline) }
        let x = try Self.property("x", of: out)
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

    @Test("an alias chain past 32 hops keeps its reference, typed, in both modes")
    func aliasChainPastTheHopCap() throws {
        for mode in [ToolSchemaRefMode.inline, .typed] {
            let chain = Self.aliasChain(40, end: ##"{"type":"string"}"##)
            let out = ToolSchemaRefResolution.resolveBody(Self.body(chain), mode: mode)
            let x = try Self.property("x", of: out)
            #expect(x["$ref"] as? String == "#/$defs/a0")
            // The cut-off decides, not the chain's end.
            #expect(x["type"] as? String == "object")
        }
    }

    @Test("a pointer longer than 1,024 bytes or 32 tokens is unresolved")
    func longPointersAreUnresolved() throws {
        let long = String(repeating: "a", count: 1_100)
        let deep = (0..<33).map { _ in "x" }.joined(separator: "/")
        for ref in ["#/$defs/" + long, "#/" + deep] {
            let parameters = ##"{"type":"object","properties":{"p":{"$ref":""## + ref
                + ##""}},"$defs":{"## + "\"\(long)\":{\"type\":\"string\"}" + "}}"
            let out = ToolSchemaRefResolution.resolveBody(Self.body(parameters), mode: .inline)
            let p = try Self.property("p", of: out)
            #expect(p["$ref"] as? String == ref)
            #expect(p["type"] as? String == "object")
        }
    }

    /// Many sites share one target whose own pointer is long: each site must not
    /// parse it again.
    @Test("sixty thousand sites sharing a long-pointer target type quickly on a 512 KiB stack",
          .timeLimit(.minutes(1)))
    func manySitesShareALongPointer() async throws {
        let name = String(repeating: "a", count: 1_000)
        var properties: [String] = []
        properties.reserveCapacity(60_000)
        for index in 0..<60_000 { properties.append(##""p\##(index)":{"$ref":"#/$defs/A"}"##) }
        // The shared target also carries 5,000 annotation keys, so looking it up
        // as a Swift dictionary at every site would copy them every time.
        let annotations = (0..<5_000).map { ##""x\##($0)":0"## }.joined(separator: ",")
        let parameters = ##"{"type":"object","properties":{"## + properties.joined(separator: ",")
            + ##"},"$defs":{"A":{"$ref":"#/$defs/"## + name + ##"","## + annotations + ##"},""## + name
            + ##"":{"type":"string"}}}"##
        let input = Self.body(parameters)
        for mode in [ToolSchemaRefMode.inline, .typed] {
            let start = ContinuousClock.now
            let out = await Self.onSmallStack { ToolSchemaRefResolution.resolveBody(input, mode: mode) }
            #expect(ContinuousClock.now - start < .seconds(15))
            let p = try Self.property("p0", of: out)
            #expect(p["type"] as? String == "string")
        }
    }

    /// Many tools, each with expensive typing: the work is one budget for the
    /// whole request, not one per schema.
    @Test("a request's typing work is bounded across its tools", .timeLimit(.minutes(1)))
    func typingWorkIsBoundedAcrossTools() throws {
        let chain = (0..<30).map { ##""n\##($0)":{"$ref":"#/$defs/n\##($0 + 1)"}"## }.joined(separator: ",")
            + ##","n30":{"type":"null"}"##
        let members = Array(repeating: ##"{"$ref":"#/$defs/n0"}"##, count: 32).joined(separator: ",")
        let properties = (0..<64).map { ##""p\##($0)":{"$ref":"#/$defs/T"}"## }.joined(separator: ",")
        let schema = ##"{"type":"object","properties":{"## + properties + ##"},"$defs":{"## + chain
            + ##","T":{"anyOf":["## + members + ##",{"type":"string"}]}}}"##
        let input = Self.body(tools: (0..<1_000).map {
            ##"{"type":"function","function":{"name":"t\##($0)","parameters":"## + schema + "}}"
        })
        let start = ContinuousClock.now
        _ = ToolSchemaRefResolution.resolveBody(input, mode: .typed)
        _ = ToolSchemaRefResolution.resolveBody(input, mode: .inline)
        #expect(ContinuousClock.now - start < .seconds(40))
    }

    /// An inline copies target text by bytes, not only by nodes: a large
    /// string referenced from many sites is not multiplied into the body.
    @Test("a large target referenced many times isn't copied into a huge body", .timeLimit(.minutes(1)),
          arguments: [false, true])
    func largeTargetsAreNotMultiplied(longPointer: Bool) async throws {
        let sites = longPointer ? 1_000 : 680
        let properties = (0..<sites).map { ##""p\##($0)":{"$ref":"#/$defs/T"}"## }.joined(separator: ",")
        let target = longPointer
            ? ##"{"$ref":"#/$defs/"## + String(repeating: "a", count: 4_000_000) + ##""}"##
            : ##"{"type":"string","description":""## + String(repeating: "x", count: 4_100_000) + ##""}"##
        let input = Self.body(##"{"properties":{"## + properties + ##"},"$defs":{"T":"## + target + "}}")
        #expect(input.count <= ToolSchemaNormalization.maxNormalizationBytes)
        let start = ContinuousClock.now
        let out = await Self.onSmallStack { ToolSchemaRefResolution.resolveBody(input, mode: .inline) }
        #expect(ContinuousClock.now - start < .seconds(15))
        #expect(out.count <= input.count + 256 * 1024)
        let p = try Self.property("p0", of: out)
        #expect(p["$ref"] as? String == "#/$defs/T")
        #expect(p["type"] as? String == (longPointer ? "object" : "string"))
    }

    /// The cycle search's visits grow with the request's schemas: in a batch
    /// of identical honest items the last item inlines as the first does.
    @Test("every item of a long honest batch inlines alike", .timeLimit(.minutes(1)))
    func longHonestBatchInlinesAlike() async throws {
        let properties = (0..<30).map { ##""p\##($0)":{"$ref":"#/$defs/d\##($0)"}"## }.joined(separator: ",")
        let defs = (0..<30).map { ##""d\##($0)":{"type":"object","properties":{"a":{"type":"string"}}}"## }
            .joined(separator: ",")
        let item = ##"{"model":"gemma-4-26b-qat-4bit","messages":[{"role":"user","content":"hi"}],"## + ##""tools":"##
            + ##"[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"## + properties
            + ##"},"$defs":{"## + defs + "}}}}]}"
        let batch = Data(("[" + Array(repeating: item, count: 800).joined(separator: ",") + "]").utf8)
        let resolved = await ToolSchemaRefResolution.resolveLocalBody(batch, batch: true) { _ in .inline }
        let items = try #require(try JSONSerialization.jsonObject(with: resolved) as? [[String: Any]])
        for index in [0, 799] {
            let tools = try #require(items[index]["tools"] as? [Any])
            let tool = try #require(tools.first as? [String: Any])
            let function = try #require(tool["function"] as? [String: Any])
            let parameters = try #require(function["parameters"] as? [String: Any])
            let p0 = try #require((parameters["properties"] as? [String: Any])?["p0"] as? [String: Any])
            #expect(p0["$ref"] == nil, "item \(index)")
            #expect(p0["properties"] != nil, "item \(index)")
        }
    }

    /// A remembered type is reused only where its hops fit under the cap from
    /// the asking reference, so the result doesn't depend on typing order.
    @Test("a shared chain types the same whichever reference is typed first")
    func chainTypesDoNotDependOnOrder() throws {
        let chain = (0..<39).map { ##""a\##($0)":{"$ref":"#/$defs/a\##($0 + 1)"}"## }.joined(separator: ",")
            + ##","a39":{"type":"string"}"##
        let parameters = ##"{"type":"object","properties":{"x":{"$ref":"#/$defs/a0"},"y":{"$ref":"#/$defs/a20"}},"##
            + ##""$defs":{"## + chain + "}}"
        for mode in [ToolSchemaRefMode.typed, .inline] {
            let out = ToolSchemaRefResolution.resolveBody(Self.body(parameters), mode: mode)
            #expect(try Self.property("x", of: out)["type"] as? String == "object")
            #expect(try Self.property("y", of: out)["type"] as? String == "string")
        }
    }

    @Test("more than 512 targets in one schema are kept, typed by target")
    func manyTargetsAreTyped() throws {
        let properties = (0..<600).map { ##""p\##($0)":{"$ref":"#/$defs/d\##($0)"}"## }.joined(separator: ",")
        let defs = (0..<600).map { ##""d\##($0)":{"type":"string"}"## }.joined(separator: ",")
        let out = ToolSchemaRefResolution.resolveBody(
            Self.body(##"{"type":"object","properties":{"## + properties + ##"},"$defs":{"## + defs + "}}"),
            mode: .inline)
        let p = try Self.property("p599", of: out)
        #expect(p["$ref"] as? String == "#/$defs/d599")
        #expect(p["type"] as? String == "string")
    }

    @Test("the mode setting reaches the installed provider job")
    func modeSettingIsForwardedToTheService() {
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(ToolSchemaRefPolicy.environmentKey))
    }
}
