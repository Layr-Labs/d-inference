import Foundation
import DarkbloomClusterProtocol
import Testing
@testable import DarkbloomClusterRuntime

@Suite("Nemotron prefix reuse preserves original chunk reductions")
struct NemotronPrefixChunkTests {
    private func request(_ count: Int, chunk: Int = 512,
                         profileID: String = NemotronRegisteredLightning.profileID) throws -> QwenLayerStageGenerationRequest {
        let profile = try QwenLayerStageGenerationProfile(identifier: profileID, vocabularySize: 64,
            hiddenSize: 32, activationDType: "bfloat16", maximumPromptTokens: 32768,
            maximumChunkTokens: 512, maximumOutputTokens: 8, maximumContextTokens: 65536)
        return try .init(profile: profile, requestID: UUID(), promptTokenIDs: Array(repeating: 3, count: count),
            chunkSize: chunk, outputCount: 3, stopTokenIDs: [])
    }

    private func frames(_ request: QwenLayerStageGenerationRequest) throws -> [QwenLayerStageFrame] {
        try (0..<request.forwardCount).map { try request.frame(sequence: $0) }
    }

    @Test func coldPrefixOnRetainsEveryOriginalPrefillAndDecodeFrame() throws {
        for count in [1, 2, 255, 256, 257, 511, 512, 513, 1023, 1024, 1025, 4096, 16384, 32768] {
            for chunk in [1, 128, 256, 384, 512] {
                let original = try request(count, chunk: chunk)
                let planned = try original.planned(reusedPrefix: 0, splitFinalToken: true)
                #expect(original.preservesPrefixChunkGrid)
                #expect(!planned.splitsFinalPromptToken)
                #expect(try frames(planned) == frames(original))
                #expect(planned.fingerprint == original.fingerprint)
            }
        }
    }

    @Test func gridHitsRetainTheExactColdSuffixAndOffGridRestoresRefuse() throws {
        for count in [513, 1024, 1025, 4096] {
            let original = try request(count)
            let cold = try frames(original)
            for start in stride(from: 512, to: count, by: 512) {
                let warm = try original.planned(reusedPrefix: start, splitFinalToken: true)
                let suffix = try frames(warm)
                let expected = cold.filter { $0.tokenOffset >= start }
                #expect(suffix.map(\.tokenOffset) == expected.map(\.tokenOffset))
                #expect(suffix.map(\.tokenCount) == expected.map(\.tokenCount))
                #expect(suffix.map(\.phase) == expected.map(\.phase))
                #expect(suffix.map(\.finalPromptChunk) == expected.map(\.finalPromptChunk))
            }
            for start in [1, 255, 511, count - 1] where start % 512 != 0 {
                #expect(throws: ProbeError.self) { _ = try original.planned(reusedPrefix: start, splitFinalToken: true) }
            }
        }
    }

    @Test func capturesOnlyExistingGridEndsBeforeThePromptEnd() throws {
        let original = try request(1024)
        let cold = try original.planned(reusedPrefix: 0, splitFinalToken: true)
        #expect(cold.prefixCaptureFrontiers(stride: 512) == [512])
        #expect(cold.prefixCaptureFrontiers(stride: 1024).isEmpty)
        let warm = try original.planned(reusedPrefix: 512, splitFinalToken: true)
        #expect(warm.prefixCaptureFrontiers(stride: 512).isEmpty)
        #expect(try request(1025).planned(reusedPrefix: 0, splitFinalToken: true)
            .prefixCaptureFrontiers(stride: 512) == [512, 1024])
        #expect(try request(512).planned(reusedPrefix: 0, splitFinalToken: true)
            .prefixCaptureFrontiers(stride: 512).isEmpty)
    }

    @Test func residentDiskAndBatchOffersShareTheSameGridFilter() throws {
        let original = try request(1536)
        #expect(original.admittedPrefixFrontiers([1535, 1024, 1023, 512, 511, 1, 0, 1536]) == [1024, 512])
        #expect(original.admittedPrefixFrontiers([]).isEmpty)
        #expect(try request(1025).admittedPrefixFrontiers([1024, 512]) == [1024, 512])
    }

    @Test func otherProfileFramesAndOffGridReuseRemainUnchanged() throws {
        for profile in ["qwen35-prefix-fixture", ClusterStillImages.glmProfileID,
                        "registered_mimo_v26_greedy_generation_v1"] {
            let original = try request(1024, profileID: profile)
            #expect(!original.preservesPrefixChunkGrid)
            let planned = try original.planned(reusedPrefix: 0, splitFinalToken: true)
            #expect(planned.splitsFinalPromptToken)
            #expect(try (0..<planned.prefillFrameCount).map { try planned.frame(sequence: $0).tokenCount } == [512, 511, 1])
            #expect(planned.prefixCaptureFrontiers(stride: 512) == [512, 1023])
            #expect(try original.planned(reusedPrefix: 1023, splitFinalToken: true).prefillFrameCount == 1)
            #expect(original.admittedPrefixFrontiers([1023, 512]) == [1023, 512])
            #expect(try original.planned(reusedPrefix: 0, splitFinalToken: false).prefixCaptureFrontiers(stride: 512).isEmpty)
        }
    }

    @Test func sourceBoundReceiptSeparatesOldCacheAndRankArithmetic() throws {
        let policy = QwenResidentArithmeticPolicy.nemotronHybrid
        let old = try QwenLongPrefillArithmeticEnvironment.admit(policy.requiredValues, contract: policy.contract,
            additionalValues: [:], additionalAbsentNames: [], additionalBindings: [:])
        let new = try policy.admit(policy.requiredValues)
        #expect(new.contract == old.contract && new.requiredValues == old.requiredValues)
        #expect(new.requiredAbsentNames == old.requiredAbsentNames)
        #expect(new.defaultBindings["nemotron-prefix-chunk-grid-v1"] != nil)
        #expect(sha256(try canonicalJSONData(new)) != sha256(try canonicalJSONData(old)))
        #expect(try QwenResidentArithmeticPolicy.dense.admit(policy.requiredValues)
            == QwenLongPrefillArithmeticEnvironment.admit(policy.requiredValues))
    }
}
