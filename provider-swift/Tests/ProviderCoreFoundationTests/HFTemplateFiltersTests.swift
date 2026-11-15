// Copyright © 2026 Eigen Labs.

import Foundation
import Jinja
import Testing
@testable import ProviderCoreFoundation

/// Expected strings are CPython 3 `json.dumps` and `str` of the same values.
struct HFTemplateFiltersTests {
    private static let parameters: Value = .object([
        "b": .int(1),
        "a": .array([.double(1.0), .double(2.5), .double(1e16), .double(1e-5),
                     .double(123456789012345678.0), .double(-0.0), .boolean(true), .null, .string("x")]),
        "e": .object([:]),
        "l": .array([]),
    ])
    private static let tool: Value = .object([
        "type": .string("function"),
        "function": .object([
            "name": .string("f/g"),
            "description": .string("Zürich ☃ 😀 \"q\" \\ \n\t\u{01}\u{7F}"),
            "parameters": parameters,
        ]),
    ])

    private func render(_ source: String, _ context: [String: Value], requested: Bool = true,
                        modelType: String = "qwen3_5", environment: [String: String] = [:]) throws -> String {
        let template = try Template(
            HFTemplateFilters.bindingFilters(in: source, modelType: modelType, environment: environment),
            with: .init(lstripBlocks: true, trimBlocks: true))
        var full = context
        for (key, value) in HFTemplateFilters.bindingContext(modelType: modelType, environment: environment) ?? [:] {
            full[key] = try Value(any: value)
        }
        if requested {
            for (key, value) in HFTemplateFilters.requestContext() { full[key] = try Value(any: value) }
        }
        return try template.render(full)
    }

    @Test func tojsonIsTransformersJSONDumps() throws {
        let numbers = #"[1.0, 2.5, 1e+16, 1e-05, 1.2345678901234568e+17, -0.0, true, null, "x"]"#
        #expect(try render("{{ tool | tojson }}", ["tool": Self.tool]) ==
            #"{"type": "function", "function": {"name": "f/g", "description": "Zürich ☃ 😀 \"q\" \\ \n\t\u0001"#
            + "\u{7F}" + #"", "parameters": {"b": 1, "a": "# + numbers + #", "e": {}, "l": []}}}"#)
        #expect(try render("{{ tool | tojson(ensure_ascii=true) }}", ["tool": Self.tool]) ==
            #"{"type": "function", "function": {"name": "f/g", "description": "Z\u00fcrich \u2603 \ud83d\ude00 \"q\" \\ \n\t\u0001\u007f", "parameters": {"b": 1, "a": "#
            + numbers + #", "e": {}, "l": []}}}"#)
        #expect(try render("{{ p | tojson(ensure_ascii=false) }}", ["p": Self.parameters]) ==
            #"{"b": 1, "a": "# + numbers + #", "e": {}, "l": []}"#)
        #expect(try render("{{ p | tojson(indent=2) }}", ["p": Self.parameters]) == """
            {
              "b": 1,
              "a": [
                1.0,
                2.5,
                1e+16,
                1e-05,
                1.2345678901234568e+17,
                -0.0,
                true,
                null,
                "x"
              ],
              "e": {},
              "l": []
            }
            """)
        #expect(try render(#"{{ p | tojson(separators=[",", ":"], sort_keys=true) }}"#, ["p": Self.parameters]) ==
            #"{"a":[1.0,2.5,1e+16,1e-05,1.2345678901234568e+17,-0.0,true,null,"x"],"b":1,"e":{},"l":[]}"#)
    }

    @Test func stringIsPythonStrAndLeavesTheStringTestAlone() throws {
        let source = "{{ t | string }} {{ n | string }} {{ f | string }} {{ big | string }} {{ d | string }}"
            + " {{ q | string }} {{ s | string }} {{ t is string }} {{ s is string }} {{ '| string' }}"
        let context: [String: Value] = [
            "t": .boolean(true), "n": .null, "f": .double(0.15), "big": .double(1e16),
            "d": .object(["a": .array([.int(1), .string("it's"), .null, .boolean(false), .double(2.0)])]),
            "q": .array([.string("say \"hi\""), .string("x")]), "s": .string("text"),
        ]
        #expect(try render(source, context) ==
            #"True None 0.15 1e+16 {'a': [1, "it's", None, False, 2.0]} ['say "hi"', 'x'] text false true | string"#)
    }

    @Test func aRenderThatAsksForNothingKeepsSwiftJinjasFilters() throws {
        let source = "{{ t | string }} {{ n | string }} {{ tool | tojson }}"
        let context: [String: Value] = ["t": .boolean(true), "n": .null, "tool": Self.tool]
        let unchanged = try Template(source, with: .init(lstripBlocks: true, trimBlocks: true)).render(context)
        #expect(try render(source, context, requested: false) == unchanged)
        #expect(unchanged.hasPrefix(#"true "#))
        #expect(HFTemplateFilters.bindingFilters(in: source, modelType: "qwen3_5") != source)
    }

    @Test func unlistedFamiliesAndTheLegacySwitchKeepTheTemplate() throws {
        let source = "{{ t | string }}"
        for modelType in ["gemma4", "nemotron_h", "nemotron_h_omni", "flint"] {
            #expect(HFTemplateFilters.bindingFilters(in: source, modelType: modelType) == source)
            #expect(HFTemplateFilters.bindingContext(modelType: modelType) == nil)
        }
        for modelType in ["qwen3_5", "qwen3_5_moe", "prism_hadamard_qwen35", "mimo_v2", "glm5_next", "gpt_oss"] {
            #expect(HFTemplateFilters.applies(modelType: modelType, environment: [:]))
            for value in ["1", "true", "on"] {
                let legacy = [HFTemplateFilters.legacyEnvironmentKey: value]
                #expect(!HFTemplateFilters.applies(modelType: modelType, environment: legacy))
                #expect(HFTemplateFilters.bindingFilters(in: source, modelType: modelType, environment: legacy) == source)
            }
        }
    }

    @Test func unsupportedArgumentsFailClosed() throws {
        #expect(throws: (any Error).self) { try render("{{ [1] | tojson(default=1) }}", [:]) }
        #expect(throws: (any Error).self) { try render(#"{{ [1] | tojson(separators=[","]) }}"#, [:]) }
        #expect(throws: (any Error).self) { try render("{{ 1 | string(2) }}", [:]) }
    }
}
