import Foundation
import MLXLMCommon
import MLXLMServer
@testable import ProviderCore
import Testing

extension GemmaToolConstraintTests {
    @Test("unsupported constrained schema fails before engine submission")
    func unsupportedSchemaFailsClosed() {
        let unsupported: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object([
                    "oneOf": .array([
                        .object(["type": .string("string")]),
                        .object(["type": .string("integer")]),
                    ]),
                ]),
            ]),
        ])
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try ToolChoicePromptPolicy.prepare(
                request(choice: .mode(.required), tools: [
                    tool(parameters: unsupported),
                ]))
        }
    }

    @Test("provider normalization consumes the shared tool-schema corpus")
    func sharedToolSchemaNormalizationFixtures() throws {
        var fixtureRoot = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { fixtureRoot.deleteLastPathComponent() }
        let fixtureURL = fixtureRoot.appendingPathComponent(
            "fixtures/tool-schema/v1/normalization.json")
        let corpus = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fixtureURL)) as? [String: Any])
        #expect((corpus["schema_version"] as? NSNumber)?.intValue == 1)
        let fixtures = try #require(corpus["cases"] as? [[String: Any]])
        #expect(!fixtures.isEmpty)
        let names = fixtures.compactMap { $0["name"] as? String }
        #expect(names.count == fixtures.count)
        #expect(Set(names).count == names.count)

        for fixture in fixtures {
            let input = try #require(fixture["input"])
            let expected = try #require(fixture["normalized"])
            let inputData = try JSONSerialization.data(withJSONObject: input)
            let normalized = ToolSchemaNormalization.ensureParameterTypes(
                in: inputData)
            let actualObject = try JSONSerialization.jsonObject(with: normalized)
            let actual = try JSONSerialization.data(
                withJSONObject: actualObject, options: [.sortedKeys])
            let expectedData = try JSONSerialization.data(
                withJSONObject: expected, options: [.sortedKeys])
            #expect(
                actual == expectedData,
                "shared normalization fixture failed: \(fixture["name"] ?? "unnamed")")
        }
    }

    @Test("unimplemented schema assertions never become prompt-only theater")
    func unknownSchemaKeywordFailsClosed() {
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "minProperties": .int(1),
        ])
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .mode(.required),
                    tools: [tool(parameters: parameters)]))
        }
    }

    @Test("provider grammar complexity fails before vocabulary construction")
    func grammarComplexityFailsBeforeVocabularyBuild() {
        var value: MLXLMCommon.JSONValue = .object([
            "type": .string("string"),
        ])
        for _ in 0 ..< 4 {
            value = .object([
                "type": .string("array"),
                "items": value,
                "maxItems": .int(16),
            ])
        }
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["value": value]),
        ])
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try ToolChoicePromptPolicy.prepare(
                request(
                    choice: .mode(.required),
                    tools: [tool(parameters: parameters)]))
        }
    }
    @Test("nullable branches count toward the grammar complexity ceiling")
    func nullableBranchesAreCharged() {
        var properties: [String: MLXLMCommon.JSONValue] = [:]
        for index in 0 ..< 128 {
            properties["p\(index)"] = .object([
                "type": .array([.string("string"), .string("null")]),
                "enum": .array([.null]),
            ])
        }
        let parameters: MLXLMCommon.JSONValue = .object([
            "type": .string("object"),
            "properties": .object(properties),
        ])
        let tools = (0 ..< 64).map {
            tool(name: "tool\($0)", parameters: parameters)
        }
        #expect(throws: MultiModelBatchSchedulerEngineError.self) {
            _ = try ToolChoicePromptPolicy.prepare(
                request(choice: .mode(.required), tools: tools))
        }
    }
}
