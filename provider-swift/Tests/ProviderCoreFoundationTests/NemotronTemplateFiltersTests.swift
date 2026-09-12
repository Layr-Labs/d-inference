// Copyright © 2026 Eigen Labs.

import Jinja
import Testing
@testable import ProviderCoreFoundation

struct NemotronTemplateFiltersTests {
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
