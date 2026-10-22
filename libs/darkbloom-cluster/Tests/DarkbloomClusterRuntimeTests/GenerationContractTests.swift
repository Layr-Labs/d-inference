import Foundation
import Testing
@testable import DarkbloomClusterRuntime

// Two-rank generation contract coverage: request/profile bounds, frame
// sequencing, schedule commit/finish lifecycle, agreement identity, and wire
// JSON strictness. Pure contracts — no collective, model, GPU or network.

private func testProfile() throws -> QwenLayerStageGenerationProfile {
    try QwenLayerStageGenerationProfile(identifier: "qwen35-fixture", vocabularySize: 64,
        hiddenSize: 32, activationDType: "bfloat16", maximumPromptTokens: 128,
        maximumChunkTokens: 16, maximumOutputTokens: 8, maximumContextTokens: 256)
}

@Suite("Generation contracts (two-rank, no execution)")
struct GenerationContractTests {
    @Test func profileAndRequestBoundsAreClosed() throws {
        let profile = try testProfile()
        #expect(profile.fingerprint.count == 64)
        #expect(throws: ProbeError.self) {
            _ = try QwenLayerStageGenerationProfile(identifier: "bad id!", vocabularySize: 64,
                hiddenSize: 32, activationDType: "bfloat16", maximumPromptTokens: 128,
                maximumChunkTokens: 16, maximumOutputTokens: 8, maximumContextTokens: 256)
        }
        #expect(throws: ProbeError.self) {
            _ = try QwenLayerStageGenerationProfile(identifier: "ok", vocabularySize: 0,
                hiddenSize: 32, activationDType: "bfloat16", maximumPromptTokens: 128,
                maximumChunkTokens: 16, maximumOutputTokens: 8, maximumContextTokens: 256)
        }
        #expect(throws: ProbeError.self) {
            _ = try QwenLayerStageGenerationProfile(identifier: "ok", vocabularySize: 64,
                hiddenSize: 32, activationDType: "float64", maximumPromptTokens: 128,
                maximumChunkTokens: 16, maximumOutputTokens: 8, maximumContextTokens: 256)
        }
        #expect(throws: ProbeError.self) {
            _ = try QwenLayerStageGenerationProfile(identifier: "ok", vocabularySize: 64,
                hiddenSize: 32, activationDType: "bfloat16", maximumPromptTokens: 128,
                maximumChunkTokens: 256, maximumOutputTokens: 8, maximumContextTokens: 256)
        }
        // Request construction and fingerprint stability.
        let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
            promptTokenIDs: Array(0..<10), chunkSize: 4, outputCount: 3, stopTokenIDs: [63])
        #expect(request.prefillFrameCount == 3 && request.forwardCount == 5)
        #expect(request.finalCommittedTokens == 12)
        let identical = try QwenLayerStageGenerationRequest(profile: profile, requestID: request.requestID,
            promptTokenIDs: request.promptTokenIDs, chunkSize: 4, outputCount: 3, stopTokenIDs: [63])
        #expect(identical.fingerprint == request.fingerprint)
        let different = try QwenLayerStageGenerationRequest(profile: profile, requestID: request.requestID,
            promptTokenIDs: Array(1..<11), chunkSize: 4, outputCount: 3, stopTokenIDs: [63])
        #expect(different.fingerprint != request.fingerprint)
        #expect(throws: ProbeError.self) {
            _ = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                promptTokenIDs: [], chunkSize: 4, outputCount: 3, stopTokenIDs: [])
        }
        #expect(throws: ProbeError.self) {
            _ = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                promptTokenIDs: [0, 1, 64], chunkSize: 4, outputCount: 3, stopTokenIDs: [])
        }
        #expect(throws: ProbeError.self) {
            _ = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
                promptTokenIDs: Array(0..<10), chunkSize: 4, outputCount: 9, stopTokenIDs: [])
        }
    }

    @Test func frameSequencingIsExact() throws {
        let profile = try testProfile()
        let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
            promptTokenIDs: Array(0..<10), chunkSize: 4, outputCount: 3, stopTokenIDs: [63])
        let f0 = try request.frame(sequence: 0)
        #expect(f0.phase == .prefill && f0.tokenOffset == 0 && f0.tokenCount == 4 && !f0.finalPromptChunk)
        let f2 = try request.frame(sequence: 2)
        #expect(f2.phase == .prefill && f2.tokenOffset == 8 && f2.tokenCount == 2 && f2.finalPromptChunk)
        let f3 = try request.frame(sequence: 3)
        #expect(f3.phase == .decode && f3.tokenOffset == 10 && f3.tokenCount == 1)
        let f4 = try request.frame(sequence: 4)
        #expect(f4.phase == .decode && f4.tokenOffset == 11)
        #expect(throws: ProbeError.self) { _ = try request.frame(sequence: 5) }
    }

    @Test func scheduleCommitAndFinishLifecycle() throws {
        let profile = try testProfile()
        let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
            promptTokenIDs: Array(0..<10), chunkSize: 4, outputCount: 3, stopTokenIDs: [63])
        var schedule = QwenLayerStageGenerationSchedule(request: request)
        // Wrong prefill admission (count/offset/final) refused.
        #expect(throws: ProbeError.self) { _ = try schedule.admitPrefill(count: 2, offset: 0, final: false) }
        #expect(throws: ProbeError.self) { _ = try schedule.admitDecode(offset: 0) }
        // Commit exactly the expected frames, in order.
        for sequence in 0..<3 {
            let frame = try request.frame(sequence: sequence)
            let admitted = try schedule.admitPrefill(count: frame.tokenCount, offset: frame.tokenOffset,
                final: frame.finalPromptChunk)
            try schedule.commit(admitted)
        }
        #expect(schedule.committedTokens == 10 && schedule.committedPromptTokens == 10)
        // A replayed or substituted commit is refused.
        #expect(throws: ProbeError.self) { try schedule.commit(try request.frame(sequence: 0)) }
        // EOS finish requires a committed stop token as the last selection.
        #expect(throws: ProbeError.self) { try schedule.finish(.eos, selectedTokenCount: 2, lastTokenID: 5) }
        let decode = try schedule.admitDecode(offset: 10)
        try schedule.commit(decode)
        #expect(throws: ProbeError.self) { try schedule.finish(.eos, selectedTokenCount: 2, lastTokenID: 5) }
        try schedule.finish(.eos, selectedTokenCount: 2, lastTokenID: 63)
        #expect(schedule.complete && schedule.finishReason == .eos)
        // No frame or second finish after completion.
        #expect(throws: ProbeError.self) { _ = try schedule.admitDecode(offset: 11) }
        #expect(throws: ProbeError.self) { try schedule.finish(.length, selectedTokenCount: 2, lastTokenID: 5) }
        // Length finish masks EOS refused; must equal the output limit.
        var second = QwenLayerStageGenerationSchedule(request: request)
        for sequence in 0..<5 { try second.commit(try request.frame(sequence: sequence)) }
        #expect(throws: ProbeError.self) { try second.finish(.length, selectedTokenCount: 2, lastTokenID: 5) }
        #expect(throws: ProbeError.self) { try second.finish(.length, selectedTokenCount: 3, lastTokenID: 63) }
        try second.finish(.length, selectedTokenCount: 3, lastTokenID: 5)
        #expect(second.finishReason == .length)
    }

    @Test func agreementRequiresExactStageIdentity() throws {
        let profile = try testProfile()
        let request = try QwenLayerStageGenerationRequest(profile: profile, requestID: UUID(),
            promptTokenIDs: Array(0..<10), chunkSize: 4, outputCount: 3, stopTokenIDs: [63])
        let source = try QwenLayerStageWireSourceIdentity(
            sourceConfigurationSHA256: String(repeating: "a", count: 64),
            artifactAggregateSHA256: String(repeating: "b", count: 64),
            storageCommitmentSHA256: String(repeating: "c", count: 64),
            planFingerprint: String(repeating: "d", count: 64),
            producerStageFingerprint: String(repeating: "e", count: 64))
        let agreement = try QwenLayerStageGenerationAgreement(request: request,
            membershipEpoch: UUID(), source: source,
            consumerStageFingerprint: String(repeating: "f", count: 64),
            rankBuildSHA256: [String(repeating: "1", count: 64), String(repeating: "2", count: 64)],
            numericalPolicySHA256: String(repeating: "3", count: 64))
        #expect(agreement.descriptor.rankCount == 2 && agreement.descriptor.mtpEnabled == false)
        #expect(agreement.descriptor.prefillSchedulingPolicy == nil) // serial is the omitted default
        #expect(agreement.fingerprint.count == 64 && agreement.initialTokenChainSHA256.count == 64)
        #expect(throws: ProbeError.self) {
            _ = try QwenLayerStageGenerationAgreement(request: request, membershipEpoch: UUID(),
                source: source, consumerStageFingerprint: String(repeating: "e", count: 64),
                rankBuildSHA256: [String(repeating: "1", count: 64), String(repeating: "2", count: 64)],
                numericalPolicySHA256: String(repeating: "3", count: 64))
        }
        #expect(throws: ProbeError.self) {
            _ = try QwenLayerStageGenerationAgreement(request: request, membershipEpoch: UUID(),
                source: source, consumerStageFingerprint: String(repeating: "f", count: 64),
                rankBuildSHA256: [String(repeating: "1", count: 64)],
                numericalPolicySHA256: String(repeating: "3", count: 64))
        }
        #expect(throws: ProbeError.self) {
            _ = try QwenLayerStageWireSourceIdentity(
                sourceConfigurationSHA256: "UPPER", artifactAggregateSHA256: String(repeating: "b", count: 64),
                storageCommitmentSHA256: String(repeating: "c", count: 64),
                planFingerprint: String(repeating: "d", count: 64),
                producerStageFingerprint: String(repeating: "e", count: 64))
        }
    }

    @Test func wireJSONIsBoundedAndExact() throws {
        let object = try QwenLayerStageGenerationWireJSON.object(Data(#"{"a":1,"b":"x"}"#.utf8))
        #expect(object["a"] as? Int == 1)
        #expect(throws: ProbeError.self) { _ = try QwenLayerStageGenerationWireJSON.object(Data()) }
        #expect(throws: ProbeError.self) {
            _ = try QwenLayerStageGenerationWireJSON.object(Data(repeating: 1, count: 16_385))
        }
        #expect(throws: ProbeError.self) {
            _ = try QwenLayerStageGenerationWireJSON.object(Data(#"[1,2]"#.utf8))
        }
        // Exact comparison tolerates key order but not value drift.
        struct Expected: Encodable { let a: Int; let b: String }
        try QwenLayerStageGenerationWireJSON.requireExact(["b": "x", "a": 1], Expected(a: 1, b: "x"))
        #expect(throws: ProbeError.self) {
            try QwenLayerStageGenerationWireJSON.requireExact(["a": 1, "b": "y"], Expected(a: 1, b: "x"))
        }
    }
}
