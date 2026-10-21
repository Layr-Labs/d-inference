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
    /// `latentMoE` stages the MTP fixture's latent-MoE target, the layout the
    /// row-exact batched decode supports, without loading its head.
    private static func owner(kvBytesCapacity: Int = 2 << 30,
        tokenizer: any MLXLMCommon.Tokenizer = SuperTokenTextTokenizer(),
        environment: [String: String] = [:], latentMoE: Bool = false) async throws
        -> (NemotronSuperLocalBridgeBuilder.Owner, NemotronSuperInstallation.Installed,
            NemotronSuperResidency, GlobalKVCacheBudget, PendingModelLoadLease) {
        let (installed, construction, residency) = try latentMoE
            ? { let f = try SuperMTPInstalledFixture().make(); return (f.installed, f.construction, f.residency) }()
            : SuperInstalledFixture().make()
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
            construction: construction, environment: environment)
        return (owner, installed, residency, budget, lease)
    }

    /// Each request's shared-budget charge carries one batched decode row from
    /// admission until it retires; the owner's single prefill lane (the graph
    /// path's ModelOpt workspace for one chunk) is held from before the first
    /// request until native retirement, whatever the number of requests.
    @Test(.timeLimit(.minutes(1)))
    func requestsChargeADecodeRowAndTheOwnerOnePrefillLane() async throws {
        let (owner, installed, residency, budget, lease) = try await Self.owner()
        let language = try #require(installed.model?.languageModel)
        let chunk = owner.prefill.chunkTokens
        #expect(chunk == min(2048, try #require(language.calibratedPrefillTokenLimit)))
        let prefill = try #require(language.modelOptGraphPrefillWorkspaceBytes(tokens: chunk))
        let row = try language.superDecodeCharge(kvElementBytes: 2).rowWorkspace.totalBytes
        let workspace = try NemotronSuperLocalBridgeBuilder.requestWorkspaceBytes(language)
        #expect(prefill > 0 && row > 0 && workspace == row && owner.prefillLaneBytes == prefill)
        let lane = await budget.reservationBytesSnapshot()
        #expect(lane.count == 1 && lane.first.map { NemotronSuperLocalPrefill.isLaneReservationID($0.key) } == true
            && lane.first?.value == UInt64(prefill))
        let ownedEngine = await owner.bridge.ownedEngine
        let engine = try #require(ownedEngine as? EngineV2)
        #expect(await owner.bridge.fixedRequestBytes == engine.resolvedFixedBytesPerRequest + workspace)
        // Long enough that event callbacks observe the request still in flight.
        let request = ChatCompletionRequest(model: NemotronSuperLocalBinding.modelID,
            messages: [], temperature: 0, max_tokens: 12)
        let expected = try #require(await owner.bridge.requestReservationBytes(tokenCount: 15))
        #expect(expected >= workspace)
        let observed = SuperOwnerCharges()
        try await owner.localTextBinding().run(request: request, promptTokens: [1, 2, 3]) { _ in
            await observed.record(await budget.reservationBytesSnapshot())
        }
        let rows = await observed.rows
        #expect(rows.contains([expected, prefill].sorted()), "\(rows)")
        #expect(rows.allSatisfy { $0.contains(prefill) })
        #expect(await budget.reservationBytesSnapshot() == lane)
        try await owner.closeAfterDrain()
        #expect(await budget.reservationBytesSnapshot().isEmpty)
        #expect(residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    /// A grant that cannot hold one request's fixed workspace plus the minimum
    /// KV fails the build, naming the grant, the smallest serviceable grant and
    /// the fixed request bytes, instead of publishing a zero-width owner. A
    /// grant of that minimum serves.
    @Test(.timeLimit(.minutes(1))) func unserviceableGrantFailsTheBuildWithTheMinimum() async throws {
        let grant = Int(UnifiedMemoryCap.minimumLoadKVBytes)
        var refusal: NemotronSuperLocalBridgeBuilder.UnserviceableGrant?
        do { _ = try await Self.owner(kvBytesCapacity: grant) } catch let error as
            NemotronSuperLocalBridgeBuilder.UnserviceableGrant { refusal = error }
        let refused = try #require(refusal)
        #expect(refused.grantBytes == grant && refused.minimumGrantBytes > grant && refused.requests == 1)
        #expect(refused.fixedRequestBytes > 0
            && refused.minimumGrantBytes >= grant + refused.fixedRequestBytes)
        #expect("\(refused)".contains("\(refused.minimumGrantBytes)-byte minimum"))
        let (owner, _, residency, budget, lease) = try await Self.owner(
            kvBytesCapacity: refused.minimumGrantBytes)
        #expect(await owner.bridge.effectiveServingConcurrency == 1)
        #expect(await owner.bridge.maximumRequestOverheadBytes() == refused.fixedRequestBytes)
        try await owner.closeAfterDrain()
        #expect(residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
    }

    /// Concurrency is an explicit opt-in, bounded by the adapter's decode rows
    /// and, with speculation, by the requests of one captured verify window.
    @Test func concurrencyIsAnExplicitBoundedOptIn() throws {
        typealias Builder = NemotronSuperLocalBridgeBuilder
        let key = Builder.maxConcurrentKey
        #expect(try Builder.concurrentRequests(environment: [:], speculates: false) == 1)
        #expect(try Builder.concurrentRequests(environment: [key: " 8 "], speculates: false) == 8)
        #expect(try Builder.concurrentRequests(environment: [key: "64"], speculates: false) == 64)
        #expect(try Builder.concurrentRequests(environment: [key: "1"], speculates: true) == 1)
        for value in ["0", "65", "-1", "two", "", "2.5"] {
            #expect(throws: Builder.Failure.invalidConcurrency) {
                try Builder.concurrentRequests(environment: [key: value], speculates: false)
            }
        }
        #expect(try Builder.concurrentRequests(environment: [key: "2"], speculates: true) == 2)
        #expect(try Builder.concurrentRequests(environment: [key: "8"], speculates: true) == 8)
        for value in ["0", "9", "64"] {
            #expect(throws: Builder.Failure.invalidConcurrency) {
                try Builder.concurrentRequests(environment: [key: value], speculates: true)
            }
        }
    }

    /// A batched owner serves N requests through one row-exact adapter, charges
    /// every request its recurrent generations plus the request workspace, and
    /// needs a grant that holds all N; the refusal names that grant.
    @Test(.timeLimit(.minutes(2))) func batchedOwnerChargesEveryRequestAndNeedsAGrantForAll() async throws {
        let environment = [NemotronSuperLocalBridgeBuilder.maxConcurrentKey: "2"]
        let grant = Int(UnifiedMemoryCap.minimumLoadKVBytes)
        var refusal: NemotronSuperLocalBridgeBuilder.UnserviceableGrant?
        do { _ = try await Self.owner(kvBytesCapacity: grant, environment: environment, latentMoE: true) }
        catch let error as
            NemotronSuperLocalBridgeBuilder.UnserviceableGrant { refusal = error }
        let refused = try #require(refusal)
        #expect(refused.requests == 2 && refused.minimumGrantBytes >= grant + 2 * refused.fixedRequestBytes)
        let (owner, installed, residency, budget, lease) = try await Self.owner(
            kvBytesCapacity: refused.minimumGrantBytes, environment: environment, latentMoE: true)
        #expect(owner.maximumLocalRequests == 2)
        #expect(await owner.bridge.maxConcurrentRequests == 2)
        #expect(await owner.bridge.effectiveServingConcurrency == 2)
        let language = try #require(installed.model?.languageModel)
        let charge = try language.superDecodeCharge(kvElementBytes: 2)
        let ownedEngine = await owner.bridge.ownedEngine
        let engine = try #require(ownedEngine as? EngineV2)
        #expect(engine.resolvedFixedBytesPerRequest
            == charge.recurrentGenerations * charge.recurrentBytesPerGeneration)
        let workspace = try NemotronSuperLocalBridgeBuilder.requestWorkspaceBytes(language)
        #expect(await owner.bridge.fixedRequestBytes == engine.resolvedFixedBytesPerRequest + workspace)
        #expect(owner.admitLocalRequest() && owner.admitLocalRequest() && !owner.admitLocalRequest())
        owner.finishLocalRequest()
        #expect(owner.admitLocalRequest())
        owner.finishLocalRequest(); owner.finishLocalRequest()
        try await owner.closeAfterDrain()
        #expect(residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
        // A width above the M5 paged default is the operator's explicit
        // choice, not a power- or thermal-gated expansion.
        let wide = try await Self.owner(kvBytesCapacity: 4 << 30,
            environment: [NemotronSuperLocalBridgeBuilder.maxConcurrentKey: "12"], latentMoE: true)
        #expect(await !wide.0.bridge.hasPostureGatedWidth)
        #expect(await wide.0.bridge.effectiveServingConcurrency == 12)
        try await wide.0.closeAfterDrain()
        #expect(await wide.3.finishPendingLoad(wide.4))
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

private actor SuperOwnerCharges {
    var rows: [[Int]] = []
    func record(_ snapshot: [String: UInt64]) { rows.append(snapshot.values.map { Int($0) }.sorted()) }
}
