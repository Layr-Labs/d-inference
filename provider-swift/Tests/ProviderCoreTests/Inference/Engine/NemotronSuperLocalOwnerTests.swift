// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLLM
@testable import MLXLMCommon
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

    /// The owner reserves one batched decode row per configured request and
    /// its single prefill lane (the graph path's ModelOpt workspace for one
    /// chunk) from before the first request until native retirement. The
    /// bridge counts the row in every request's fixed bytes, but on paged
    /// storage a request adds no shared-budget reservation of its own.
    @Test(.timeLimit(.minutes(1)))
    func ownerHoldsItsDecodeRowsAndOnePrefillLaneAcrossRequests() async throws {
        let (owner, installed, residency, budget, lease) = try await Self.owner()
        let language = try #require(installed.model?.languageModel)
        let chunk = owner.prefill.chunkTokens
        #expect(chunk == min(2048, try #require(language.calibratedPrefillTokenLimit)))
        let prefill = try #require(language.modelOptGraphPrefillWorkspaceBytes(tokens: chunk))
        let row = try language.superDecodeCharge(kvElementBytes: 2).rowWorkspace.totalBytes
        let workspace = try NemotronSuperLocalBridgeBuilder.requestWorkspaceBytes(language)
        #expect(prefill > 0 && row > 0 && workspace == row && owner.prefillLaneBytes == prefill)
        #expect(owner.decodeRowsBytes == workspace)
        let idle = await budget.reservationBytesSnapshot()
        #expect(idle.count == 2)
        #expect(idle.filter { NemotronSuperLocalPrefill.isLaneReservationID($0.key) }.values.map { Int($0) }
            == [prefill])
        #expect(idle.filter { NemotronSuperLocalKVBackend.isDecodeRowsReservationID($0.key) }.values
            .map { Int($0) } == [workspace])
        let ownedEngine = await owner.bridge.ownedEngine
        let engine = try #require(ownedEngine as? EngineV2)
        #expect(await owner.bridge.kvBackendKind == .paged)
        #expect(await owner.bridge.fixedRequestBytes == engine.resolvedFixedBytesPerRequest + workspace)
        let request = ChatCompletionRequest(model: NemotronSuperLocalBinding.modelID,
            messages: [], temperature: 0, max_tokens: 12)
        let observed = SuperOwnerCharges()
        // Hold the request before its native terminal, while it is still
        // admitted, so the in-flight reservations are observed without racing
        // event delivery; then let it retire.
        let gate = SuperHTTPTerminalGate()
        await owner.bridge._testInstallPersistentTerminalGate { _ in await gate.hold() }
        let binding = try owner.localTextBinding()
        let run = Task {
            try await binding.run(request: request, promptTokens: [1, 2, 3]) { _ in
                await observed.record(await budget.reservationBytesSnapshot())
            }
        }
        try await superHTTPEventually("request held before its native terminal") { await gate.entered }
        #expect(await budget.reservationBytesSnapshot() == idle)
        await gate.release()
        try await run.value
        await owner.bridge._testInstallPersistentTerminalGate(nil)
        #expect(!(await gate.timedOut))
        let held = idle.values.map { Int($0) }.sorted()
        #expect(!(await observed.rows.isEmpty))
        #expect(await observed.rows.allSatisfy { $0 == held })
        #expect(await budget.reservationBytesSnapshot() == idle)
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
        // Paged prices footprints: live generations x one generation's conv and SSM buffers, each allocator-rounded.
        let policy = try #require(Memory.allocationFootprintPolicy())
        let generationBytes = try language.cbv2RecurrentStateSpec.allocationBytesPerGeneration(policy: policy)
        #expect(engine.resolvedFixedBytesPerRequest == charge.recurrentGenerations * generationBytes)
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
        // The framed span must fit the context: 62 features plus 2 markers do
        // not, which is the request's own fault (400), not capacity.
        #expect(throws: NemotronSuperLocalImageBinding.Failure.invalidInput) {
            try owner.localImagePrompt(body: body, templateBytes: template, featureCounts: [62])
        }
        #expect(throws: NemotronSuperLocalImageBinding.Failure.invalidInput) {
            try owner.localImagePrompt(body: body, templateBytes: template, featureCounts: [2, 2])
        }
        try await owner.closeAfterDrain()
        #expect(residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
    }

    /// The owner's lock covers only an image step's admission check: while
    /// an image prompt renders, text admission returns at once.
    @Test(.timeLimit(.minutes(1))) func imagePromptRendersOutsideTheOwnerLock() async throws {
        try await Self.expectTextAdmittedWhileRendering(base: SuperSyntheticImageTokenizer(),
            media: ["type": "image_url", "image_url": ["url": "data:image/png;base64,AA=="]],
            expected: [1, 19, 18, 18, 18, 20, 2]
        ) { owner, body, template in
            try owner.localImagePrompt(body: body, templateBytes: template, featureCounts: [3])
        }
    }

    /// Likewise for a video prompt: while its template renders, text
    /// admission returns at once.
    @Test(.timeLimit(.minutes(1))) func videoPromptRendersOutsideTheOwnerLock() async throws {
        let labels = ["Frame 1 sampled at 0.00 seconds and frame 2 sampled at 0.50 seconds: "]
        try await Self.expectTextAdmittedWhileRendering(base: SuperSyntheticVideoTokenizer(),
            media: ["type": "video_url", "video_url": ["url": "data:video/mp4;base64,AA=="]],
            expected: NemotronSuperPromptContract.VideoPrompt(prefix: [1], labels: [[3, 4]], suffix: [2])
        ) { owner, body, template in
            try owner.localVideoPrompt(body: body, templateBytes: template, labels: labels)
        }
    }

    /// Renders the prompt of a text part and `media` with `render` while a
    /// gate holds its template render in `base`; text admission must return
    /// meanwhile, and the prompt must equal `expected`.
    private static func expectTextAdmittedWhileRendering<Prompt: Equatable & Sendable>(
        base: any MLXLMCommon.Tokenizer, media: [String: Any], expected: Prompt,
        render: @escaping @Sendable (NemotronSuperLocalBridgeBuilder.Owner, Data, Data) throws -> Prompt
    ) async throws {
        let gate = SuperRenderGate()
        let (owner, _, residency, budget, lease) = try await Self.owner(
            tokenizer: SuperGatedRenderTokenizer(base: base, gate: gate))
        let template = try #require(Data(base64Encoded: superImagePinnedTemplateBase64,
                                        options: .ignoreUnknownCharacters))
        let body = try JSONSerialization.data(withJSONObject: [
            "model": NemotronSuperLocalBinding.modelID,
            "messages": [["role": "user", "content": [["type": "text", "text": "fixture"], media]]]])
        let prompt = Task.detached { try render(owner, body, template) }
        #expect(await SuperRenderGate.wait(gate.entered))
        // Its own thread: an admission blocked on the lock must not hold the pool.
        let admitted = DispatchSemaphore(value: 0)
        Thread.detachNewThread { if owner.admitLocalRequest() { admitted.signal() } }
        let returned = await SuperRenderGate.wait(admitted)
        gate.release.signal()
        #expect(returned, "text admission waited for a media prompt to render")
        #expect(try await prompt.value == expected)
        if returned { owner.finishLocalRequest() }
        try await owner.closeAfterDrain()
        #expect(residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
    }
}

/// Holds a media prompt render inside the tokenizer until released.
private final class SuperRenderGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    /// Waits off the cooperative pool, at most five seconds.
    static func wait(_ semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success)
            }
        }
    }
}

/// `base`, whose template render waits on a gate.
private struct SuperGatedRenderTokenizer: MLXLMCommon.Tokenizer {
    let base: any MLXLMCommon.Tokenizer
    let gate: SuperRenderGate
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        base.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        base.decode(tokenIds: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
    var bosToken: String? { base.bosToken }
    var eosToken: String? { base.eosToken }
    var unknownToken: String? { base.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        try base.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
    func applyChatTemplate(messages: [[String: any Sendable]], chatTemplate: String,
                           tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        gate.entered.signal()
        _ = gate.release.wait(timeout: .now() + 10)
        return try base.applyChatTemplate(messages: messages, chatTemplate: chatTemplate, tools: tools,
                                          additionalContext: additionalContext)
    }
}

private actor SuperOwnerCharges {
    var rows: [[Int]] = []
    func record(_ snapshot: [String: UInt64]) { rows.append(snapshot.values.map { Int($0) }.sorted()) }
}
