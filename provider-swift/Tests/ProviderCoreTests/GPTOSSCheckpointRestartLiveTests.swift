import Foundation
import ProviderCoreFoundation
import Testing
@testable import ProviderCore

@Suite("GPT-OSS paged complete-checkpoint restart (live)", .serialized)
struct GPTOSSCheckpointRestartLiveTests {
    @Test("default cache restores an encrypted historical checkpoint for a branched prompt after engine reconstruction",
          .timeLimit(.minutes(10)),
          .enabled(if: LiveInferenceFixtures.liveTestsEnabled
            && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_GPTOSS_CHECKPOINT_RESTART"] == "1"))
    func sameKeyNewEngineRestoresBranchedPrompt() async throws {
        let fixture = try await GPTOSSCheckpointRestartFixture()
        do {
            let donorStore = try fixture.makeStore()
            let donorBridge = try fixture.makeBridge(store: donorStore)
            let donor = try await run(fixture, bridge: donorBridge, tokens: fixture.prompts.donor,
                                      scope: "tenant-a", id: "donor", expectedMarker: "ALDER-427")
            #expect(donor.hitTokens == 0)
            try await requireIdle(donorBridge)
            await donorStore.waitForWritesForTesting()
            try #require(donorStore.stats().entries > 0, "no complete checkpoint was persisted")
            #expect(donorStore.stats().bytesWritten > 0)
            let manifests = try fixture.persistedManifests()
            let expectedBoundary = try #require(manifests.filter {
                fixture.prompts.branch.starts(with: $0.prefixTokens) && $0.position < fixture.prompts.branch.count
            }.map(\.position).max())
            try #require(expectedBoundary >= 4_096, "the branched prompt must reuse a substantial prefix")
            #expect(fixture.prompts.branch != fixture.prompts.donor)
            #expect(manifests.allSatisfy { !fixture.prompts.changedPrefix.starts(with: $0.prefixTokens) })
            await donorBridge.shutdown()
            await donorStore.closeAndWait()
            #expect(donorStore.stats().stagedBytesInUse == 0)
            #expect(donorStore.stats().writeHostBytesInUse == 0)

            let restoredStore = try fixture.makeStore()
            try #require(restoredStore.stats().entries > 0, "new store failed to scan donated files")
            #expect(restoredStore.stats().filesRead == 0)
            #expect(restoredStore.stats().filesWritten == 0)
            let restoredBridge = try fixture.makeBridge(store: restoredStore)
            // FIRST request to this engine asks a different question. The only
            // existing matching state is the earlier engine's encrypted SSD file.
            let restored = try await run(fixture, bridge: restoredBridge, tokens: fixture.prompts.branch,
                scope: "tenant-a", id: "first-after-restart", expectedMarker: "BRONZE-913")
            #expect(restored.hitTokens == expectedBoundary,
                    "complete historical restore must resume at the checkpoint without the old 1,536-token replay penalty")
            #expect(restoredStore.stats().stageConsumptions == 1)
            #expect(restoredStore.stats().filesRead > 0)
            #expect(restoredStore.stats().bytesRead > 0)
            #expect(restoredStore.stats().stagedBytesInUse == 0)
            let restoredBytesRead = restoredStore.stats().bytesRead
            try await requireIdle(restoredBridge)

            let wrongTenant = try await run(fixture, bridge: restoredBridge, tokens: fixture.prompts.branch,
                scope: "tenant-b", id: "other-tenant", expectedMarker: "BRONZE-913")
            #expect(wrongTenant.hitTokens == 0)
            try await requireIdle(restoredBridge)
            let changed = try await run(fixture, bridge: restoredBridge, tokens: fixture.prompts.changedPrefix,
                scope: "tenant-a", id: "changed-prefix", expectedMarker: "CEDAR-682")
            #expect(changed.hitTokens == 0, "changing an early fact must invalidate all later checkpoint hashes")
            #expect(restoredStore.stats().stageConsumptions == 1, "isolated requests must not consume staged state")
            try await requireIdle(restoredBridge)
            await restoredBridge.shutdown()
            await restoredStore.closeAndWait()
            #expect(restoredStore.stats().stagedBytesInUse == 0)
            #expect(restoredStore.stats().writeHostBytesInUse == 0)

            let coldBridge = try fixture.makeBridge(store: nil)
            let cold = try await run(fixture, bridge: coldBridge, tokens: fixture.prompts.branch,
                scope: "tenant-a", id: "cache-off-branch", expectedMarker: "BRONZE-913")
            try await requireIdle(coldBridge)
            let coldChanged = try await run(fixture, bridge: coldBridge, tokens: fixture.prompts.changedPrefix,
                scope: "tenant-a", id: "cache-off-changed", expectedMarker: "CEDAR-682")
            #expect(cold.hitTokens == 0 && coldChanged.hitTokens == 0)
            try await requireIdle(coldBridge)
            // Semantic marker assertions apply to every response, including
            // misses. Exact greedy text is diagnostic: kernel shapes may differ.
            print("[gptoss-checkpoint-restart] prompt=\(fixture.prompts.branch.count) "
                + "hit=\(restored.hitTokens) expectedBoundary=\(expectedBoundary) bytesRead=\(restoredBytesRead) "
                + "warmTTFT=\(restored.ttft) offTTFT=\(cold.ttft) "
                + "sameText=\(restored.text == cold.text) "
                + "restored=\(restored.answer.debugDescription) cold=\(cold.answer.debugDescription) "
                + "changed=\(changed.answer.debugDescription) offChanged=\(coldChanged.answer.debugDescription)")
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    private struct Output {
        let text: String
        let answer: String
        let hitTokens: Int
        let ttft: Duration
    }

    private func run(_ fixture: GPTOSSCheckpointRestartFixture, bridge: EngineV2Bridge,
                     tokens: [Int], scope: String, id: String, expectedMarker: String) async throws -> Output {
        let signal = EngineV2RequestUsageSignal()
        let request = ChatCompletionRequest(model: GPTOSSCheckpointRestartFixture.modelID,
            messages: [ChatMessage(role: "user", content: "pre-tokenized fixture")],
            temperature: 0, max_tokens: 256)
        let started = ContinuousClock.now
        let stream = await bridge.submitTokenized(promptTokens: tokens, request: request,
            requestId: id, cacheScope: scope, usageSignal: signal)
        var text = ""
        var firstChunk: ContinuousClock.Instant?
        var failure: String?
        var finishReason: String?
        for await event in stream {
            switch event {
            case .chunk(let chunk):
                if firstChunk == nil && !chunk.isEmpty { firstChunk = .now }
                text += chunk
            case .info(_, _, _, let reason): finishReason = reason
            case .error(let message): failure = message
            case .terminal(_, let message, _, _): failure = message
            }
        }
        try #require(failure == nil, "request \(id) failed: \(failure ?? "")")
        try #require(finishReason == "stop", "request \(id) must finish naturally, not truncate its reasoning")
        let answer = stripHarmonyChannelFraming(fromAssistantContent: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(!answer.isEmpty, "request \(id) produced no final answer")
        #expect(answer.uppercased().contains(expectedMarker),
                "request \(id) final answer must preserve the requested fact: \(answer)")
        for other in ["ALDER-427", "BRONZE-913", "CEDAR-682"] where other != expectedMarker {
            #expect(!answer.uppercased().contains(other),
                    "request \(id) must not leak a donor question or replaced fact into its final answer: \(answer)")
        }
        print("[gptoss-checkpoint-request] id=\(id) hit=\(signal.prefixCacheHitTokens ?? 0) "
            + "ttft=\((firstChunk ?? .now) - started) answer=\(answer.debugDescription)")
        return Output(text: text, answer: answer, hitTokens: signal.prefixCacheHitTokens ?? 0,
                      ttft: (firstChunk ?? .now) - started)
    }

    private func requireIdle(_ bridge: EngineV2Bridge) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while true {
            let capacity = await bridge.capacitySnapshot()
            let idle = capacity.activeRequests == 0 && capacity.waitingRequests == 0
                && capacity.kvBytesInUse == 0 && capacity.kvBytesReserved == 0
            if idle { return }
            if ContinuousClock.now >= deadline {
                try #require(idle, "request accounting did not drain before reconstruction")
                return
            }
            try await taskSleep(.milliseconds(10))
        }
    }
}
