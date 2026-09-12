import Foundation
import Testing
@testable import ProviderCore

@Suite("Gemma QAT paged complete-checkpoint restart (live)", .serialized)
struct GemmaQATCheckpointRestartLiveTests {
    @Test("fresh engine imports the same tenant's persisted checkpoint before producing a donor",
          .timeLimit(.minutes(5)),
          .enabled(if: LiveInferenceFixtures.liveTestsEnabled
            && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_GEMMA_CHECKPOINT_RESTART"] == "1"))
    func sameKeyNewEngineRestores() async throws {
        let fixture = try await GemmaQATCheckpointRestartFixture()
        do {
            let donorStore = try fixture.makeStore()
            let donorBridge = try fixture.makeBridge(store: donorStore)
            let donor = try await run(fixture, bridge: donorBridge, scope: "tenant-a", id: "donor")
            #expect(donor.hitTokens == 0)
            try await waitForDonation(donorStore)
            #expect(donorStore.stats().bytesWritten > 0)
            try await requireIdle(donorBridge)
            await donorBridge.shutdown()
            await donorStore.closeAndWait()
            #expect(donorStore.stats().stagedBytesInUse == 0)
            #expect(donorStore.stats().writeHostBytesInUse == 0)

            let restoredStore = try fixture.makeStore()
            try #require(restoredStore.stats().entries > 0, "new store failed to scan donated files")
            #expect(restoredStore.stats().filesRead == 0)
            #expect(restoredStore.stats().filesWritten == 0)
            let restoredBridge = try fixture.makeBridge(store: restoredStore)
            // This is the FIRST submission to the new engine/store. A hit
            // cannot have come from a request made by this engine earlier.
            let restored = try await run(fixture, bridge: restoredBridge, scope: "tenant-a", id: "first-after-restart")
            #expect(restored.hitTokens >= 4_096)
            #expect(restoredStore.stats().stageConsumptions == 1)
            #expect(restoredStore.stats().filesRead > 0)
            #expect(restoredStore.stats().bytesRead > 0)
            #expect(restoredStore.stats().stagedBytesInUse == 0)
            try await requireIdle(restoredBridge)
            let wrongTenant = try await run(fixture, bridge: restoredBridge, scope: "tenant-b", id: "other-tenant")
            #expect(wrongTenant.hitTokens == 0)
            try await requireIdle(restoredBridge)
            await restoredBridge.shutdown()
            await restoredStore.closeAndWait()
            #expect(restoredStore.stats().stagedBytesInUse == 0)
            #expect(restoredStore.stats().writeHostBytesInUse == 0)

            let coldBridge = try fixture.makeBridge(store: nil)
            let cold = try await run(fixture, bridge: coldBridge, scope: "tenant-a", id: "cache-off")
            #expect(cold.hitTokens == 0)
            try await requireIdle(coldBridge)
            for result in [donor, restored, wrongTenant, cold] {
                #expect(result.text.lowercased().contains("alder") && result.text.contains("427"),
                        "cold and restored output must both preserve the requested marker")
            }
            print("[gemma-checkpoint-restart] prompt=\(fixture.tokens.count) hit=\(restored.hitTokens) "
                + "bytesRead=\(restoredStore.stats().bytesRead) "
                + "sameText=\(restored.text == cold.text) restored=\(restored.text.debugDescription) "
                + "cold=\(cold.text.debugDescription)")
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    private struct Output { let text: String; let hitTokens: Int }

    private func run(_ fixture: GemmaQATCheckpointRestartFixture, bridge: EngineV2Bridge,
                     scope: String, id: String) async throws -> Output {
        let signal = EngineV2RequestUsageSignal()
        let request = ChatCompletionRequest(model: GemmaQATCheckpointRestartFixture.modelID,
            messages: [ChatMessage(role: "user", content: "pre-tokenized fixture")],
            temperature: 0, max_tokens: 64)
        let stream = await bridge.submitTokenized(promptTokens: fixture.tokens, request: request,
            requestId: id, cacheScope: scope, usageSignal: signal)
        var text = ""
        var failure: String?
        for await event in stream {
            switch event {
            case .chunk(let chunk): text += chunk
            case .info: break
            case .error(let message): failure = message
            case .terminal(_, let message, _, _):
                failure = message
            }
        }
        try #require(failure == nil, "request failed: \(failure ?? "")")
        try #require(!text.isEmpty)
        return Output(text: text, hitTokens: signal.prefixCacheHitTokens ?? 0)
    }

    private func waitForDonation(_ store: SSDHybridCheckpointStore) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while store.stats().entries == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(store.stats().entries > 0, "no complete checkpoint was persisted")
        // Do not close the bridge after only the earlier checkpoint lands:
        // shutdown deliberately drops queued writes, including the tail.
        await store.waitForWritesForTesting()
    }

    private func requireIdle(_ bridge: EngineV2Bridge) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            let capacity = await bridge.capacitySnapshot()
            let idle = capacity.activeRequests == 0 && capacity.waitingRequests == 0
                && capacity.kvBytesInUse == 0 && capacity.kvBytesReserved == 0
            if idle { return }
            if ContinuousClock.now >= deadline {
                try #require(idle, "request accounting did not drain before reconstruction")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
