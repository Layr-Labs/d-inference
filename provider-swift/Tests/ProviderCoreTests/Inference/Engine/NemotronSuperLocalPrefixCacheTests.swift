// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import Testing
@testable import ProviderCore

private actor SuperPrefixRun {
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

/// Exact text prefix reuse of the plain Super owner: an explicit opt-in, a
/// bank whose whole budget is reserved from before the first request until
/// native retirement, restored text identical to cold text, and no entry
/// shared between owners.
struct NemotronSuperLocalPrefixCacheTests {
    typealias Builder = NemotronSuperLocalBridgeBuilder
    typealias Prefix = NemotronSuperLocalPrefixCache

    static let memoryKey = "DARKBLOOM_PREFIX_CACHE_MEMORY"
    /// Four-token chunks: checkpoints at every fourth token of the tiny fixture.
    static let chunk: Int = 4
    static let environment = [NemotronSuperLocalPrefill.chunkKey: String(chunk), memoryKey: "1"]
    static let grant: Int = 2 << 30

    @Test func bankIsAnExplicitOptInOfThePlainOwnerOnly() throws {
        let grant = Self.grant
        #expect(Prefix.config(environment: [:], kvBytesCapacity: grant, speculates: false) == nil)
        let config = try #require(Prefix.config(
            environment: [Self.memoryKey: "1"], kvBytesCapacity: grant, speculates: false))
        let eighth: Int = grant / 8
        #expect(config.maximumBytes == eighth)
        #expect(config.modelID == NemotronSuperLocalBinding.modelID)
        #expect(config.promptContractID.hasSuffix(NemotronSuperPromptContract.templateSHA256))
        #expect(Prefix.config(environment: [Self.memoryKey: "1"], kvBytesCapacity: grant,
            speculates: true) == nil)
        for disabled in [["DARKBLOOM_CBV2_HYBRID_PREFIX_CACHE": "0"], ["DARKBLOOM_PREFIX_CACHE": "0"]] {
            let environment = disabled.merging([Self.memoryKey: "1"]) { $1 }
            #expect(Prefix.config(environment: environment, kvBytesCapacity: grant, speculates: false) == nil)
        }
        let sized = [Self.memoryKey: "1", "DARKBLOOM_CBV2_HYBRID_PREFIX_BYTES": "67108864"]
        #expect(Prefix.config(environment: sized, kvBytesCapacity: grant, speculates: false)?.maximumBytes
            == 67_108_864)
        let id = Prefix.bankReservationID()
        #expect(Prefix.isBankReservationID(id) && !NemotronSuperLocalPrefill.isLaneReservationID(id))
    }

    private static func budget() -> GlobalKVCacheBudget {
        GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: .max) })
    }

    private static func owner(_ fixture: SuperMTPInstalledFixture.Installation,
                              environment: [String: String], budget: GlobalKVCacheBudget,
                              lease: PendingModelLoadLease) async throws -> Builder.Owner {
        try await Builder.make(installed: fixture.installed,
            tokenizer: TokenizerHandle(SuperTokenTextTokenizer()), eosTokenIDs: [63],
            sizing: .init(weightsBytes: fixture.installed.receipt.payloadBytes,
                fp16KVBytesPerToken: 64, maxContextLength: 64, defaultMaxTokens: 16),
            kvBytesCapacity: grant, kvBudget: budget, loadLease: lease,
            construction: fixture.construction, environment: environment)
    }

    private static func lease(_ fixture: SuperMTPInstalledFixture.Installation, _ name: String,
                              budget: GlobalKVCacheBudget) async throws -> PendingModelLoadLease {
        try #require(await budget.claimPendingLoad(requestID: "super-prefix-\(name)",
            weightBytes: UInt64(fixture.installed.receipt.payloadBytes), minimumKVBytes: UInt64(grant)))
    }

    private static func run(_ owner: Builder.Owner, prompt: [Int]) async throws -> String {
        let events = SuperPrefixRun()
        try await owner.localTextBinding().run(request: .init(model: NemotronSuperLocalBinding.modelID,
            messages: [], temperature: 0, max_tokens: 12), promptTokens: prompt) {
            await events.record($0)
        }
        #expect(await events.errors.isEmpty)
        return await events.text
    }

    private static func bank(_ owner: Builder.Owner) async -> CBv2HybridPrefixCache? {
        (await owner.bridge.ownedEngine as? EngineV2)?.hybridPrefixCache
    }

    /// Polls `condition` for up to five seconds.
    private static func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Twenty tokens (18, the image placeholder, is left out): a grid end.
    static let donor: [Int] = (0 ..< 21).map { (index: Int) -> Int in (index * 7 + 3) % 61 + 1 }
        .filter { (token: Int) -> Bool in token != 18 }
    static let adopter: [Int] = donor + [5, 9, 1, 4, 22, 7, 3, 8, 30]

    /// The donor's checkpoints sit on the 4-token chunk grid; the next turn
    /// restores the deepest one below its last token and streams the same
    /// text as a second owner serving it cold. That owner never sees the
    /// first owner's entries. Each owner holds its lane and its bank from
    /// build to retirement, and nothing stays charged after close.
    @Test(.timeLimit(.minutes(3)))
    func restoredTextEqualsColdTextAndEveryChargeRetires() async throws {
        let budget = Self.budget()
        let warmFixture = try SuperMTPInstalledFixture().make()
        let coldFixture = try SuperMTPInstalledFixture().make()
        let leases = [try await Self.lease(warmFixture, "warm", budget: budget),
                      try await Self.lease(coldFixture, "cold", budget: budget)]
        let warm = try await Self.owner(warmFixture, environment: Self.environment, budget: budget,
            lease: leases[0])
        let cold = try await Self.owner(coldFixture, environment: Self.environment, budget: budget,
            lease: leases[1])
        let eighth: Int = Self.grant / 8
        #expect(warm.prefixBankBytes == eighth && cold.prefixBankBytes == eighth)
        let held = await budget.reservationBytesSnapshot()
        let banks = held.filter { Prefix.isBankReservationID($0.key) }
        #expect(banks.count == 2 && banks.values.allSatisfy { $0 == UInt64(eighth) })
        #expect(held.filter { NemotronSuperLocalPrefill.isLaneReservationID($0.key) }.count == 2)

        let warmBank = try #require(await Self.bank(warm))
        let coldBank = try #require(await Self.bank(cold))
        _ = try await Self.run(warm, prompt: Self.donor)
        let published = await Self.eventually { warmBank.stats.entries == 1 }
        #expect(published)
        let restored = try await Self.run(warm, prompt: Self.adopter)
        let deepest: Int = Self.donor.count / Self.chunk * Self.chunk
        #expect(warmBank.stats.adoptions == 1)
        #expect(warmBank.stats.tokensSaved == deepest)
        let coldText = try await Self.run(cold, prompt: Self.adopter)
        #expect(!coldText.isEmpty)
        #expect(restored == coldText)
        #expect(coldBank.stats.adoptions == 0 && coldBank.stats.lookupMatches == 0)
        #expect(await budget.reservationBytesSnapshot() == held)

        try await warm.closeAfterDrain()
        try await cold.closeAfterDrain()
        #expect(await budget.reservationBytesSnapshot().isEmpty)
        #expect(warmFixture.residency.snapshot.usedBytes == 0)
        for lease in leases { #expect(await budget.finishPendingLoad(lease)) }
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    /// A bank that does not fit the shared budget fails the load after the
    /// engine retired, refunding the lane already reserved.
    @Test(.timeLimit(.minutes(2))) func bankThatDoesNotFitFailsTheLoadAndRefundsTheLane() async throws {
        let fixture = try SuperMTPInstalledFixture().make()
        let budget = Self.budget()
        let lease = try await Self.lease(fixture, "small", budget: budget)
        let language = try #require(fixture.installed.model?.languageModel)
        let lane = NemotronSuperLocalPrefill.laneBytes(language, chunkTokens: Self.chunk,
            measuredBound: false)
        let bank: Int = Self.grant / 8
        // Ballast leaves room for the lane and half the bank: the largest
        // reservation that still fits, found by bisection, minus both.
        var low: UInt64 = 0
        var high: UInt64 = 64 << 30
        while low < high {
            let middle = low + (high - low + 1) / 2
            if await budget.reserveBytes(requestID: "probe", bytes: middle) {
                await budget.release(requestID: "probe")
                low = middle
            } else {
                high = middle - 1
            }
        }
        let free = UInt64(lane + bank / 2)
        #expect(low > free)
        #expect(await budget.reserveBytes(requestID: "ballast", bytes: low - free))
        await #expect(throws: Prefix.Failure.bankRefused) {
            _ = try await Self.owner(fixture, environment: Self.environment, budget: budget, lease: lease)
        }
        #expect(await budget.reservationBytesSnapshot().keys.sorted() == ["ballast"])
        await budget.release(requestID: "ballast")
        fixture.installed.closeAfterRetirement()
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    /// A retained native fault keeps the bank charged with the lane: no
    /// retirement evidence, no refund.
    @Test(.timeLimit(.minutes(2))) func retainedNativeFaultKeepsTheBankCharged() async throws {
        let fixture = try SuperMTPInstalledFixture().make()
        let budget = Self.budget()
        let lease = try await Self.lease(fixture, "fault", budget: budget)
        let owner = try await Self.owner(fixture, environment: Self.environment, budget: budget,
            lease: lease)
        _ = try await Self.run(owner, prompt: Self.donor)
        let held = await budget.reservationBytesSnapshot()
        #expect(held.keys.contains(where: Prefix.isBankReservationID))
        owner.quarantineLocalImage(construction: NativeConstructionScope(),
            activity: owner.imageServiceBudget.beginUnboundedActivity())
        await #expect(throws: Builder.Failure.retirementIncomplete) { try await owner.closeAfterDrain() }
        #expect(await budget.reservationBytesSnapshot() == held)
    }
}
