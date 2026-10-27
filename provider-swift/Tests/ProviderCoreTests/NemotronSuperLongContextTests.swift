// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// The served context and the verified ceiling the builder and the image
/// binding accept. Synthetic fixture; the full-checkpoint evidence is
/// `NemotronSuperLongContextLiveTests` and the runner's long-context probe.
struct NemotronSuperLongContextTests {
    private typealias Policy = NemotronSuperServingPolicy
    private typealias Binding = NemotronSuperLocalImageBinding

    @Test func servedContextIsTheVerifiedCeiling() {
        // The slot serves the whole verified ceiling; the coordinator decides
        // whether a long prompt's prefill time suits a request.
        #expect(Policy.contextTokens == 262_144 && Policy.contextTokens == Policy.maximumContextTokens)
    }

    private static func owner(maxContextLength: Int, budget: GlobalKVCacheBudget, name: String)
        async throws -> (NemotronSuperLocalBridgeBuilder.Owner, PendingModelLoadLease,
                         NemotronSuperResidency) {
        let (installed, construction, residency) = try SuperInstalledFixture().make()
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-longctx-\(name)",
            weightBytes: UInt64(installed.receipt.payloadBytes), minimumKVBytes: 2 << 30))
        do {
            let owner = try await NemotronSuperLocalBridgeBuilder.make(installed: installed,
                tokenizer: TokenizerHandle(SuperTokenTextTokenizer()), eosTokenIDs: [],
                sizing: .init(weightsBytes: installed.receipt.payloadBytes, fp16KVBytesPerToken: 64,
                    maxContextLength: maxContextLength, defaultMaxTokens: 2),
                kvBytesCapacity: 2 << 30, kvBudget: budget, loadLease: lease,
                construction: construction, environment: [:])
            return (owner, lease, residency)
        } catch {
            installed.closeAfterRetirement()
            #expect(await budget.finishPendingLoad(lease))
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func builderAcceptsTheCeilingAndRefusesBeyondIt() async throws {
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: .max) })
        await #expect(throws: NemotronSuperLocalBridgeBuilder.Failure.unsupportedSizing) {
            _ = try await Self.owner(maxContextLength: Policy.maximumContextTokens + 1, budget: budget,
                                     name: "beyond")
        }
        #expect(await budget.outstandingReservedBytes() == 0)
        let (owner, lease, residency) = try await Self.owner(maxContextLength: Policy.maximumContextTokens,
            budget: budget, name: "ceiling")
        let request = ChatCompletionRequest(model: NemotronSuperLocalBinding.modelID, messages: [],
            temperature: 0, max_tokens: 2)
        try await owner.localTextBinding().run(request: request, promptTokens: [1, 2, 3]) { _ in }
        try await owner.closeAfterDrain()
        #expect(residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    /// A baseline greyscale JPEG container: frame, one empty scan, EOI.
    private static func jpeg(width: Int, height: Int) -> Data {
        Data([0xff, 0xd8, 0xff, 0xc0, 0, 11, 8, UInt8(height >> 8), UInt8(height & 0xff),
              UInt8(width >> 8), UInt8(width & 0xff), 1, 1, 0x11, 0,
              0xff, 0xda, 0, 8, 1, 1, 0, 0, 63, 0, 0xff, 0xd9])
    }

    @Test func imageBindingTakesSixteenLargestImagesWithinTheServedContext() throws {
        let images = Array(repeating: Self.jpeg(width: 2_048, height: 1_664), count: Policy.maximumImages)
        // 16 x 3,328 visual tokens: refused at the former 16,384-token window,
        // as the request's own fault rather than retryable capacity.
        #expect(throws: Binding.Failure.invalidInput) {
            try Binding.encodedPlan(images, contextLength: 16_384)
        }
        let plan = try Binding.encodedPlan(images, contextLength: Policy.contextTokens)
        #expect(plan.grids.reduce(0) { $0 + $1.tokens } == 53_248)
        #expect(throws: Binding.Failure.invalidInput) {
            try Binding.encodedPlan(images, contextLength: Policy.maximumContextTokens + 1)
        }
    }
}
