import Foundation

@main struct AgreementCheck {
    static func main() throws {
        let hash = String(repeating: "a", count: 64), other = String(repeating: "b", count: 64)
        let id = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let profile = try QwenLayerStageGenerationProfile(identifier: "cpu_generation", vocabularySize: 32,
            hiddenSize: 4096, activationDType: "bfloat16", maximumPromptTokens: 8192,
            maximumChunkTokens: 512, maximumOutputTokens: 128, maximumContextTokens: 8320)
        let source = try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: hash, artifactAggregateSHA256: hash,
            storageCommitmentSHA256: hash, planFingerprint: hash, producerStageFingerprint: hash)
        for count in [1, 513, 8192] {
            let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: id,
                promptTokenIDs: Array(repeating: 7, count: count), chunkSize: 512, outputCount: 128, stopTokenIDs: [])
            let agreement: QwenLayerStageGenerationAgreement
#if LOOKAHEAD_CHECK
            let opted = CommandLine.arguments.contains("lookahead")
            agreement = try .init(request: request, membershipEpoch: id, source: source, consumerStageFingerprint: other,
                rankBuildSHA256: [hash, other], numericalPolicySHA256: hash,
                prefillPolicy: opted ? .oneChunkLookahead : .serial)
#else
            agreement = try .init(request: request, membershipEpoch: id, source: source, consumerStageFingerprint: other,
                rankBuildSHA256: [hash, other], numericalPolicySHA256: hash)
#endif
            let identity = QwenLayerStageSessionIdentity(stageIndex: 0, requestFingerprint: request.fingerprint,
                artifactAggregateSHA256: hash, storageCommitmentSHA256: hash, bf16ConversionEnabled: true,
                sourceConfigurationSHA256: hash, constructionConfigurationSHA256: hash,
                planFingerprint: hash, stageFingerprint: hash, activationDType: "bfloat16")
            let result = QwenLayerStageGenerationResult(agreementFingerprint: agreement.fingerprint,
                membershipEpoch: id.uuidString.lowercased(), identity: identity, selectedTokenIDs: [7],
                tokenChainSHA256: agreement.initialTokenChainSHA256, completedFrames: request.prefillFrameCount,
                committedTokens: count, finishReason: .clientStop)
#if LOOKAHEAD_CHECK
            var checkedResult = result
            if opted {
                checkedResult.prefillSchedule = .init(policy: "oneChunkLookahead", rank: 0,
                    preparedAheadFrames: request.prefillFrameCount - 1, maximumPreparedBoundaries: 1)
            }
            let encoded = try canonicalJSONData(checkedResult)
#else
            let encoded = try canonicalJSONData(result)
#endif
            print(String(decoding: try canonicalJSONData(agreement.descriptor), as: UTF8.self))
            print(agreement.fingerprint)
            print(String(decoding: encoded, as: UTF8.self))
        }
    }
}
