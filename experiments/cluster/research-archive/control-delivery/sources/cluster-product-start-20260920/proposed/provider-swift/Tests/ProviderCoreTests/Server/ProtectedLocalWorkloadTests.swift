import Foundation
import MLXLMCommon
import Testing
import DarkbloomClusterProtocol
@testable import ProviderCore

@Suite struct ProtectedLocalWorkloadTests {
    @Test func restrictedProfilePreservesIdentityAndCannotWidenNativeLimits() throws {
        let native = ClusterWorkerProfile(id: "fixture", vocabularySize: 100,
            maximumPromptTokens: 8192, maximumOutputTokens: 128, maximumChunkTokens: 512, maximumContextTokens: 8320)
        let profile = try ProtectedLocalWorkload.profile(native, requestTimeoutSeconds: 120)
        #expect(profile.id == native.id && profile.vocabularySize == native.vocabularySize)
        #expect(profile.maxPromptTokens == 32 && profile.maxOutputTokens == 2 && profile.maxContextTokens == 34)
        #expect(profile.requestTimeout == .seconds(120))
        for timeout in [0, 301] {
            #expect(throws: NativePairMemberError.self) { try ProtectedLocalWorkload.profile(native, requestTimeoutSeconds: timeout) }
        }
        let small = ClusterWorkerProfile(id: "fixture", vocabularySize: 100,
            maximumPromptTokens: 31, maximumOutputTokens: 2, maximumChunkTokens: 16, maximumContextTokens: 33)
        #expect(throws: NativePairMemberError.self) { try ProtectedLocalWorkload.profile(small, requestTimeoutSeconds: 120) }
    }
    @Test func originalOwnerGateStillRequiresExactShapeAndEmptyStops() throws {
        let valid = CBv2Request(id: .init(1), promptTokens: Array(repeating: 1, count: 32),
            sampling: .init(temperature: 0), maxTokens: 2)
        try ProtectedLocalWorkload.require(valid)
        for prompt in [0, 31, 33] {
            var changed = valid; changed.promptTokens = Array(repeating: 1, count: prompt)
            #expect(throws: DistributedEngineError.self) { try ProtectedLocalWorkload.require(changed) }
        }
        for count in [0, 1, 3, 128] {
            var changed = valid; changed.maxTokens = count
            #expect(throws: DistributedEngineError.self) { try ProtectedLocalWorkload.require(changed) }
        }
        var tokens = valid; tokens.stopTokens = [99]
        var strings = valid; strings.stopStrings = ["stop"]
        #expect(throws: DistributedEngineError.self) { try ProtectedLocalWorkload.require(tokens) }
        #expect(throws: DistributedEngineError.self) { try ProtectedLocalWorkload.require(strings) }
    }
    @Test func fixedLengthPolicyDoesNotChangeOrdinaryModelEOS() throws {
        let ordinary = LocalHostTestSession()
        let protected = try protectedTestSession(ProtectedMemberTestBackend())
        #expect(try ordinary.httpStopTokenIDs(tokenizerEOS: 99) == [99])
        #expect(try protected.httpStopTokenIDs(tokenizerEOS: 99).isEmpty)
        #expect(!ordinary.httpDrainOnExhaustion && protected.httpDrainOnExhaustion)
    }
}
