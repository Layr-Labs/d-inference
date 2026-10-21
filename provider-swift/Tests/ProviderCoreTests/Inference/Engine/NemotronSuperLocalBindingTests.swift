// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXNN
import MLXLLM
import MLXLMCommon
import MLXVLM
import Testing
@testable import ProviderCore

private actor SuperBindingAccounting {
    var acquired = 0
    var released = 0
    var entered = false
    var retirement: CheckedContinuation<Void, Never>?
    func acquire() { acquired += 1 }
    func release() { released += 1 }
    func holdUntilRetired() async {
        entered = true
        await withCheckedContinuation { retirement = $0 }
    }
    func retire() { retirement?.resume(); retirement = nil }
}

struct NemotronSuperLocalBindingTests {
    private func acquisition(_ accounting: SuperBindingAccounting, bridge: EngineV2Bridge?,
                             nativeLease: NativeLocalConsumerLease? = nil)
        -> NemotronSuperLocalBinding.Acquire {
        { model in
            await accounting.acquire()
            return .init(
                tokenizer: TokenizerHandle(StubBridgeTokenizer()),
                releaseToken: OneShotRelease(release: { _ in await accounting.release() }, modelId: model, nativeConsumerLease: nativeLease),
                engineV2Bridge: bridge)
        }
    }

    @Test func calibratedSchedulerHonorsWorkspaceBoundAndPreservesNarrowerPolicies() throws {
        let model = NemotronHModel(NemotronHConfiguration(
            vocabSize: 32, hiddenSize: 4, numHiddenLayers: 1,
            numAttentionHeads: 1, numKeyValueHeads: 1, mambaNumHeads: 1, mambaHeadDim: 4,
            ssmStateSize: 4, convKernel: 4, nGroups: 1, intermediateSize: 4,
            moeIntermediateSize: 4, moeSharedExpertIntermediateSize: 4,
            nRoutedExperts: 2, numExpertsPerTok: 2, hybridOverridePattern: "E", nSharedExperts: 1))
        let baseline = EngineV2Factory.productionSchedulerConfig(maxConcurrentRequests: 1,
            model: model, environment: [:])
        #expect(model.calibratedPrefillTokenLimit == nil)
        let weights = try ModelOptFP8Weights(
            e4m3Bytes: MLXArray(Array(repeating: UInt8(0), count: 16)).reshaped(4, 4), tensorScale: 1)
        let calibrated = try ModelOptCalibratedLinear(weights: weights, inputScale: 1, weightDType: .float32)
        try model.update(modules: .unflattened([
            "backbone.layers.0.mixer.shared_experts.up_proj": calibrated as Module]), verify: .all)
        let limit = try #require(model.calibratedPrefillTokenLimit)
        for cap in [nil, "0", "7", "100000"] as [String?] {
            var environment = [EngineV2Factory.soloPrefillStripeKey: "100000"]
            environment[MixedPrefillPolicy.globalKey] = cap
            let bounded = EngineV2Factory.productionSchedulerConfig(maxConcurrentRequests: 1,
                model: model, environment: environment)
            #expect(bounded.prefillChunkSize == min(baseline.prefillChunkSize, limit))
            #expect(bounded.soloPrefillStripeTokens == nil)
            #expect(bounded.mixedStepPrefillTokenCap == min(cap.flatMap(Int.init) ?? limit, limit))
            #expect(bounded.maxConcurrentPartialPrefills == baseline.maxConcurrentPartialPrefills)
        }
        let unchanged = EngineV2Factory.productionSchedulerConfig(maxConcurrentRequests: 1,
            environment: [EngineV2Factory.soloPrefillStripeKey: "100000", MixedPrefillPolicy.globalKey: "100000"])
        #expect(unchanged.soloPrefillStripeTokens == 100000)
        #expect(unchanged.mixedStepPrefillTokenCap == 100000)
    }

    @Test func missingBridgeReleasesActualAcquiredLease() async throws {
        let accounting = SuperBindingAccounting()
        let binding = NemotronSuperLocalBinding(acquire: acquisition(accounting, bridge: nil))
        await #expect(throws: NemotronSuperLocalBinding.Failure.missingBridge) {
            try await binding.run(request: .init(model: NemotronSuperLocalBinding.modelID, messages: []),
                                  promptTokens: [1], onEvent: { _ in })
        }
        #expect(await accounting.acquired == 1)
        #expect(await accounting.released == 1)
    }

    @Test func unsupportedMediaAndWrongModelNeverAcquire() async throws {
        let accounting = SuperBindingAccounting()
        let binding = NemotronSuperLocalBinding(acquire: acquisition(accounting, bridge: nil))
        await #expect(throws: NemotronSuperLocalBinding.Failure.unsupportedCapability) {
            try await binding.run(request: .init(model: NemotronSuperLocalBinding.modelID, messages: []),
                                  promptTokens: [1], hasMedia: true, onEvent: { _ in })
        }
        await #expect(throws: NemotronSuperLocalBinding.Failure.wrongModel) {
            try await binding.run(request: .init(model: "other", messages: []),
                                  promptTokens: [1], onEvent: { _ in })
        }
        await #expect(throws: NemotronSuperLocalBinding.Failure.unsupportedCapability) {
            try await binding.run(request: .init(model: NemotronSuperLocalBinding.modelID, messages: []),
                                  promptTokens: [18], onEvent: { _ in })
        }
        #expect(await accounting.acquired == 0)
    }

    @Test func drainRetainsLeaseUntilExecutionRetiresAndDoesNotShutdownSharedBridge() async throws {
        let accounting = SuperBindingAccounting()
        let engine = InertStubEngine()
        let bridge = EngineV2Bridge(engine: engine, modelId: NemotronSuperLocalBinding.modelID,
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [])
        let binding = NemotronSuperLocalBinding(
            acquire: acquisition(accounting, bridge: bridge),
            fixtureExecution: { _, _, _, _, _ in
                await accounting.holdUntilRetired()
                try Task.checkCancellation()
            })
        let running = Task {
            try await binding.run(request: .init(model: NemotronSuperLocalBinding.modelID, messages: []),
                                  promptTokens: [1], onEvent: { _ in })
        }
        for _ in 0..<20_000 {
            if await accounting.entered { break }
            await Task.yield()
        }
        try #require(await accounting.entered)
        running.cancel()
        let draining = Task { await binding.drain() }
        #expect(await accounting.released == 0)
        await accounting.retire()
        _ = await running.result
        await draining.value
        #expect(await accounting.released == 1)
        #expect(engine.shutdownCalls == 0)
        await #expect(throws: NemotronSuperLocalBinding.Failure.drained) {
            try await binding.run(request: .init(model: NemotronSuperLocalBinding.modelID, messages: []),
                                  promptTokens: [1], onEvent: { _ in })
        }
        #expect(await accounting.acquired == 1)
    }
    @Test func nativePreparationOwnsExecutionThroughActualLeaseCompletion() async throws {
        let accounting = SuperBindingAccounting()
        let lease = NativeLocalConsumerLease()
        let bridge = EngineV2Bridge(engine: InertStubEngine(), modelId: NemotronSuperLocalBinding.modelID,
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [])
        let binding = NemotronSuperLocalBinding(
            acquire: acquisition(accounting, bridge: bridge, nativeLease: lease),
            fixtureExecution: { _, _, _, _, _ in
                #expect(!lease.snapshot().hasOutstandingHandoff)
                await accounting.holdUntilRetired()
                try Task.checkCancellation()
            })
        let running = Task {
            try await binding.run(request: .init(model: NemotronSuperLocalBinding.modelID, messages: []),
                                  promptTokens: [1], onEvent: { _ in })
        }
        for _ in 0..<20_000 {
            if await accounting.entered { break }
            await Task.yield()
        }
        try #require(await accounting.entered)
        #expect(lease.snapshot().phase == .active)
        #expect(!lease.snapshot().hasOutstandingHandoff)
        lease.closeAndCancel()
        #expect(await accounting.released == 0)
        #expect(lease.snapshot().phase == .closing)
        await accounting.retire()
        _ = await running.result
        #expect(lease.snapshot().phase == .completed)
        #expect(await accounting.released == 1)
        await binding.drain()
        await bridge.shutdown()
    }

    @Test func nativeMissingBridgeDisposesPreparationAndCompletesLease() async throws {
        let accounting = SuperBindingAccounting()
        let lease = NativeLocalConsumerLease()
        let binding = NemotronSuperLocalBinding(acquire: acquisition(accounting, bridge: nil, nativeLease: lease))
        await #expect(throws: NemotronSuperLocalBinding.Failure.missingBridge) {
            try await binding.run(request: .init(model: NemotronSuperLocalBinding.modelID, messages: []),
                                  promptTokens: [1], onEvent: { _ in })
        }
        #expect(lease.snapshot().phase == .completed)
        #expect(await accounting.released == 1)
    }

    @Test func nativeClosedBeforePreparationDisposesTransferredHandoff() async throws {
        let accounting = SuperBindingAccounting()
        let lease = NativeLocalConsumerLease()
        let acquire = acquisition(accounting, bridge: nil, nativeLease: lease)
        let binding = NemotronSuperLocalBinding(acquire: { model in
            let acquired = try await acquire(model)
            lease.closeAndCancel()
            return acquired
        })
        await #expect(throws: NativeLocalConsumerOwnershipError.closed) {
            try await binding.run(request: .init(model: NemotronSuperLocalBinding.modelID, messages: []),
                                  promptTokens: [1], onEvent: { _ in })
        }
        #expect(!lease.snapshot().hasOutstandingHandoff)
        #expect(lease.snapshot().phase == .completed)
        #expect(await accounting.released == 1)
    }

    @Test func realBridgeEarlyRejectionDoesNotAwaitUnregisteredPump() async throws {
        let accounting = SuperBindingAccounting()
        let bridge = EngineV2Bridge(engine: InertStubEngine(), modelId: NemotronSuperLocalBinding.modelID,
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [])
        await bridge.shutdown()
        let binding = NemotronSuperLocalBinding(acquire: acquisition(accounting, bridge: bridge))
        let events = SuperBindingEvents()
        try await binding.run(request: .init(model: NemotronSuperLocalBinding.modelID, messages: []),
                              promptTokens: [1], onEvent: { await events.record($0) })
        #expect(await events.errors == 1)
        #expect(await accounting.released == 1)
    }

}


private actor SuperBindingEvents {
    var errors = 0
    func record(_ event: GenerationEvent) {
        // Count terminal kinds only. Never record prompt, token or event content.
        if case .error = event { errors += 1 }
    }
}


private actor SuperNativeEvents {
    var completions: [Int] = []
    var errors: [String] = []
    func record(_ event: GenerationEvent) {
        switch event {
        case .info(_, let completion, _, _): completions.append(completion)
        case .error(let message): errors.append(message)
        case .terminal(_, let message, _, _): errors.append(message)
        default: break
        }
    }
}

extension NemotronSuperLocalBindingTests {
    @Test(.timeLimit(.minutes(1)), arguments: [(false, false), (true, false), (true, true)])
    func completeInstalledModelRunsThroughRealProviderBridgeAndRetires(withImage: Bool, cancelImage: Bool) async throws {
        let (installed, construction, residency) = try SuperInstalledFixture().make()
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let claim = await budget.claimPendingLoad(requestID: "super-synthetic-load",
            weightBytes: UInt64(installed.receipt.payloadBytes), minimumKVBytes: 2 << 30)
        let lease = try #require(claim)
        let tokenizer = TokenizerHandle(SuperSyntheticTokenizer())
        let owner = try await NemotronSuperLocalBridgeBuilder.make(installed: installed, tokenizer: tokenizer,
            eosTokenIDs: [31], sizing: .init(weightsBytes: installed.receipt.payloadBytes,
                fp16KVBytesPerToken: 64, maxContextLength: 64, defaultMaxTokens: 2),
            kvBytesCapacity: 2 << 30, kvBudget: budget, loadLease: lease,
            construction: construction, environment: [:])
        let accounting = SuperBindingAccounting()
        let binding = NemotronSuperLocalBinding(acquire: acquisition(accounting, bridge: owner.bridge))
        let events = SuperNativeEvents()
        if withImage {
            // Synthetic explicit grant; not a measured production image workspace.
            let mediaGrant = try residency.reserve(.request, bytes: 1 << 20)
            do {
                let prepared = try NemotronSuperVisionPreparation.prepare(installed: installed,
                    prompt: [1, 18, 2],
                    normalizedImages: [MLXArray((0..<16).map { Float($0) / 16 }).reshaped(1, 1, 4, 4)],
                    maximumFeatureBytes: 1024, construction: construction)
                let submission = NemotronSuperVisionSubmission.make(prepared)
                let usage = EngineV2RequestUsageSignal()
                let stream = await owner.bridge.submitTokenized(
                    promptTokens: submission.promptTokens,
                    request: .init(model: NemotronSuperLocalBinding.modelID,
                        messages: [], temperature: 0, max_tokens: cancelImage ? 32 : 2),
                    requestId: "super-synthetic-image", cacheScope: "", cacheEnabled: false,
                    usageSignal: usage, multimodal: submission.multimodalInput())
                var cancelled = false
                for await event in stream {
                    await events.record(event)
                    if cancelImage, !cancelled, case .chunk = event {
                        cancelled = true
                        await owner.bridge.cancel(requestId: "super-synthetic-image")
                    }
                }
                #expect(!cancelImage || cancelled)
                await usage.waitForTerminalObservation()
            }
            #expect(mediaGrant.release())
        } else {
            try await binding.run(request: .init(model: NemotronSuperLocalBinding.modelID,
                messages: [], temperature: 0, max_tokens: 2), promptTokens: [1, 2, 3]) { await events.record($0) }
        }
        let errors = await events.errors
        let completions = await events.completions
        #expect(errors == (cancelImage ? ["request cancelled"] : []), "synthetic bridge errors: \(errors)")
        if cancelImage {
            // Cancellation may race with already-buffered tokens; the guarantee
            // is native retirement and an independently usable bridge afterward.
            let resumed = SuperNativeEvents()
            try await binding.run(request: .init(model: NemotronSuperLocalBinding.modelID,
                messages: [], temperature: 0, max_tokens: 2), promptTokens: [4, 5]) {
                await resumed.record($0)
            }
            #expect(await resumed.errors.isEmpty)
            #expect(await resumed.completions == [2])
        } else { #expect(completions == [2]) }
        #expect(await accounting.released == (withImage && !cancelImage ? 0 : 1))
        await binding.drain()
        try await owner.closeAfterDrain()
        #expect(residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }
}

/// Deliberately tiny fixture tokenizer, never an official tokenizer/parity claim.
struct SuperSyntheticTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1, 2, 3] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.map { $0 == 0 ? "x" : "p" }.joined()
    }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { id == 0 ? "x" : "p" }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        [1, 2, 3]
    }
}
