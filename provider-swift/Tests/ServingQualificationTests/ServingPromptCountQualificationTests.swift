import CryptoKit
import Foundation
import MLXLMCommon
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

/// Tokenizer/template-only corpus measurement. It never constructs a model,
/// touches Metal, downloads an artifact, or records rendered text/token IDs.
@Suite("Dedicated prompt count qualification", .serialized)
struct ServingPromptCountQualificationTests {
    struct Input: Decodable {
        let id: String
        let partition: String
        let family: String
        let request: Data
    }
    struct Observation: Encodable {
        let id: String
        let partition: String
        let family: String
        let workloadSHA256: String
        let actualPromptTokens: Int
        let failure: String?
    }
    struct Receipt: Encodable {
        let schemaVersion: Int
        let modelID: String
        let artifactSHA256: String
        let promptContractID: String
        let observations: [Observation]
        let qualified: Bool
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_PROMPT_COUNT_QUALIFICATION"] == "1",
                   "requires an explicit numeric prompt corpus job"))
    func collectTemplateCounts() async throws {
        let env = ProcessInfo.processInfo.environment
        let modelPath = try #require(env["DARKBLOOM_PROMPT_COUNT_MODEL_PATH"])
        let modelID = try #require(env["DARKBLOOM_PROMPT_COUNT_MODEL_ID"])
        let artifact = try #require(env["DARKBLOOM_PROMPT_COUNT_ARTIFACT_SHA256"])
        let inputPath = try #require(env["DARKBLOOM_PROMPT_COUNT_INPUT"])
        let outputPath = try #require(env["DARKBLOOM_PROMPT_COUNT_OUTPUT"])
        let directory = URL(fileURLWithPath: modelPath)
        let actualArtifact = try Self.verifiedArtifactHash(directory: directory, modelID: modelID, expected: artifact)
        let contract = try PromptContractIdentity.compute(modelDirectory: directory)
        let tokenizer = try await LocalTokenizerLoader().load(from: directory)
        let inputs = try JSONDecoder().decode([Input].self, from: Data(contentsOf: URL(fileURLWithPath: inputPath)))
        try #require(!inputs.isEmpty && inputs.count <= 10_000)
        var observations: [Observation] = []
        for input in inputs {
            var count = 0
            var failure: String?
            do {
                count = try ProviderPromptContractPipeline.tokenizeProviderBody(
                    input.request, tokenizer: tokenizer, modelType: "qwen3_5").count
            } catch {
                failure = "template_rejected"
            }
            observations.append(Observation(id: input.id, partition: input.partition, family: input.family,
                workloadSHA256: SHA256.hash(data: input.request).map { String(format: "%02x", $0) }.joined(),
                actualPromptTokens: count, failure: failure))
        }
        _ = try Self.verifiedArtifactHash(directory: directory, modelID: modelID, expected: actualArtifact)
        let receipt = Receipt(schemaVersion: 1, modelID: modelID, artifactSHA256: actualArtifact,
                              promptContractID: contract, observations: observations, qualified: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }

    static func verifiedArtifactHash(directory: URL, modelID: String, expected: String) throws -> String {
        guard let actual = WeightHasher.computeHash(snapshotDir: directory, modelID: modelID),
              actual == expected else { throw PromptCountArtifactFailure.mismatch }
        return actual
    }

}

private enum PromptCountArtifactFailure: Error { case mismatch }
