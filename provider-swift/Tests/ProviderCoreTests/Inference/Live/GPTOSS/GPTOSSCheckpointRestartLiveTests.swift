import Foundation
@_spi(Benchmarking) import MLXLMCommon
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

    /// The donor starts alone (one 2,048-token solo stripe), then a second
    /// request arrives and the rest of its prompt prefills in 512-token
    /// company chunks. The uniform-cap rule disarmed at that cap change and
    /// left only the 2,048 boundary; the historical rule keeps every 1,024
    /// multiple, so a repeat restores the deepest one below the prompt end.
    @Test("a donor that prefills under batching still leaves checkpoints deep into its prompt",
          .timeLimit(.minutes(10)),
          .enabled(if: LiveInferenceFixtures.liveTestsEnabled
            && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_GPTOSS_CHECKPOINT_RESTART"] == "1"))
    func batchedDonorRestoresDeepBoundary() async throws {
        let fixture = try await GPTOSSCheckpointRestartFixture()
        do {
            let donorStore = try fixture.makeStore()
            let donorBridge = try fixture.makeBridge(store: donorStore, maxConcurrentRequests: 2)
            let engine = try #require(await donorBridge.engine as? EngineV2)
            let before = try engine.beginForwardShapeObservation()
            let donorTask = Task {
                try await run(fixture, bridge: donorBridge, tokens: fixture.prompts.donor,
                              scope: "tenant-a", id: "batched-donor", expectedMarker: "ALDER-427")
            }
            // Let the donor's first solo stripe launch before company arrives.
            let deadline = ContinuousClock.now + .seconds(60)
            while engine.stepCount < 1 {
                try #require(ContinuousClock.now < deadline, "donor never launched its first step")
                try await taskSleep(.milliseconds(5))
            }
            let companyTask = Task {
                try await run(fixture, bridge: donorBridge, tokens: fixture.prompts.changedPrefix,
                              scope: "tenant-b", id: "company", expectedMarker: "CEDAR-682")
            }
            let donor = try await donorTask.value
            let company = try await companyTask.value
            #expect(donor.hitTokens == 0 && company.hitTokens == 0)
            try await requireIdle(donorBridge)
            let delta = engine.forwardShapeSnapshot().delta(since: before)
            let prefillWidths = Set(delta.entries.filter {
                $0.axes.kind == .target && $0.axes.phase == .prefill && $0.completedCalls > 0
            }.map(\.axes.sequenceWidth))
            print("[gptoss-batched-donor] prefillWidths=\(prefillWidths.sorted())")
            #expect(prefillWidths.contains(2048) && prefillWidths.contains(512),
                    "the donor must have prefilled under both the solo stripe and company chunks")
            await donorStore.waitForWritesForTesting()
            let positions = try fixture.persistedManifests()
                .filter { $0.cacheSalt == "tenant-a" && fixture.prompts.donor.starts(with: $0.prefixTokens) }
                .map(\.position).sorted()
            print("[gptoss-batched-donor] prompt=\(fixture.prompts.donor.count) positions=\(positions)")
            let deepest = try #require(positions.max())
            #expect(deepest >= 5_120, "the donor must keep a boundary past the solo stripe")
            #expect(positions.contains(2048) && positions.contains { $0 % 2048 != 0 },
                    "boundaries from both chunk geometries must survive")
            #expect(positions.allSatisfy { $0 % 1024 == 0 })
            await donorBridge.shutdown()
            await donorStore.closeAndWait()

            let restoredStore = try fixture.makeStore()
            let restoredBridge = try fixture.makeBridge(store: restoredStore)
            let repeated = try await run(fixture, bridge: restoredBridge, tokens: fixture.prompts.donor,
                                         scope: "tenant-a", id: "repeat", expectedMarker: "ALDER-427")
            #expect(repeated.hitTokens == deepest && repeated.hitTokens >= 5_120,
                    "a repeat must restore the deepest retained boundary")
            try await requireIdle(restoredBridge)
            print("[gptoss-batched-donor] repeatHit=\(repeated.hitTokens) deepest=\(deepest) "
                + "sameText=\(repeated.text == donor.text) warmTTFT=\(repeated.ttft) coldTTFT=\(donor.ttft)")
            await restoredBridge.shutdown()
            await restoredStore.closeAndWait()
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
        let normalized = answer.uppercased().trimmingCharacters(in:
            CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "`\"'.*")))
        #expect(normalized == expectedMarker,
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
