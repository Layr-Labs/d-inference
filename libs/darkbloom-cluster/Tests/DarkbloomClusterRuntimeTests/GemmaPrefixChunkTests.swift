import Foundation
import DarkbloomClusterProtocol
import Testing
@testable import DarkbloomClusterRuntime

@Suite("Registered Gemma prefix chunk policy")
struct GemmaPrefixChunkTests {
    private func request(profileID: String, count: Int, chunk: Int) throws -> QwenLayerStageGenerationRequest {
        let profile = try QwenLayerStageGenerationProfile(identifier: profileID, vocabularySize: 64,
            hiddenSize: 32, activationDType: "bfloat16", maximumPromptTokens: 32768,
            maximumChunkTokens: 512, maximumOutputTokens: 8, maximumContextTokens: 65536)
        return try .init(profile: profile, requestID: UUID(), promptTokenIDs: Array(repeating: 3, count: count),
            chunkSize: chunk, outputCount: 3, stopTokenIDs: [])
    }

    @Test func eachRegisteredAliasPreservesColdAndRestoredFrames() throws {
        let rows = ClusterRuntimeAdapter.gemma4LayerStage.registeredProfiles
        #expect(rows.count == 3)
        for row in rows {
            for count in [1, 2, 127, 128, 129, 511, 512, 513, 1023, 1024, 1025, 4096, 16384, 32768] {
                for chunk in [128, 384, 512] {
                    let original = try request(profileID: row.profileID, count: count, chunk: chunk)
                    #expect(original.preservesPrefixChunkGrid)
                    let cold = try original.planned(reusedPrefix: 0, splitFinalToken: true)
                    #expect(!cold.splitsFinalPromptToken)
                    #expect(try (0..<cold.forwardCount).map { try cold.frame(sequence: $0) }
                        == (0..<original.forwardCount).map { try original.frame(sequence: $0) })
                    let frontiers = cold.prefixCaptureFrontiers(stride: chunk)
                    #expect(frontiers.allSatisfy { $0 < count && $0 % chunk == 0 })
                    if let start = frontiers.max() {
                        let warm = try original.planned(reusedPrefix: start, splitFinalToken: true)
                        let expected = try (0..<cold.forwardCount).map { try cold.frame(sequence: $0) }.filter { $0.tokenOffset >= start }
                        let actual = try (0..<warm.forwardCount).map { try warm.frame(sequence: $0) }
                        #expect(actual.map(\.tokenOffset) == expected.map(\.tokenOffset))
                        #expect(actual.map(\.tokenCount) == expected.map(\.tokenCount))
                        #expect(actual.map(\.phase) == expected.map(\.phase))
                    }
                    if count > 1, (count - 1) % chunk != 0 {
                        #expect(throws: ProbeError.self) { _ = try original.planned(reusedPrefix: count - 1, splitFinalToken: true) }
                    }
                }
            }
        }
    }

    @Test func receiptChangesNamespaceWithoutChangingArithmeticSettings() throws {
        let receipt = try Gemma4ArithmeticEnvironment.admit(Gemma4ArithmeticEnvironment.requiredValues)
        let data = try canonicalJSONData(receipt)
        var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(old.removeValue(forKey: "prefixFramePolicy") as? String == "gemma4-original-chunk-grid-v1")
        #expect(receipt.contract == ClusterRuntimeAdapter.gemma4LayerStage.arithmeticPolicyID)
        #expect(receipt.requiredValues == Gemma4ArithmeticEnvironment.requiredValues)
        #expect(receipt.requiredAbsentNames == Gemma4ArithmeticEnvironment.requiredAbsentNames)
        #expect(receipt.finalLayerTailRows == 1 && receipt.finalLayerTailMinimumChunk == 128 && receipt.finalLayerLastQuery)
        #expect(sha256(data) != sha256(try JSONSerialization.data(withJSONObject: old, options: [.sortedKeys, .withoutEscapingSlashes])))
    }

    @Test func qwenBonsaiAndGLMKeepTheirFinalTokenSplit() throws {
        for adapter in [ClusterRuntimeAdapter.qwen35Dense, .qwen35RoutedExperts, .qwen35PrismHadamard, .glm5NextLayerStage] {
            for row in adapter.registeredProfiles {
                let request = try request(profileID: row.profileID, count: 1024, chunk: 512)
                #expect(!request.preservesPrefixChunkGrid)
                let planned = try request.planned(reusedPrefix: 0, splitFinalToken: true)
                #expect(planned.splitsFinalPromptToken)
                #expect(try (0..<planned.prefillFrameCount).map { try planned.frame(sequence: $0).tokenCount } == [512, 511, 1])
                #expect(planned.prefixCaptureFrontiers(stride: 512) == [512, 1023])
            }
        }
    }
}
