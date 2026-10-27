// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// A Super bank built with a routing identity advertises it as a resident
/// capability, proves its lookups and publications on the coordinator's
/// 256-token chain and reports the prompt tokens a restore reused, on the
/// plain and on the speculating owner. Another scope never hits, and its cold
/// text equals the restored text. Without an identity, or without a bank,
/// the owner advertises nothing.
struct NemotronSuperPrefixCacheEvidenceTests {
    typealias Builder = NemotronSuperLocalBridgeBuilder
    typealias Prefix = NemotronSuperLocalPrefixCache

    static let memoryKey = "DARKBLOOM_PREFIX_CACHE_MEMORY"
    /// The coordinator's block size: checkpoints at 256, 512, ...
    static let chunk = 256
    static let environment = [NemotronSuperLocalPrefill.chunkKey: String(chunk), memoryKey: "1"]
    static let grant: Int = 2 << 30
    static let routing = Prefix.RoutingIdentity(modelAggregateHash: String(repeating: "a", count: 64),
                                                promptContractID: String(repeating: "b", count: 64))

    /// 600 fixture tokens (18, the image placeholder, is left out): chunk
    /// checkpoints at 256 and 512, and a 512-token proof floor.
    static let donor: [Int] = Array((0 ..< 700).map { (index: Int) -> Int in (index * 7 + 3) % 61 + 1 }
        .filter { (token: Int) -> Bool in token != 18 }.prefix(600))
    static let adopter: [Int] = donor + (0 ..< 120).map { (index: Int) -> Int in (index * 5 + 2) % 61 + 1 }
        .filter { (token: Int) -> Bool in token != 18 }

    /// One request's signal and the lookup and ready results it delivered,
    /// as the coordinator receipts see them.
    final class Receipts: @unchecked Sendable {
        private final class Log: @unchecked Sendable {
            let lock = NSLock()
            var lookups: [PrefixCacheLookupResult] = []
            var ready: [PrefixCacheReadyResult] = []
        }
        private let log: Log
        let signal: EngineV2RequestUsageSignal

        init() {
            let log = Log()
            self.log = log
            signal = EngineV2RequestUsageSignal(
                onLookupResolved: { result in log.lock.withLock { log.lookups.append(result) } },
                onCacheReady: { result in log.lock.withLock { log.ready.append(result) } })
        }

        var lookups: [PrefixCacheLookupResult] { log.lock.withLock { log.lookups } }
        var ready: [PrefixCacheReadyResult] { log.lock.withLock { log.ready } }
    }

    actor Events {
        var text = ""
        var errors: [String] = []
        func record(_ event: GenerationEvent) {
            switch event {
            case .chunk(let chunk): text += chunk
            case .info: break
            case .error(let message): errors.append(message)
            case .terminal(_, let message, _, _): errors.append(message)
            }
        }
    }

    static func budget() -> GlobalKVCacheBudget {
        GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: .max) })
    }

    static func lease(_ fixture: SuperMTPInstalledFixture.Installation, _ name: String,
                              budget: GlobalKVCacheBudget, speculates: Bool) async throws -> PendingModelLoadLease {
        let head = speculates ? try NemotronSuperLocalMTP.loadSupplementBytes(fixture.headQuote) : 0
        return try #require(await budget.claimPendingLoad(requestID: "super-evidence-\(name)",
            weightBytes: UInt64(fixture.installed.receipt.payloadBytes + head),
            minimumKVBytes: UInt64(grant)))
    }

    static func owner(_ fixture: SuperMTPInstalledFixture.Installation,
                              environment: [String: String], budget: GlobalKVCacheBudget,
                              lease: PendingModelLoadLease, speculates: Bool,
                              routing: Prefix.RoutingIdentity?,
                              modelID: String = NemotronSuperLocalBinding.modelID,
                              completeCheckpointIdentity: CBv2CompleteCheckpointIdentity? = nil)
        async throws -> Builder.Owner {
        try await Builder.make(installed: fixture.installed,
            tokenizer: TokenizerHandle(SuperTokenTextTokenizer()), eosTokenIDs: [63],
            sizing: .init(weightsBytes: fixture.installed.receipt.payloadBytes,
                fp16KVBytesPerToken: 64, maxContextLength: 1024, defaultMaxTokens: 16),
            kvBytesCapacity: grant, kvBudget: budget, loadLease: lease,
            construction: fixture.construction,
            mtp: speculates ? .init(module: fixture.head, setting: .init(depth: 3)) : nil,
            modelID: modelID, environment: environment, routingIdentity: routing,
            completeCheckpointIdentity: completeCheckpointIdentity)
    }

    static func run(_ owner: Builder.Owner, prompt: [Int], scope: String,
                            receipts: Receipts) async throws -> String {
        let events = Events()
        try await owner.localTextBinding().run(request: .init(model: owner.modelID,
            messages: [], temperature: 0, max_tokens: 8), promptTokens: prompt, cacheScope: scope,
            usageSignal: receipts.signal) { await events.record($0) }
        #expect(await events.errors.isEmpty)
        return await events.text
    }

    /// Polls `condition` for up to five seconds.
    static func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test(.timeLimit(.minutes(3)), arguments: [false, true])
    func routedBankAdvertisesProvesAndReportsItsReuse(speculates: Bool) async throws {
        let budget = Self.budget()
        let fixture = try SuperMTPInstalledFixture().make()
        let lease = try await Self.lease(fixture, "routed", budget: budget, speculates: speculates)
        let owner = try await Self.owner(fixture, environment: Self.environment, budget: budget,
            lease: lease, speculates: speculates, routing: Self.routing)
        let capability = try #require(owner.bridge.residentPrefixCacheEvidence?.capability())
        #expect(capability.modelId == NemotronSuperLocalBinding.modelID)
        #expect(capability.modelAggregateHash == Self.routing.modelAggregateHash)
        #expect(capability.promptContractId == Self.routing.promptContractID)
        #expect(capability.blockHashVersion == CBv2BlockHasher.version)
        #expect(capability.blockSize == UInt32(CBv2BlockHasher.defaultBlockSize))
        #expect(capability.enabled && capability.ready)

        let chain = CBv2BlockHasher(promptContractID: Self.routing.promptContractID, scopeID: "tenant-a")
        let anchors = chain.chainHashes(tokens: Self.adopter, maxBlocks: 2).enumerated().map {
            PrefixCacheAnchor(chainHash: $1.hexString, tokenCount: UInt64(($0 + 1) * Self.chunk))
        }

        // The donor misses, then publishes the chunk checkpoints it captured.
        let donor = Receipts()
        _ = try await Self.run(owner, prompt: Self.donor, scope: "tenant-a", receipts: donor)
        let missed = try #require(donor.lookups.first)
        #expect(donor.lookups.count == 1)
        #expect(missed.outcome == .missAbsent && missed.tier == .memory && missed.cachedTokens == 0)
        #expect(missed.promptAnchor == anchors[1], "the donor shares the adopter's first 512 tokens")
        let published = await Self.eventually { !donor.ready.isEmpty }
        #expect(published)
        let ready = try #require(donor.ready.last)
        #expect(ready.tier == .memory && ready.readyAnchors == anchors)
        #expect(donor.signal.prefixCacheHitTokens == 0)

        // The next turn restores the deepest checkpoint below its last token.
        let adopter = Receipts()
        let restored = try await Self.run(owner, prompt: Self.adopter, scope: "tenant-a", receipts: adopter)
        let hit = try #require(adopter.lookups.first)
        #expect(hit.outcome == .hit && hit.tier == .memory)
        #expect(hit.cachedTokens == 512 && hit.prefillTokensSaved == 512)
        #expect(hit.matchedAnchor == anchors[1])
        #expect(adopter.signal.prefixCacheHitTokens == 512)
        #expect(adopter.signal.lookupResult?.cachedTokens == 512)

        // Another tenant's identical prompt is cold, with the same text.
        let other = Receipts()
        let cold = try await Self.run(owner, prompt: Self.adopter, scope: "tenant-b", receipts: other)
        let miss = try #require(other.lookups.first)
        #expect(miss.outcome == .missAbsent && miss.cachedTokens == 0)
        #expect(miss.promptAnchor != hit.promptAnchor, "the chain is bound to the scope")
        #expect(other.signal.prefixCacheHitTokens == 0)
        #expect(!cold.isEmpty)
        #expect(restored == cold)

        try await owner.closeAfterDrain()
        #expect(owner.bridge.residentPrefixCacheEvidence?.capability() == nil, "closed with its bridge")
        #expect(await budget.reservationBytesSnapshot().isEmpty)
        #expect(await budget.finishPendingLoad(lease))
    }

    /// No routing identity, or a routing identity without a bank: nothing to
    /// advertise, and requests report no reuse.
    @Test(.timeLimit(.minutes(3)))
    func ownersWithoutAnIdentityOrABankAdvertiseNothing() async throws {
        let budget = Self.budget()
        let unrouted = try SuperMTPInstalledFixture().make()
        let unbanked = try SuperMTPInstalledFixture().make()
        let leases = [try await Self.lease(unrouted, "unrouted", budget: budget, speculates: false),
                      try await Self.lease(unbanked, "unbanked", budget: budget, speculates: false)]
        let local = try await Self.owner(unrouted, environment: Self.environment, budget: budget,
            lease: leases[0], speculates: false, routing: nil)
        let bankless = try await Self.owner(unbanked,
            environment: [NemotronSuperLocalPrefill.chunkKey: String(Self.chunk)], budget: budget,
            lease: leases[1], speculates: false, routing: Self.routing)
        #expect(local.prefixBankBytes > 0 && local.bridge.residentPrefixCacheEvidence == nil)
        #expect(bankless.prefixBankBytes == 0 && bankless.bridge.residentPrefixCacheEvidence == nil)
        // The local bank still restores; its outcome still reaches the signal.
        _ = try await Self.run(local, prompt: Self.donor, scope: "", receipts: Receipts())
        let bank = try #require((await local.bridge.ownedEngine as? EngineV2)?.hybridPrefixCache)
        let published = await Self.eventually { bank.stats.entries == 1 }
        #expect(published)
        let adopter = Receipts()
        _ = try await Self.run(local, prompt: Self.adopter, scope: "", receipts: adopter)
        #expect(adopter.signal.prefixCacheHitTokens == 512)
        try await local.closeAfterDrain()
        try await bankless.closeAfterDrain()
        #expect(await budget.reservationBytesSnapshot().isEmpty)
        for lease in leases { #expect(await budget.finishPendingLoad(lease)) }
    }
}
