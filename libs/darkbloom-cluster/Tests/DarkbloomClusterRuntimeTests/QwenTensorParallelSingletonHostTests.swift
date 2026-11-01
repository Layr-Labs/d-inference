import DarkbloomClusterProtocol
import Foundation
import Testing
@testable import DarkbloomClusterRuntime

struct QwenTensorParallelSingletonHostTests {
    private func request() throws -> QwenLayerStageGenerationRequest {
        let profile = try QwenLayerStageGenerationProfile(identifier: "singleton-credit-fixture", vocabularySize: 256,
            hiddenSize: 256, activationDType: "bfloat16", maximumPromptTokens: 128,
            maximumChunkTokens: 64, maximumOutputTokens: 16, maximumContextTokens: 256)
        return try .init(profile: profile, requestID: UUID(), promptTokenIDs: [2, 3, 5],
            chunkSize: 2, outputCount: 8, stopTokenIDs: [])
    }

    @Test func singletonCreditsAndCompletionRequireTheRealDriverRetirementBoundary() throws {
        let request = try request(), id = request.requestID
        var publications: [(Int, Int, Int)] = [], answers = 0
        let host = QwenTensorParallelSingletonHost(request: request, channel: .init(publish: {
            publications.append(($0, $1, $2))
        }, answer: { answers += 1; return answers < 2 }))
        #expect(throws: ProbeError.self) { try host.completion() }
        #expect(throws: ProbeError.self) { try host.publishFinished(requestID: id, reason: .clientStop) }
        try host.publishToken(requestID: id, ordinal: 0, tokenID: 7, committedTokens: 3)
        #expect(answers == 1 && publications.count == 1)
        #expect(throws: ProbeError.self) {
            try host.publishToken(requestID: id, ordinal: 1, tokenID: 11, committedTokens: 4)
        }
        #expect(try host.pollDecision(id) == true)
        #expect(try host.pollDecision(id) == nil)
        try host.publishToken(requestID: id, ordinal: 1, tokenID: 11, committedTokens: 4)
        #expect(try host.awaitDecisions([id]) == [id: false])
        #expect(publications.map { $0.0 } == [0, 1] && publications.map { $0.1 } == [7, 11])
        try host.publishPromptCache(requestID: id, reusedTokens: 2, storedFrontiers: [3])
        try host.retiredSelection(id, tokens: [7, 11], reason: .clientStop)
        #expect(throws: ProbeError.self) { try host.completion() }
        try host.publishFinished(requestID: id, reason: .clientStop)
        let result = try host.completion()
        #expect(result.selectedTokenIDs == [7, 11] && result.completedFrames == 2 && result.committedTokens == 5)
        #expect(result.bothRequestStatesRetired && result.finishReason == .clientStop)
        #expect(result.reusedPromptTokens == 2 && result.storedPromptFrontiers == [3])
        let chain = sha256(try canonicalJSONData(["7", "11"]))
        #expect(result.tokenChainSHA256 == chain)
        #expect(throws: ProbeError.self) { try host.publishToken(requestID: id, ordinal: 2, tokenID: 13, committedTokens: 5) }
    }

    @Test func singletonAdapterRejectsCancelledUnretiredAndCrossRequestCompletion() throws {
        let request = try request(), id = request.requestID
        let host = QwenTensorParallelSingletonHost(request: request, channel: .init(publish: { _, _, _ in }, answer: { true }))
        #expect(throws: ProbeError.self) { try host.publishLeft(requestID: id) }
        #expect(throws: ProbeError.self) { try host.retiredSelection(UUID(), tokens: [7], reason: .length) }
        #expect(throws: ProbeError.self) { try host.awaitDecisions([id, UUID()]) }
        #expect(throws: ProbeError.self) { try host.completion() }
        try host.retiredSelection(id, tokens: [7], reason: .length)
        #expect(throws: ProbeError.self) { try host.retiredSelection(id, tokens: [7], reason: .length) }
        #expect(throws: ProbeError.self) { try host.publishFinished(requestID: id, reason: .eos) }
        try host.publishFinished(requestID: id, reason: .length)
        #expect(try host.completion().finishReason == .length)
    }
}
