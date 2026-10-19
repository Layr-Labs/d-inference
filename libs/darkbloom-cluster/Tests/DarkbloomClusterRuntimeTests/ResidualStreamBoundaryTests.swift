import Foundation
import MLX
import Testing
@testable import DarkbloomClusterRuntime

@Suite("Residual stream boundaries retain admitted geometry")
struct ResidualStreamBoundaryTests {
    private func profile(streams: Int? = nil) throws -> QwenLayerStageGenerationProfile {
        try .init(identifier: "four-stream-fixture", vocabularySize: 64, hiddenSize: 4096,
            activationDType: "bfloat16", maximumPromptTokens: 128, maximumChunkTokens: 16,
            maximumOutputTokens: 8, maximumContextTokens: 256, residualStreams: streams)
    }

    @Test func existingProfileEncodingAndFingerprintStayUnchanged() throws {
        let value = try profile()
        let encoded = try #require(try JSONSerialization.jsonObject(with: canonicalJSONData(value)) as? [String: Any])
        #expect(encoded["residualStreams"] == nil)
        #expect(value.boundaryShape(tokenCount: 3) == [1, 3, 4096])
        #expect(value.boundaryElementsPerToken == 4096)
        let previousFields = ["qwen-stage-generation-profile-v1", "four-stream-fixture", "64", "4096",
            "bfloat16", "128", "16", "8", "256"]
        #expect(value.fingerprint == sha256(Data(previousFields.joined(separator: "|").utf8)))
        let streams = try profile(streams: 4)
        #expect(streams.fingerprint != value.fingerprint)
        #expect(streams.boundaryShape(tokenCount: 3) == [1, 3, 4, 4096])
        #expect(streams.boundaryElementsPerToken * 2 == 32 * 1024)
        for count in [-1, 0, 1, 2, 3, 5, Int.max] {
            #expect(throws: ProbeError.self) { try profile(streams: count) }
        }
    }

    @Test func receiverDerivesFourStreamAllocationAndRejectsFlattenedHeader() throws {
        let request = try QwenLayerStageGenerationRequest(profile: profile(streams: 4), requestID: UUID(),
            promptTokenIDs: [1, 2, 3, 4], chunkSize: 4, outputCount: 2, stopTokenIDs: [])
        let source = try QwenLayerStageWireSourceIdentity(
            sourceConfigurationSHA256: String(repeating: "a", count: 64),
            artifactAggregateSHA256: String(repeating: "b", count: 64),
            storageCommitmentSHA256: String(repeating: "c", count: 64),
            planFingerprint: String(repeating: "d", count: 64),
            producerStageFingerprint: String(repeating: "e", count: 64))
        let agreement = try QwenLayerStageGenerationAgreement(request: request, membershipEpoch: UUID(),
            source: source, consumerStageFingerprint: String(repeating: "f", count: 64),
            rankBuildSHA256: [String(repeating: "1", count: 64), String(repeating: "2", count: 64)],
            numericalPolicySHA256: String(repeating: "3", count: 64))
        let expected = try QwenLayerStageGenerationBoundaryExpectation(agreement: agreement,
            frame: request.frame(sequence: 0), tokenIDs: request.promptTokenIDs,
            previousTokenChainSHA256: agreement.initialTokenChainSHA256)
        #expect(expected.shape == [1, 4, 4, 4096] && expected.byteCount == 4 * 32 * 1024)
        let packet = try QwenLayerStageGenerationBoundaryPacket(expected: expected,
            payloadSHA256: String(repeating: "a", count: 64))
        let decoded = try QwenLayerStageGenerationBoundaryPacket.decode(packet.encoded(), expected: expected)
        #expect(decoded.fingerprint == packet.fingerprint)
        var object = try #require(try JSONSerialization.jsonObject(with: packet.encoded()) as? [String: Any])
        var changed = try #require(object["expectation"] as? [String: Any])
        changed["shape"] = [1, 4, 16384] // Same byte count, wrong semantic boundary.
        object["expectation"] = changed
        let malformed = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: ProbeError.self) {
            try QwenLayerStageGenerationBoundaryPacket.decode(malformed, expected: expected)
        }
    }

    @Test func nativeOwnedFourStreamBufferKeepsEveryValue() throws {
        try MLX.withError { error in
            let array = MLXArray((0..<96).map(Float.init)).reshaped(1, 3, 4, 8).asType(.bfloat16)
            eval(array)
            Stream.gpu.synchronize()
            try error.check()
            let frame = QwenLayerStageFrame(sequence: 0, phase: .prefill, tokenOffset: 0,
                tokenCount: 3, finalPromptChunk: true)
            let digest = sha256(array.asData().data)
            let boundary = QwenLayerStageBoundary(requestFingerprint: String(repeating: "a", count: 64),
                sourceConfigurationSHA256: String(repeating: "b", count: 64),
                artifactAggregateSHA256: String(repeating: "c", count: 64),
                storageCommitmentSHA256: String(repeating: "d", count: 64),
                planFingerprint: String(repeating: "e", count: 64),
                producerStageFingerprint: String(repeating: "f", count: 64), frame: frame,
                tokenIDsSHA256: QwenLayerStageBoundary.tokenHash([1, 2, 3]), payloadSHA256: digest, array: array)
            try boundary.validateOwnedArray(tokens: 3, hidden: 8, dtype: .bfloat16, residualStreams: 4)
            #expect(boundary.array.asType(.float32).asArray(Float.self) == (0..<96).map(Float.init))
            #expect(throws: ProbeError.self) { try boundary.validateOwnedArray(tokens: 3, hidden: 32, dtype: .bfloat16) }
            try error.check()
        }
    }
}
