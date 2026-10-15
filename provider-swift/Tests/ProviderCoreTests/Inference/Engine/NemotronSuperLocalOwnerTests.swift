// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLMCommon
import Testing
@testable import ProviderCore

private actor SuperOwnerRun {
    var chunks = 0
    var completions: [Int] = []
    func record(_ event: GenerationEvent) {
        switch event {
        case .chunk: chunks += 1
        case .info(_, let completion, _, _): completions.append(completion)
        default: break
        }
    }
}

struct NemotronSuperLocalOwnerTests {
    @Test(.timeLimit(.minutes(1)))
    func ownerOwnsAndDrainsItsTextBindingOnClose() async throws {
        let (installed, construction, residency) = try SuperInstalledFixture().make()
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-owner-text",
            weightBytes: UInt64(installed.receipt.payloadBytes), minimumKVBytes: 2 << 30))
        let owner = try await NemotronSuperLocalBridgeBuilder.make(installed: installed,
            tokenizer: TokenizerHandle(SuperTokenTextTokenizer()), eosTokenIDs: [],
            sizing: .init(weightsBytes: installed.receipt.payloadBytes,
                fp16KVBytesPerToken: 64, maxContextLength: 64, defaultMaxTokens: 2),
            kvBytesCapacity: 2 << 30, kvBudget: budget, loadLease: lease,
            construction: construction, environment: [:])
        let binding = try owner.localTextBinding()
        #expect(try owner.localTextBinding() === binding)
        let request = ChatCompletionRequest(model: NemotronSuperLocalBinding.modelID,
            messages: [], temperature: 0, max_tokens: 3)
        let first = SuperOwnerRun()
        try await binding.run(request: request, promptTokens: [1, 2, 3]) { await first.record($0) }
        #expect(await first.completions == [3])

        // Close while a long request may still be streaming: the owner cancels
        // and joins it before shutting the bridge down.
        let streaming = SuperOwnerRun()
        let running = Task {
            try await binding.run(request: ChatCompletionRequest(
                model: NemotronSuperLocalBinding.modelID, messages: [], temperature: 0,
                max_tokens: 48), promptTokens: [4, 5]) { await streaming.record($0) }
        }
        for _ in 0 ..< 20_000 {
            if await streaming.chunks > 0 { break }
            await Task.yield()
        }
        try await owner.closeAfterDrain()
        _ = await running.result
        await #expect(throws: NemotronSuperLocalBinding.Failure.drained) {
            try await binding.run(request: request, promptTokens: [1]) { _ in }
        }
        #expect(throws: NemotronSuperLocalBridgeBuilder.Failure.self) {
            try owner.localTextBinding()
        }
        #expect(residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }
}
