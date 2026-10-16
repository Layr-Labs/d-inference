// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
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

extension NemotronSuperLocalOwnerTests {
    private static func owner(kvBytesCapacity: Int = 2 << 30,
        tokenizer: any MLXLMCommon.Tokenizer = SuperTokenTextTokenizer()) async throws
        -> (NemotronSuperLocalBridgeBuilder.Owner, NemotronSuperInstallation.Installed,
            NemotronSuperResidency, GlobalKVCacheBudget, PendingModelLoadLease) {
        let (installed, construction, residency) = try SuperInstalledFixture().make()
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-owner-admission",
            weightBytes: UInt64(installed.receipt.payloadBytes),
            minimumKVBytes: UInt64(kvBytesCapacity)))
        let owner = try await NemotronSuperLocalBridgeBuilder.make(installed: installed,
            tokenizer: TokenizerHandle(tokenizer), eosTokenIDs: [],
            sizing: .init(weightsBytes: installed.receipt.payloadBytes,
                fp16KVBytesPerToken: 64, maxContextLength: 64, defaultMaxTokens: 2),
            kvBytesCapacity: kvBytesCapacity, kvBudget: budget, loadLease: lease,
            construction: construction, environment: [:])
        return (owner, installed, residency, budget, lease)
    }

    /// The owner's image prompt carries the reference `<img>` (19), one
    /// `<image>` (18) per feature and `</img>` (20) for each image slot.
    @Test(.timeLimit(.minutes(1))) func imagePromptUsesTheReferenceImageFraming() async throws {
        let (owner, _, residency, budget, lease) = try await Self.owner(
            tokenizer: SuperSyntheticImageTokenizer())
        let template = try #require(Data(base64Encoded: superImagePinnedTemplateBase64,
                                        options: .ignoreUnknownCharacters))
        let body = try JSONSerialization.data(withJSONObject: [
            "model": NemotronSuperLocalBinding.modelID,
            "messages": [["role": "user", "content": [
                ["type": "text", "text": "fixture"],
                ["type": "image_url", "image_url": ["url": "data:image/png;base64,AA=="]]]]]])
        #expect(try owner.localImagePrompt(body: body, templateBytes: template, featureCounts: [3])
            == [1, 19, 18, 18, 18, 20, 2])
        // The framed span must fit the context: 62 features plus 2 markers do not.
        #expect(throws: NemotronSuperLocalImageBinding.Failure.capacity) {
            try owner.localImagePrompt(body: body, templateBytes: template, featureCounts: [62])
        }
        #expect(throws: NemotronSuperLocalImageBinding.Failure.invalidInput) {
            try owner.localImagePrompt(body: body, templateBytes: template, featureCounts: [2, 2])
        }
        try await owner.closeAfterDrain()
        #expect(residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
    }
}
