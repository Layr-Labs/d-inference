// Copyright © 2026 Eigen Labs.

import Foundation
import Jinja
import Testing
@testable import ProviderCoreFoundation

struct NemotronTemplateFiltersTests {
    @Test func sharedNumberSpellingsMatchActualSwiftFilters() throws {
        struct Vector: Decodable { let bits: String; let rendered: String }
        struct Corpus: Decodable { let vectors: [Vector] }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf:
            root.appendingPathComponent("fixtures/prompt-contract/v1/nemotron_number_vectors.json")))
        #expect(corpus.vectors.count >= 512)
        let environment = Environment()
        NemotronTemplateFilters.install(in: environment, modelType: "nemotron_h")
        let template = try Template(NemotronTemplateFilters.bindingFilters(
            in: "{{ value|string }}|{{ value|tojson }}", modelType: "nemotron_h"))
        for vector in corpus.vectors {
            let value = Double(bitPattern: try #require(UInt64(vector.bits, radix: 16)))
            #expect(try template.render(["value": .double(value)], environment: environment)
                == vector.rendered + "|" + vector.rendered)
        }
    }

    @Test func nullableTypeArrayUsesStringDescription() throws {
        let environment = Environment()
        NemotronTemplateFilters.install(in: environment, modelType: "nemotron_h")
        let template = try Template(NemotronTemplateFilters.bindingFilters(
            in: "{{ value|string }}", modelType: "nemotron_h"))
        #expect(try template.render(["value": .array([.string("number"), .string("null")])],
            environment: environment) == "['number', 'null']")
    }

    @Test func matchesTransformersDefaultsUsedByNemotron() throws {
        let environment = Environment()
        NemotronTemplateFilters.install(in: environment, modelType: "nemotron_h")
        let template = try Template(NemotronTemplateFilters.bindingFilters(
            in: "{{ flag|string }}|{{ values|tojson }}|{{ object|tojson }}", modelType: "nemotron_h"))
        let context: [String: Value] = [
            "flag": .boolean(false),
            "values": .array([.string("celsius"), .string("fahrenheit")]),
            "object": .object([
                "city": .string("Montréal / 東京"),
                "valid": .boolean(true),
            ]),
        ]

        #expect(
            try template.render(context, environment: environment)
                == "False|[\"celsius\", \"fahrenheit\"]|{\"city\": \"Montréal / 東京\", \"valid\": true}")
    }

    @Test func nonNemotronFamiliesKeepTheirEnvironment() throws {
        let environment = Environment()
        environment["string"] = .function { _, _, _ in .string("unchanged") }
        NemotronTemplateFilters.install(in: environment, modelType: "qwen3_5")

        #expect(try Template("{{ false|string }}").render([:], environment: environment) == "unchanged")
        #expect(NemotronTemplateFilters.additionalContext(modelType: "gemma4") == nil)
    }

    @Test func unsupportedOptionsFailClosed() throws {
        let environment = Environment()
        NemotronTemplateFilters.install(in: environment, modelType: "nemotron_h")

        #expect(throws: (any Error).self) {
            try Template("{{ [1]|tojson(indent=2) }}").render([:], environment: environment)
        }
    }

    @Test func stringFilterDoesNotShadowStringTestOrLiterals() throws {
        let source = "literal | string {{ '| string' }} {{ '' is string }} {{ false is string }} {{ false | string }}"
        let bound = NemotronTemplateFilters.bindingFilters(in: source, modelType: "nemotron_h")
        let environment = Environment()
        NemotronTemplateFilters.install(in: environment, modelType: "nemotron_h")
        #expect(try Template(bound).render([:], environment: environment)
            == "literal | string | string true false False")
        #expect(NemotronTemplateFilters.bindingFilters(in: source, modelType: "qwen3_5") == source)
    }
}
