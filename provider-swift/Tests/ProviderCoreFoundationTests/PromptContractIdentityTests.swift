import Foundation
import Testing

@testable import ProviderCoreFoundation

struct PromptContractIdentityTests {
    private struct Corpus: Decodable {
        let vectors: [Vector]
    }

    private struct Vector: Decodable {
        let artifacts: [ManifestFile]
        let expectedPromptContractId: String

        enum CodingKeys: String, CodingKey {
            case artifacts
            case expectedPromptContractId = "expected_prompt_contract_id"
        }
    }

    @Test("shared prompt-contract vectors match")
    func sharedVectors() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }
        let fixture = root.appendingPathComponent(
            "fixtures/prompt-contract/v1/contract_vectors.json")
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: fixture))
        for vector in corpus.vectors {
            #expect(
                try PromptContractIdentity.compute(files: vector.artifacts)
                    == vector.expectedPromptContractId)
        }
    }

    @Test("alternate template sources remain cold until runtime semantics are unified")
    func alternateTemplateDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "prompt-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents: [(String, Data)] = [
            ("config.json", Data(#"{"model_type":"fixture"}"#.utf8)),
            ("tokenizer.json", Data(#"{"version":"1.0"}"#.utf8)),
            ("tokenizer_config.json", Data(#"{"chat_template":"{{ messages }}"}"#.utf8)),
            ("chat_template.json", Data(#"{"chat_template":"{{ messages | list }}"}"#.utf8)),
            ("ignored.txt", Data("ignored".utf8)),
        ]
        for (name, data) in contents {
            try data.write(to: root.appendingPathComponent(name))
        }
        #expect(throws: PromptContractIdentity.Error.invalidArtifact) {
            try PromptContractIdentity.compute(modelDirectory: root)
        }
    }

    @Test("standalone chat template can replace tokenizer config")
    func standaloneTemplateDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "prompt-contract-standalone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"model_type":"fixture"}"#.utf8).write(
            to: root.appendingPathComponent("config.json"))
        try Data(#"{"version":"1.0"}"#.utf8).write(
            to: root.appendingPathComponent("tokenizer.json"))
        try Data("{{ messages }}".utf8).write(
            to: root.appendingPathComponent("chat_template.jinja"))

        #expect(try PromptContractIdentity.compute(modelDirectory: root).count == 64)
    }

    @Test("unsupported renderer semantics do not produce a contract identity")
    func unsupportedTemplateDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "prompt-contract-unsupported-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"model_type":"fixture"}"#.utf8).write(
            to: root.appendingPathComponent("config.json"))
        try Data(#"{"version":"1.0"}"#.utf8).write(
            to: root.appendingPathComponent("tokenizer.json"))
        try Data(#"{% include "unsupported.jinja" %}"#.utf8).write(
            to: root.appendingPathComponent("chat_template.jinja"))

        #expect(throws: PromptContractIdentity.Error.invalidArtifact) {
            try PromptContractIdentity.compute(modelDirectory: root)
        }
    }

    @Test("provider-local time keeps prompt caching cold")
    func dynamicTimeTemplateDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "prompt-contract-dynamic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"model_type":"fixture"}"#.utf8).write(
            to: root.appendingPathComponent("config.json"))
        try Data(#"{"version":"1.0"}"#.utf8).write(
            to: root.appendingPathComponent("tokenizer.json"))
        try Data(#"{{ strftime_now("%Y-%m-%d") }}"#.utf8).write(
            to: root.appendingPathComponent("chat_template.jinja"))

        #expect(throws: PromptContractIdentity.Error.invalidArtifact) {
            try PromptContractIdentity.compute(modelDirectory: root)
        }
    }

    @Test("shared request corpus covers every required serving shape")
    func sharedRequestCorpus() throws {
        struct Corpus: Decodable {
            let schemaVersion: Int
            let cases: [Fixture]

            enum CodingKeys: String, CodingKey {
                case schemaVersion = "schema_version"
                case cases
            }
        }
        struct Fixture: Decodable {
            let id: String
            let endpoint: String
            let scopeID: String
            let body: JSONValue

            enum CodingKeys: String, CodingKey {
                case id
                case endpoint
                case scopeID = "scope_id"
                case body
            }
        }
        enum JSONValue: Decodable {
            case object

            init(from decoder: Decoder) throws {
                _ = try decoder.container(keyedBy: DynamicKey.self)
                self = .object
            }
        }
        struct DynamicKey: CodingKey {
            let stringValue: String
            let intValue: Int?

            init?(stringValue: String) {
                self.stringValue = stringValue
                self.intValue = nil
            }

            init?(intValue: Int) {
                self.stringValue = String(intValue)
                self.intValue = intValue
            }
        }

        let corpus = try JSONDecoder().decode(
            Corpus.self,
            from: Data(contentsOf: fixtureRoot().appendingPathComponent("corpus.json")))
        #expect(corpus.schemaVersion == 1)
        let ids = Set(corpus.cases.map(\.id))
        #expect(ids.count == corpus.cases.count)
        #expect(corpus.cases.allSatisfy {
            !$0.id.isEmpty
                && !$0.scopeID.isEmpty
                && ["chat_completions", "completions", "responses", "messages"]
                    .contains($0.endpoint)
        })
        #expect(Set([
            "tools", "nulls", "harmony", "gemma", "reasoning_effort", "unicode",
            "endpoint_chat_completions", "endpoint_completions", "endpoint_responses",
            "endpoint_messages", "exact_block_multiple", "long_prompt",
        ]).isSubset(of: ids))
    }

    private func fixtureRoot() -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("fixtures/prompt-contract/v1")
    }
}
