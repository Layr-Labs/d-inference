// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
@testable import MLXLLM
import MLXLMCommon
import MLXVLM
import Testing
@testable import ProviderCore

/// Fixture tokenizer whose text spells each token id, so streamed chunks
/// expose the exact token sequence. Never an official tokenizer.
struct SuperTokenTextTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1, 2, 3] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.map { "<\($0)>" }.joined()
    }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { "<\(id)>" }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        [1, 2, 3]
    }
}

private actor SuperMTPRun {
    var text = ""
    var completions: [Int] = []
    var errors: [String] = []
    func record(_ event: GenerationEvent) {
        switch event {
        case .chunk(let chunk): text += chunk
        case .info(_, let completion, _, _): completions.append(completion)
        case .error(let message): errors.append(message)
        case .terminal(_, let message, _, _): errors.append(message)
        }
    }
}

struct NemotronSuperLocalMTPTests {
    @Test func speculationIsExplicitOptInWithBoundedDepth() throws {
        typealias MTP = NemotronSuperLocalMTP
        #expect(try MTP.Setting.resolve(environment: [:]) == nil)
        for value in ["0", "true", "yes", "on", ""] {
            #expect(try MTP.Setting.resolve(environment: [MTP.enabledKey: value]) == nil)
        }
        #expect(try MTP.Setting.resolve(environment: [MTP.enabledKey: "1"])?.depth == 1)
        #expect(try MTP.Setting.resolve(
            environment: [MTP.enabledKey: " 1 ", MTP.depthKey: "3"])?.depth == 3)
        // A depth without the enable switch stays off.
        #expect(try MTP.Setting.resolve(environment: [MTP.depthKey: "2"]) == nil)
        for depth in ["0", "4", "two", "-1"] {
            #expect(throws: MTP.Failure.invalidDepth) {
                try MTP.Setting.resolve(environment: [MTP.enabledKey: "1", MTP.depthKey: depth])
            }
        }
        // Rectangular verification is the opt-in default; serial is explicit.
        #expect(try MTP.Setting.resolve(environment: [MTP.enabledKey: "1"])?.verification
            == .rectangularExact)
        #expect(try MTP.Setting.resolve(environment: [MTP.enabledKey: "1",
            MTP.verificationKey: " serial "]) == .init(depth: 1, verification: .serial))
        #expect(try MTP.Setting.resolve(environment: [MTP.enabledKey: "1",
            MTP.verificationKey: "rectangular", MTP.depthKey: "2"])
            == .init(depth: 2, verification: .rectangularExact))
        #expect(try MTP.Setting.resolve(environment: [MTP.verificationKey: "serial"]) == nil)
        // "auto" lets the engine pick each step's depth up to the maximum.
        #expect(try MTP.Setting.resolve(environment: [MTP.enabledKey: "1", MTP.depthKey: "auto"])
            == .init(depth: 3, verification: .rectangularExact, adaptive: true))
        #expect(throws: MTP.Failure.invalidDepth) {
            try MTP.Setting.resolve(environment: [MTP.enabledKey: "1", MTP.depthKey: "auto",
                MTP.verificationKey: "serial"])
        }
        for value in ["", "Serial", "rectangularExact", "automatic", "rectangular_exact"] {
            #expect(throws: MTP.Failure.invalidVerification) {
                try MTP.Setting.resolve(
                    environment: [MTP.enabledKey: "1", MTP.verificationKey: value])
            }
        }
        #expect(throws: MTP.Failure.loadQuote) {
            try MTP.loadSupplementBytes(.init(payloadBytes: 0, constructionBytes: 1))
        }
        #expect(try MTP.loadSupplementBytes(.init(payloadBytes: 3, constructionBytes: 4)) == 7)
    }

    /// The shared factory serves both speculative targets like the ordinary
    /// adapter: same layer kinds and capabilities plus MTP, and the same hard
    /// calibrated prefill bound on every scheduler.
    @Test func sharedFactoryRecognizesTheSpeculativeTextTargets() throws {
        let fixture = try SuperMTPInstalledFixture().make()
        let model = try #require(fixture.installed.model)
        let adapter = NemotronSuperRecurrentAdapter(model)
        let target = NemotronSuperMTPTextTarget(model)
        let capture = try NemotronSuperMTPCaptureTarget(capturing: model)
        let limit = try #require(adapter.calibratedPrefillTokenLimit)
        var capabilities = adapter.cbv2Capabilities
        #expect(!capabilities.supportsMTP)
        capabilities.supportsMTP = true
        for speculative in [target, capture] {
            #expect(EngineV2Factory.calibratedPrefillTokenLimit(model: speculative) == limit)
            #expect(EngineV2Factory.cbv2LayerKinds(model: speculative) == adapter.cbv2LayerKinds)
            let resolved = try #require(EngineV2Factory.ProductionModelAdapter(model: speculative))
            #expect(resolved.modelCapabilities == capabilities)
        }
        for served in [adapter, target, capture] as [any LanguageModel] {
            let config = EngineV2Factory.productionSchedulerConfig(
                maxConcurrentRequests: 1, model: served, environment: [:])
            #expect(config.prefillChunkSize <= limit && config.soloPrefillStripeTokens == nil)
        }
        fixture.installed.closeAfterRetirement()
    }

    /// With speculation the refused grant's report includes the assistant's
    /// bounded per-request charge, so its minimum exceeds the plain owner's.
    @Test(.timeLimit(.minutes(2))) func speculativeGrantRefusalReportsTheAssistantCharge() async throws {
        let grant = Int(UnifiedMemoryCap.minimumLoadKVBytes)
        var refusals: [NemotronSuperLocalBridgeBuilder.UnserviceableGrant] = []
        for setting in [nil, NemotronSuperLocalMTP.Setting(depth: 1)] {
            let fixture = try SuperMTPInstalledFixture().make()
            let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
                memorySnapshot: { .init(total: 16 << 30, active: 0, cache: 0, systemAvailable: .max) })
            let bytes = fixture.installed.receipt.payloadBytes
                + (try NemotronSuperLocalMTP.loadSupplementBytes(fixture.headQuote))
            let lease = try #require(await budget.claimPendingLoad(requestID: "super-mtp-grant",
                weightBytes: UInt64(bytes), minimumKVBytes: UInt64(grant)))
            do {
                _ = try await NemotronSuperLocalBridgeBuilder.make(installed: fixture.installed,
                    tokenizer: TokenizerHandle(SuperTokenTextTokenizer()), eosTokenIDs: [63],
                    sizing: .init(weightsBytes: fixture.installed.receipt.payloadBytes,
                        fp16KVBytesPerToken: 64, maxContextLength: 64, defaultMaxTokens: 16),
                    kvBytesCapacity: grant, kvBudget: budget, loadLease: lease,
                    construction: fixture.construction,
                    mtp: setting.map { .init(module: fixture.head, setting: $0) }, environment: [:])
                Issue.record("a minimum-KV grant served")
            } catch let refusal as NemotronSuperLocalBridgeBuilder.UnserviceableGrant {
                refusals.append(refusal)
            }
            fixture.installed.closeAfterRetirement()
            #expect(await budget.finishPendingLoad(lease))
        }
        let (plain, speculative) = (try #require(refusals.first), try #require(refusals.last))
        #expect(refusals.count == 2 && speculative.fixedRequestBytes > plain.fixedRequestBytes)
        #expect(speculative.minimumGrantBytes > plain.minimumGrantBytes)
    }

    private func owner(_ fixture: SuperMTPInstalledFixture.Installation,
                       setting: NemotronSuperLocalMTP.Setting?,
                       budget: GlobalKVCacheBudget, lease: PendingModelLoadLease)
        async throws -> NemotronSuperLocalBridgeBuilder.Owner {
        try await NemotronSuperLocalBridgeBuilder.make(installed: fixture.installed,
            tokenizer: TokenizerHandle(SuperTokenTextTokenizer()), eosTokenIDs: [63],
            sizing: .init(weightsBytes: fixture.installed.receipt.payloadBytes,
                fp16KVBytesPerToken: 64, maxContextLength: 64, defaultMaxTokens: 16),
            kvBytesCapacity: 2 << 30, kvBudget: budget, loadLease: lease,
            construction: fixture.construction,
            mtp: setting.map { .init(module: fixture.head, setting: $0) },
            environment: [:])
    }

    private func run(_ owner: NemotronSuperLocalBridgeBuilder.Owner, prompt: [Int], maxTokens: Int)
        async throws -> (text: String, completions: [Int], errors: [String]) {
        let binding = NemotronSuperLocalBinding(acquire: { model in
            .init(tokenizer: TokenizerHandle(SuperTokenTextTokenizer()),
                releaseToken: OneShotRelease(release: { _ in }, modelId: model),
                engineV2Bridge: owner.bridge)
        })
        let events = SuperMTPRun()
        try await binding.run(request: .init(model: NemotronSuperLocalBinding.modelID,
            messages: [], temperature: 0, max_tokens: maxTokens), promptTokens: prompt) {
            await events.record($0)
        }
        await binding.drain()
        return (await events.text, await events.completions, await events.errors)
    }

    @Test(.timeLimit(.minutes(3)), arguments: [
        (1, NemotronSuperLocalMTP.Setting.Verification.rectangularExact), (3, .rectangularExact),
        (1, .serial), (3, .serial),
    ])
    func speculativeOwnerServesExactTextRefusesMediaAndRetires(
        depth: Int, verification: NemotronSuperLocalMTP.Setting.Verification
    ) async throws {
        let plainFixture = try SuperMTPInstalledFixture().make()
        let speculativeFixture = try SuperMTPInstalledFixture().make()
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 16 << 30, active: 0, cache: 0, systemAvailable: .max) })
        var leases: [PendingModelLoadLease] = []
        for (name, fixture) in [("plain", plainFixture), ("speculative", speculativeFixture)] {
            let bytes = fixture.installed.receipt.payloadBytes
                + (try NemotronSuperLocalMTP.loadSupplementBytes(fixture.headQuote))
            leases.append(try #require(await budget.claimPendingLoad(
                requestID: "super-mtp-\(name)", weightBytes: UInt64(bytes), minimumKVBytes: 2 << 30)))
        }
        let plain = try await owner(plainFixture, setting: nil, budget: budget, lease: leases[0])
        let speculative = try await owner(speculativeFixture,
            setting: .init(depth: depth, verification: verification), budget: budget,
            lease: leases[1])
        #expect(!plain.speculates && speculative.speculates)
        for (prompt, maxTokens) in [([1, 2, 3], 9), ([5, 9, 1, 4, 22, 7, 3, 8, 30], 14), ([40], 1)] {
            let expected = try await run(plain, prompt: prompt, maxTokens: maxTokens)
            let actual = try await run(speculative, prompt: prompt, maxTokens: maxTokens)
            #expect(expected.errors.isEmpty && actual.errors.isEmpty, "\(actual.errors)")
            #expect(actual.text == expected.text,
                "prompt \(prompt) depth \(depth) \(verification)")
            #expect(actual.completions == expected.completions)
        }
        let ownedEngine = await speculative.bridge.ownedEngine
        let engine = try #require(ownedEngine as? EngineV2)
        let metrics = try #require(engine.mtpMetricsSnapshot())
        let rectangular = verification == .rectangularExact
        #expect(metrics.rounds > 0)
        #expect(metrics.serialVerificationRounds == (rectangular ? 0 : metrics.rounds))
        #expect(metrics.rectangularVerificationRounds == (rectangular ? metrics.rounds : 0))
        // The engine shortens the final rounds near the length bound.
        #expect(metrics.draftedTokens <= metrics.rounds * depth)
        #expect(metrics.draftedTokens >= metrics.rounds && metrics.acceptedTokens > 0)
        let plainEngine = await plain.bridge.ownedEngine
        #expect((plainEngine as? EngineV2)?.mtpMetricsSnapshot() == nil)
        print("SYNTHETIC provider super-mtp depth=\(depth) \(verification) rounds=\(metrics.rounds) "
            + "drafted=\(metrics.draftedTokens) accepted=\(metrics.acceptedTokens) "
            + "emitted=\(metrics.emittedTokens)")
        #expect(throws: NemotronSuperLocalBridgeBuilder.Failure.self) {
            try speculative.localImageBinding()
        }
        #expect(throws: NemotronSuperLocalBridgeBuilder.Failure.self) {
            try speculative.localImagePrompt(body: Data(), templateBytes: Data(), featureCounts: [1])
        }
        try await plain.closeAfterDrain()
        try await speculative.closeAfterDrain()
        #expect(plainFixture.residency.snapshot.usedBytes == 0)
        #expect(speculativeFixture.residency.snapshot.usedBytes == 0)
        for lease in leases { #expect(await budget.finishPendingLoad(lease)) }
        #expect(await budget.outstandingReservedBytes() == 0)
    }
}
