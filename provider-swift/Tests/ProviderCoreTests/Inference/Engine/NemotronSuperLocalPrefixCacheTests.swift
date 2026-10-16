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

/// Exact prefix reuse of the plain and the speculating Super owner: an
/// explicit opt-in, a bank whose whole budget is reserved from before the
/// first request until native retirement, restored text and image turns
/// identical to cold ones, and no entry shared between owners.
/// Counts installations a staging performed.
final class SuperPrefixInstallCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

struct NemotronSuperLocalPrefixCacheTests {
    typealias Builder = NemotronSuperLocalBridgeBuilder
    typealias Prefix = NemotronSuperLocalPrefixCache

    static let memoryKey = "DARKBLOOM_PREFIX_CACHE_MEMORY"
    /// Four-token chunks: checkpoints at every fourth token of the tiny fixture.
    static let chunk: Int = 4
    static let environment = [NemotronSuperLocalPrefill.chunkKey: String(chunk), memoryKey: "1"]
    static let grant: Int = 2 << 30

    /// The synthetic fixtures are not the pinned checkpoint: their bank keeps
    /// `PrefixCachePolicy.hybridConfig`'s generic default size.
    private static func config(_ environment: [String: String]) -> CBv2HybridPrefixCacheConfig? {
        Prefix.config(environment: environment, kvBytesCapacity: grant, requests: 1, speculates: false,
            pinned: false)
    }

    @Test func bankIsAnExplicitOptIn() throws {
        let grant = Self.grant
        #expect(Self.config([:]) == nil)
        let config = try #require(Self.config([Self.memoryKey: "1"]))
        let eighth: Int = grant / 8
        #expect(config.maximumBytes == eighth)
        #expect(config.modelID == NemotronSuperLocalBinding.modelID)
        #expect(config.promptContractID.hasSuffix(NemotronSuperPromptContract.templateSHA256))
        for disabled in [["DARKBLOOM_CBV2_HYBRID_PREFIX_CACHE": "0"], ["DARKBLOOM_PREFIX_CACHE": "0"]] {
            let environment = disabled.merging([Self.memoryKey: "1"]) { $1 }
            #expect(Self.config(environment) == nil)
        }
        let sized = [Self.memoryKey: "1", "DARKBLOOM_CBV2_HYBRID_PREFIX_BYTES": "67108864"]
        #expect(Self.config(sized)?.maximumBytes == 67_108_864)
        let id = Prefix.bankReservationID()
        #expect(Prefix.isBankReservationID(id) && !NemotronSuperLocalPrefill.isLaneReservationID(id))
    }

    private static func budget() -> GlobalKVCacheBudget {
        GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: .max) })
    }

    /// `speculates` installs depth-3 exact rectangular speculation with the
    /// fixture's embedded head.
    private static func owner(_ fixture: SuperMTPInstalledFixture.Installation,
                              environment: [String: String], budget: GlobalKVCacheBudget,
                              lease: PendingModelLoadLease, speculates: Bool = false)
        async throws -> Builder.Owner {
        try await Builder.make(installed: fixture.installed,
            tokenizer: TokenizerHandle(SuperTokenTextTokenizer()), eosTokenIDs: [63],
            sizing: .init(weightsBytes: fixture.installed.receipt.payloadBytes,
                fp16KVBytesPerToken: 64, maxContextLength: 64, defaultMaxTokens: 16),
            kvBytesCapacity: grant, kvBudget: budget, loadLease: lease,
            construction: fixture.construction,
            mtp: speculates ? .init(module: fixture.head, setting: .init(depth: 3)) : nil,
            environment: environment)
    }

    private static func lease(_ fixture: SuperMTPInstalledFixture.Installation, _ name: String,
                              budget: GlobalKVCacheBudget, speculates: Bool = false)
        async throws -> PendingModelLoadLease {
        let head = speculates ? try NemotronSuperLocalMTP.loadSupplementBytes(fixture.headQuote) : 0
        return try #require(await budget.claimPendingLoad(requestID: "super-prefix-\(name)",
            weightBytes: UInt64(fixture.installed.receipt.payloadBytes + head),
            minimumKVBytes: UInt64(grant)))
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
    /// text as a second owner serving it cold, on the plain and on the
    /// speculating owner. That owner never sees the first owner's entries.
    /// Each owner holds its lane and its bank from build to retirement, and
    /// nothing stays charged after close.
    @Test(.timeLimit(.minutes(3)), arguments: [false, true])
    func restoredTextEqualsColdTextAndEveryChargeRetires(speculates: Bool) async throws {
        let budget = Self.budget()
        let warmFixture = try SuperMTPInstalledFixture().make()
        let coldFixture = try SuperMTPInstalledFixture().make()
        let leases = [try await Self.lease(warmFixture, "warm", budget: budget, speculates: speculates),
                      try await Self.lease(coldFixture, "cold", budget: budget, speculates: speculates)]
        let warm = try await Self.owner(warmFixture, environment: Self.environment, budget: budget,
            lease: leases[0], speculates: speculates)
        let cold = try await Self.owner(coldFixture, environment: Self.environment, budget: budget,
            lease: leases[1], speculates: speculates)
        #expect(warm.speculates == speculates && cold.speculates == speculates)
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

    private static func runImage(_ owner: Builder.Owner, prompt: [Int], cacheScope: String?)
        async throws -> String {
        let events = SuperPrefixRun()
        let pixels = MLXArray((0 ..< 16).map { (index: Int) -> Float in Float(index) / 16 })
            .reshaped([1, 1, 4, 4])
        try await owner.localImageBinding().run(request: .init(model: NemotronSuperLocalBinding.modelID,
            messages: [], temperature: 0, max_tokens: 12),
            input: .init(promptTokens: prompt, normalizedImages: [pixels]),
            cacheScope: cacheScope) { await events.record($0) }
        #expect(await events.errors.isEmpty)
        return await events.text
    }

    /// An image turn binds an identity of its evaluated features: the next
    /// turn with the same image restores the deepest chunk boundary and
    /// streams the cold text, on the plain and on the speculating owner
    /// (target-only there). Without a cache scope an image request neither
    /// restores nor publishes.
    @Test(.timeLimit(.minutes(3)), arguments: [false, true])
    func sameImageTurnRestoresTheColdText(speculates: Bool) async throws {
        let budget = Self.budget()
        let warmFixture = try SuperMTPInstalledFixture().make()
        let coldFixture = try SuperMTPInstalledFixture().make()
        let leases = [try await Self.lease(warmFixture, "image-warm", budget: budget, speculates: speculates),
                      try await Self.lease(coldFixture, "image-cold", budget: budget, speculates: speculates)]
        let warm = try await Self.owner(warmFixture, environment: Self.environment, budget: budget,
            lease: leases[0], speculates: speculates)
        let cold = try await Self.owner(coldFixture, environment: Self.environment, budget: budget,
            lease: leases[1], speculates: speculates)
        // The image placeholder 18 takes one feature (a 4 x 4 one-channel
        // raster); twenty tokens end on the chunk grid.
        let turn: [Int] = [1, 18] + Array(Self.donor.prefix(18))
        let nextTurn: [Int] = turn + [5, 9, 1, 4, 22, 7, 3, 8, 30]
        let warmBank = try #require(await Self.bank(warm))
        _ = try await Self.runImage(warm, prompt: turn, cacheScope: nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(warmBank.stats.entries == 0)
        _ = try await Self.runImage(warm, prompt: turn, cacheScope: "")
        let published = await Self.eventually { warmBank.stats.entries == 1 }
        #expect(published)
        let restored = try await Self.runImage(warm, prompt: nextTurn, cacheScope: "")
        let deepest: Int = turn.count / Self.chunk * Self.chunk
        #expect(warmBank.stats.adoptions == 1)
        #expect(warmBank.stats.tokensSaved == deepest)
        let coldText = try await Self.runImage(cold, prompt: nextTurn, cacheScope: "")
        #expect(!coldText.isEmpty)
        #expect(restored == coldText)
        try await warm.closeAfterDrain()
        try await cold.closeAfterDrain()
        #expect(await budget.reservationBytesSnapshot().isEmpty)
        for lease in leases { #expect(await budget.finishPendingLoad(lease)) }
    }

    /// The bank is part of the slot's floor. An owner with a bank needs
    /// exactly the bank's budget more grant than the same owner without one,
    /// both as its re-slice floor (`minimumServiceableGrantBytes`) and as the
    /// minimum grant for its requests (`superMinimumGrantBytes`): a re-slice
    /// never shrinks the grant below a bank whose whole budget stays reserved
    /// in the shared ledger until native retirement.
    @Test(.timeLimit(.minutes(3)), arguments: [false, true])
    func theBankIsPartOfTheSlotFloor(speculates: Bool) async throws {
        let budget = Self.budget()
        let bankedFixture = try SuperMTPInstalledFixture().make()
        let plainFixture = try SuperMTPInstalledFixture().make()
        let leases = [try await Self.lease(bankedFixture, "floor-bank", budget: budget, speculates: speculates),
                      try await Self.lease(plainFixture, "floor-plain", budget: budget, speculates: speculates)]
        let banked = try await Self.owner(bankedFixture, environment: Self.environment, budget: budget,
            lease: leases[0], speculates: speculates)
        let plain = try await Self.owner(plainFixture,
            environment: [NemotronSuperLocalPrefill.chunkKey: String(Self.chunk)], budget: budget,
            lease: leases[1], speculates: speculates)
        let bank: Int = Self.grant / 8
        #expect(banked.prefixBankBytes == bank && plain.prefixBankBytes == 0)
        let bankedFloor = await banked.bridge.minimumServiceableGrantBytes()
        let plainFloor = await plain.bridge.minimumServiceableGrantBytes()
        #expect(plainFloor > 0 && plainFloor < Int.max)
        let floorDifference: Int = bankedFloor - plainFloor
        #expect(floorDifference == bank)
        let requests = banked.maximumLocalRequests
        let bankedMinimum = await banked.bridge.superMinimumGrantBytes(requests: requests)
        let plainMinimum = await plain.bridge.superMinimumGrantBytes(requests: requests)
        #expect(plainMinimum > 0 && plainMinimum < Int.max)
        let minimumDifference: Int = bankedMinimum - plainMinimum
        #expect(minimumDifference == bank)
        try await banked.closeAfterDrain()
        try await plain.closeAfterDrain()
        #expect(await budget.reservationBytesSnapshot().isEmpty)
        for lease in leases { #expect(await budget.finishPendingLoad(lease)) }
    }

    /// Free bytes of `budget`: the largest reservation it admits, by bisection.
    private static func freeBytes(_ budget: GlobalKVCacheBudget) async -> UInt64 {
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
        return low
    }

    /// One LOAD claim, taken before any allocation, holds the whole pinned
    /// owner: the installation and any head (their transients only beyond
    /// the serving room), the lane share (the measured whole-chunk bound), a
    /// speculating owner's round share, the bank and the requests' KV floor.
    /// With one byte less free the load is refused before anything is
    /// installed. With exactly that much free it loads: the installation's
    /// share passes to live usage once resident, and the lane, round and bank
    /// shares pass to their own reservations, so neither the 8.5 GiB lane
    /// share nor the 16 GiB bank is ever counted twice (counting the bank
    /// twice would need 4 GiB more than is free). The round share passes to
    /// the engine's exact round reservation.
    @Test(.timeLimit(.minutes(5)))
    func oneLoadClaimHoldsThePinnedOwnerOnce() async throws {
        for speculates in [false, true] {
            let bank: Int = 16 << 30
            let kvFloor: Int = 2 << 30
            let grant: Int = 40 << 30
            let speculation = speculates
                ? [NemotronSuperLocalMTP.enabledKey: "1", NemotronSuperLocalMTP.depthKey: "3"] : [:]
            let environment = speculation.merging(
                [Self.memoryKey: "1", "DARKBLOOM_CBV2_HYBRID_PREFIX_BYTES": String(bank)]) { $1 }
            let context = 1024
            let shares = try Builder.pinnedOwnerShares(environment: environment, kvBytesCapacity: grant,
                speculates: speculates, contextTokens: context)
            let round = speculates
                ? NemotronSuperServingPolicy.speculativeOwnerBoundBytes(requests: 1, environment: environment,
                    contextTokens: context)
                : 0
            let lane = NemotronSuperLocalPrefill.pinnedLaneBytes(
                chunkTokens: NemotronSuperLocalPrefill.defaultChunkTokens)
            #expect(lane == 17 << 29)
            #expect(shares == .init(lane: lane, round: round, bank: bank))
            #expect(!speculates || round > 1 << 30, "the pinned round units, not the fixture's")
            // The head's LOAD quote, from a separate staging of the same fixture.
            let headQuote = speculates ? try SuperMTPInstalledFixture().staging().head?.quote() : nil
            #expect(!speculates || headQuote != nil)
            for short in [true, false] {
                let fixture = SuperMTPInstalledFixture()
                let base = try fixture.staging()
                let installs = SuperPrefixInstallCount()
                let staging = NemotronSuperLocalLoad.Staging(source: base.source, install: {
                    installs.increment()
                    return try base.install($0, $1, $2)
                }, head: base.head, pinned: true)
                // The installation's staging and the head's construction run
                // in the serving room the claim also holds (lane, round, bank,
                // KV floor), so they add only what exceeds it.
                let quote = try NemotronSuperInstallation.loadQuote(source: base.source,
                    backendAllowanceBytes: 1 << 20)
                let serving = shares.lane + shares.round + shares.bank + kvFloor
                let sequential = NemotronSuperLoadClaim.mayReturnStagingBuffers()
                let install = try NemotronSuperLoadClaim.bytes(installation: quote, head: headQuote,
                    sequential: sequential, servingBytes: serving)
                let transient = max(quote.stagingBytes, headQuote?.constructionBytes ?? 0)
                #expect(!sequential || install
                    == quote.payloadBytes + (headQuote?.payloadBytes ?? 0) + max(0, transient - serving))
                let claim = UInt64(install + serving)
                let budget = Self.budget()
                let free = await Self.freeBytes(budget)
                #expect(free > claim)
                let ballast: UInt64 = free - claim + (short ? 1 : 0)
                #expect(await budget.reserveBytes(requestID: "ballast", bytes: ballast))
                let tensorBytes = base.source.tensors.values.reduce(0) { $0 + $1.layout.byteCount }
                let sizing = SlotSizingSnapshot(weightsBytes: tensorBytes, fp16KVBytesPerToken: 64,
                    maxContextLength: context, defaultMaxTokens: 16)
                let transaction = NemotronSuperLocalLoad(budget: budget)
                var failure: Error?
                do {
                    _ = try await transaction.load(staging: { staging },
                        tokenizer: TokenizerHandle(SuperTokenTextTokenizer()), eosTokenIDs: [63], sizing: sizing,
                        kvBytesCapacity: grant, admissionKVBytes: kvFloor + bank + round,
                        backendAllowanceBytes: 1 << 20,
                        modelID: NemotronSuperLocalBinding.modelID, environment: environment)
                } catch {
                    failure = error
                }
                if short {
                    #expect((failure as? NemotronSuperLocalLoad.Failure) == .capacity)
                    #expect(installs.count == 0, "refused before allocation")
                } else {
                    #expect(failure == nil)
                    #expect(installs.count == 1)
                    let held = await budget.reservationBytesSnapshot()
                    let laneHeld = held.filter { NemotronSuperLocalPrefill.isLaneReservationID($0.key) }
                    let bankHeld = held.filter { Prefix.isBankReservationID($0.key) }
                    #expect(laneHeld.count == 1 && bankHeld.values.first == UInt64(bank))
                    // The fixture engine's exact round, far below the pinned share.
                    let roundHeld = held.filter { NemotronSuperLocalMTP.isRoundReservationID($0.key) }
                    #expect(roundHeld.count == (speculates ? 1 : 0))
                    #expect(roundHeld.values.allSatisfy { $0 > 0 && $0 < UInt64(round) })
                    // The claim is gone; only the owner's own reservations and the ballast stay.
                    let owner: UInt64 = (laneHeld.values.first ?? 0) + UInt64(bank)
                        + roundHeld.values.reduce(0, +)
                    #expect(await budget.outstandingReservedBytes() == ballast + owner)
                    try await transaction.closeAfterDrain()
                }
                await budget.release(requestID: "ballast")
                #expect(await budget.outstandingReservedBytes() == 0)
            }
        }
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
