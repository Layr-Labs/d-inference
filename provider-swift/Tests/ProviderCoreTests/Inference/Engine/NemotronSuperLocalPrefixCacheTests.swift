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
    /// With one byte less free than the claim and the admission slack, that
    /// configuration is refused before anything is installed and the load
    /// serves its fallback without the bank (`NemotronSuperLoadFit`). With
    /// exactly that much free it loads: the installation's share passes to
    /// live usage once resident, and the lane, round and bank shares pass to
    /// their own reservations, so neither the 8.5 GiB lane share nor the
    /// 16 GiB bank is ever counted twice (that would need the bank again, far
    /// more than the 3 GiB admission slack left free). The round share passes to the engine's exact
    /// round reservation.
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
                let slack = UInt64(NemotronSuperLoadFit.admissionSlackBytes)
                let ballast: UInt64 = free - claim - slack + (short ? 1 : 0)
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
                let attempts = await transaction.fitAttempts
                #expect(attempts.first == .init(requests: 1, prefixBankBytes: bank, claimBytes: claim,
                                                admitted: !short))
                if short {
                    #expect(failure == nil)
                    #expect(installs.count == 1, "installed once, after the fallback's claim")
                    #expect(attempts.count == 2 && attempts[1].admitted && attempts[1].prefixBankBytes == 0)
                    #expect(attempts[1].claimBytes < claim)
                    let held = await budget.reservationBytesSnapshot()
                    #expect(held.keys.allSatisfy { !Prefix.isBankReservationID($0) }, "no bank")
                    try await transaction.closeAfterDrain()
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

    /// A managed claim that fits only at a narrower width serves that width:
    /// the load drops the bank, then halves eight requests until the gate
    /// admits a configuration (here two) and builds the bridge for it. With
    /// one byte less free than the narrowest (one request, no bank, 1,024-token
    /// chunks) nothing is installed and the load is refused.
    @Test(.timeLimit(.minutes(5)))
    func managedLoadServesTheWidestConfigurationTheGateAdmits() async throws {
        let grant: Int = 40 << 30
        let context = 1024
        let environment = [Builder.maxConcurrentKey: "8", Self.memoryKey: "1",
                           "DARKBLOOM_CBV2_HYBRID_PREFIX_BYTES": String(4 << 30)]
        let admission = NemotronSuperServingPolicy.admissionKVBytes(requests: 8, speculates: false) + (4 << 30)
        let candidates = try NemotronSuperLoadFit.candidates(environment: environment,
            admissionKVBytes: admission, kvBytesCapacity: grant, speculates: false, contextTokens: context)
        #expect(candidates.map(\.requests) == [8, 8, 4, 2, 1, 1])
        let quote = try NemotronSuperInstallation.loadQuote(
            source: try SuperMTPInstalledFixture().staging().source, backendAllowanceBytes: 1 << 20)
        let claims: [UInt64] = try candidates.map { candidate in
            let shares = try Builder.pinnedOwnerShares(environment: candidate.environment,
                kvBytesCapacity: grant, speculates: false, contextTokens: context)
            // Lane and bank shares plus the KV floor (the admission less the
            // bank); a plain owner has no round.
            let serving = shares.lane + candidate.admissionKVBytes
            let install = try NemotronSuperLoadClaim.bytes(installation: quote, head: nil,
                sequential: NemotronSuperLoadClaim.mayReturnStagingBuffers(), servingBytes: serving)
            return UInt64(install + serving)
        }
        #expect(claims == claims.sorted(by: >) && Set(claims).count == claims.count)
        // The gate must also hold the admission slack beside each claim.
        let slack = UInt64(NemotronSuperLoadFit.admissionSlackBytes)
        for (free, served) in [(claims[3] + slack, 2), (claims[5] + slack - 1, nil)] {
            let base = try SuperMTPInstalledFixture().staging()
            let installs = SuperPrefixInstallCount()
            let staging = NemotronSuperLocalLoad.Staging(source: base.source, install: {
                installs.increment()
                return try base.install($0, $1, $2)
            }, head: base.head, pinned: true)
            let budget = Self.budget()
            let ballast = await Self.freeBytes(budget) - free
            #expect(await budget.reserveBytes(requestID: "ballast", bytes: ballast))
            let tensorBytes = base.source.tensors.values.reduce(0) { $0 + $1.layout.byteCount }
            let sizing = SlotSizingSnapshot(weightsBytes: tensorBytes, fp16KVBytesPerToken: 64,
                maxContextLength: context, defaultMaxTokens: 16)
            let transaction = NemotronSuperLocalLoad(budget: budget)
            var bridge: EngineV2Bridge?
            var failure: Error?
            do {
                bridge = try await transaction.load(staging: { staging },
                    tokenizer: TokenizerHandle(SuperTokenTextTokenizer()), eosTokenIDs: [63], sizing: sizing,
                    kvBytesCapacity: grant, admissionKVBytes: admission, backendAllowanceBytes: 1 << 20,
                    modelID: NemotronSuperLocalBinding.modelID, environment: environment)
            } catch {
                failure = error
            }
            let attempts = await transaction.fitAttempts
            #expect(attempts.map(\.claimBytes) == Array(claims.prefix(attempts.count)))
            #expect(attempts.dropLast().allSatisfy { !$0.admitted })
            #expect(attempts.first?.prefixBankBytes == 4 << 30)
            #expect(attempts.dropFirst().allSatisfy { $0.prefixBankBytes == 0 })
            if let served {
                #expect(failure == nil && installs.count == 1)
                #expect(attempts.last == .init(requests: served, prefixBankBytes: 0, claimBytes: claims[3],
                                               admitted: true))
                #expect(await bridge?.maxConcurrentRequests == served)
                try await transaction.closeAfterDrain()
            } else {
                #expect((failure as? NemotronSuperLocalLoad.Failure) == .capacity)
                #expect(installs.count == 0, "refused before allocation")
                #expect(attempts.count == candidates.count && attempts.allSatisfy { !$0.admitted })
            }
            await budget.release(requestID: "ballast")
            #expect(await budget.outstandingReservedBytes() == 0)
        }
    }

    /// Bytes a scripted budget reports (MLX's buffer cache, live usage) until
    /// the test or a flush changes them.
    final class ScriptedBytes: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: UInt64 = 0
        var bytes: UInt64 {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// A configuration refused only for buffers MLX holds in its cache is not
    /// narrowed: the load returns them once and asks again, and builds the
    /// planned owner (a refusal alone only schedules the reclaimer's flush,
    /// too late for the next configuration, which would serve without the
    /// bank). Nor is it narrowed when that flush returns the buffers before
    /// the load looks at the cache again: here the budget's own reclaimer
    /// may win that race.
    @Test(.timeLimit(.minutes(5)))
    func cachedBuffersAreReturnedBeforeNarrowing() async throws {
        let grant: Int = 40 << 30
        let context = 1024
        let environment = [Builder.maxConcurrentKey: "8", Self.memoryKey: "1",
                           "DARKBLOOM_CBV2_HYBRID_PREFIX_BYTES": String(4 << 30)]
        let admission = NemotronSuperServingPolicy.admissionKVBytes(requests: 8, speculates: false) + (4 << 30)
        let planned = try #require(try NemotronSuperLoadFit.candidates(environment: environment,
            admissionKVBytes: admission, kvBytesCapacity: grant, speculates: false, contextTokens: context).first)
        let base = try SuperMTPInstalledFixture().staging()
        let quote = try NemotronSuperInstallation.loadQuote(source: base.source, backendAllowanceBytes: 1 << 20)
        let shares = try Builder.pinnedOwnerShares(environment: environment, kvBytesCapacity: grant,
            speculates: false, contextTokens: context)
        let fit = try #require(try NemotronSuperLoadFit.claim(planned, kvBytesCapacity: grant, shares: shares) {
            try NemotronSuperLoadClaim.bytes(installation: quote, head: nil,
                sequential: NemotronSuperLoadClaim.mayReturnStagingBuffers(), servingBytes: $0)
        })
        let cache = ScriptedBytes()
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 64 << 30, active: 0, cache: cache.bytes, systemAvailable: .max) },
            clearCache: { cache.bytes = 0 })
        // Exactly the planned configuration fits once the cache is returned.
        let ballast = await Self.freeBytes(budget) - fit.requiredBytes
        #expect(await budget.reserveBytes(requestID: "ballast", bytes: ballast))
        cache.bytes = 512 << 20
        let staging = NemotronSuperLocalLoad.Staging(source: base.source, install: base.install,
                                                     head: base.head, pinned: true)
        let tensorBytes = base.source.tensors.values.reduce(0) { $0 + $1.layout.byteCount }
        let transaction = NemotronSuperLocalLoad(budget: budget)
        let bridge = try await transaction.load(staging: { staging },
            tokenizer: TokenizerHandle(SuperTokenTextTokenizer()), eosTokenIDs: [63],
            sizing: SlotSizingSnapshot(weightsBytes: tensorBytes, fp16KVBytesPerToken: 64,
                                       maxContextLength: context, defaultMaxTokens: 16),
            kvBytesCapacity: grant, admissionKVBytes: admission, backendAllowanceBytes: 1 << 20,
            modelID: NemotronSuperLocalBinding.modelID, environment: environment)
        #expect(cache.bytes == 0)
        let attempts = await transaction.fitAttempts
        #expect(attempts == [.init(requests: 8, prefixBankBytes: 4 << 30, claimBytes: fit.chargedBytes,
                                   admitted: true)])
        #expect(await bridge.maxConcurrentRequests == 8)
        try await transaction.closeAfterDrain()
        await budget.release(requestID: "ballast")
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    /// What a pinned-fixture load did after its room fell while the weights
    /// installed (`loadLosingRoomWhileInstalling`).
    private struct RoomLostLoad {
        let transaction: NemotronSuperLocalLoad
        let budget: GlobalKVCacheBudget
        /// Each configuration's claim, in the order the load tries them.
        let fits: [NemotronSuperLoadFit.Claim]
        let ballast: UInt64
        let installs: Int
        let headLoads: Int
        let bridge: EngineV2Bridge?
        let failure: Error?
    }

    /// A pinned-fixture load on a scripted budget whose room falls while the
    /// weights install, as when other processes take memory: before
    /// installation exactly the first configuration's requirement is free
    /// beside the ballast; once installed, live usage leaves `room(serving)`,
    /// where `serving` is what each configuration holds beside the resident
    /// weights (owner shares and KV floor), in the order the load tries them.
    /// With `roomWhileBuilding` it falls again to `roomWhileBuilding(serving)`
    /// once the budget accepts the first reservation after installation: the
    /// first owner's prefill lane, after its bridge is built.
    private static func loadLosingRoomWhileInstalling(environment: [String: String], admissionKVBytes: Int?,
                                                      speculates: Bool, room: ([UInt64]) -> UInt64,
                                                      roomWhileBuilding: (([UInt64]) -> UInt64)? = nil)
        async throws -> RoomLostLoad {
        let grant: Int = 40 << 30
        let context = 1024
        let candidates = try NemotronSuperLoadFit.candidates(environment: environment,
            admissionKVBytes: admissionKVBytes, kvBytesCapacity: grant, speculates: speculates, contextTokens: context)
        let base = try SuperMTPInstalledFixture().staging()
        let quote = try NemotronSuperInstallation.loadQuote(source: base.source, backendAllowanceBytes: 1 << 20)
        let headQuote = speculates ? try base.head?.quote() : nil
        let sequential = NemotronSuperLoadClaim.mayReturnStagingBuffers()
        let fits: [NemotronSuperLoadFit.Claim] = try candidates.map { candidate in
            let shares = try Builder.pinnedOwnerShares(environment: candidate.environment, kvBytesCapacity: grant,
                speculates: speculates, contextTokens: context)
            return try #require(try NemotronSuperLoadFit.claim(candidate, kvBytesCapacity: grant, shares: shares) {
                try NemotronSuperLoadClaim.bytes(installation: quote, head: headQuote, sequential: sequential,
                                                 servingBytes: $0)
            })
        }
        let serving = fits.map { UInt64($0.ownerBytes + $0.kvFloorBytes) }
        let usageAfterInstallation = fits[0].requiredBytes - room(serving)
        let usageWhileBuilding = roomWhileBuilding.map { fits[0].requiredBytes - $0(serving) }
        let installs = SuperPrefixInstallCount(), headLoads = SuperPrefixInstallCount()
        let fallsWhileBuilding = SuperPrefixInstallCount()
        let usage = ScriptedBytes()
        // The budget stamps each reservation it accepts, and each refusal, with
        // `clockNow`: after installation the first stamp is the first owner's
        // lane when the builder's recheck passed.
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 64 << 30, active: usage.bytes, cache: 0, systemAvailable: .max) },
            clockNow: {
                if let usageWhileBuilding, installs.count == 1, fallsWhileBuilding.count == 0 {
                    fallsWhileBuilding.increment()
                    usage.bytes = usageWhileBuilding
                }
                return .now
            })
        let ballast = await Self.freeBytes(budget) - fits[0].requiredBytes
        #expect(await budget.reserveBytes(requestID: "ballast", bytes: ballast))
        let staging = NemotronSuperLocalLoad.Staging(source: base.source, install: {
            installs.increment()
            let installed = try base.install($0, $1, $2)
            usage.bytes = usageAfterInstallation
            return installed
        }, head: base.head.map { head in
            .init(quote: head.quote, load: {
                headLoads.increment()
                return try head.load($0, $1, $2)
            })
        }, pinned: true)
        let tensorBytes = base.source.tensors.values.reduce(0) { $0 + $1.layout.byteCount }
        let sizing = SlotSizingSnapshot(weightsBytes: tensorBytes, fp16KVBytesPerToken: 64,
            maxContextLength: context, defaultMaxTokens: 16)
        let transaction = NemotronSuperLocalLoad(budget: budget)
        var bridge: EngineV2Bridge?
        var failure: Error?
        do {
            bridge = try await transaction.load(staging: { staging },
                tokenizer: TokenizerHandle(SuperTokenTextTokenizer()), eosTokenIDs: [63], sizing: sizing,
                kvBytesCapacity: grant, admissionKVBytes: admissionKVBytes, backendAllowanceBytes: 1 << 20,
                modelID: NemotronSuperLocalBinding.modelID, environment: environment)
        } catch {
            failure = error
        }
        return RoomLostLoad(transaction: transaction, budget: budget, fits: fits, ballast: ballast,
                            installs: installs.count, headLoads: headLoads.count, bridge: bridge, failure: failure)
    }

    /// The gate can admit a configuration whose room is gone once its
    /// weights are installed (other processes grew meanwhile), so the
    /// builder's recheck refuses it. The load keeps the installation and any
    /// head and serves the next narrower configuration the gate admits
    /// beside them, asked for its owner shares, KV floor and slack only:
    /// with room for four requests, eight without the bank are refused too.
    @Test(.timeLimit(.minutes(5)), arguments: [false, true])
    func ownerLostAfterInstallationNarrowsWithoutReinstalling(speculates: Bool) async throws {
        let slack = UInt64(NemotronSuperLoadFit.admissionSlackBytes)
        let speculation = speculates
            ? [NemotronSuperLocalMTP.enabledKey: "1", NemotronSuperLocalMTP.depthKey: "3,2,2,2,1"] : [:]
        let environment = speculation.merging([Builder.maxConcurrentKey: "8", Self.memoryKey: "1",
            "DARKBLOOM_CBV2_HYBRID_PREFIX_BYTES": String(4 << 30)]) { $1 }
        let admission = NemotronSuperServingPolicy.admissionKVBytes(requests: 8, speculates: speculates,
            environment: environment, contextTokens: 1024, kvBytesCapacity: 40 << 30, bankBytes: 4 << 30)
        let load = try await Self.loadLosingRoomWhileInstalling(environment: environment,
            admissionKVBytes: admission, speculates: speculates) { $0[2] + slack }
        #expect(load.failure == nil, "\(load.failure.map { "\($0)" } ?? "")")
        #expect(load.installs == 1 && load.headLoads == (speculates ? 1 : 0), "installed once")
        #expect(await load.transaction.fitAttempts == [
            .init(requests: 8, prefixBankBytes: 4 << 30, claimBytes: load.fits[0].chargedBytes, admitted: true,
                  lostAfterInstallation: true),
            .init(requests: 8, prefixBankBytes: 0, claimBytes: load.fits[1].chargedBytes, admitted: false),
            .init(requests: 4, prefixBankBytes: 0, claimBytes: load.fits[2].chargedBytes, admitted: true),
        ])
        #expect(await load.bridge?.maxConcurrentRequests == 4)
        // No claim is left: only the served owner's reservations (no bank) and the ballast.
        let held = await load.budget.reservationBytesSnapshot()
        #expect(held.keys.allSatisfy { !Prefix.isBankReservationID($0) })
        #expect(await load.budget.outstandingReservedBytes() == held.values.reduce(0, +))
        try await load.transaction.closeAfterDrain()
        await load.budget.release(requestID: "ballast")
        #expect(await load.budget.outstandingReservedBytes() == 0)
    }

    /// A refusal after the first owner's bridge is built: the room passes the
    /// builder's recheck exactly, then falls once the lane is reserved, below
    /// what paged storage's decode rows need. (The fixture's lane is far below
    /// the claim's 8.5 GiB lane share, so a room that passes the recheck also
    /// holds the rows.) The builder retires that bridge and releases its lane;
    /// the load builds eight requests without the bank in a second native
    /// setup over the same installation and any head. A 16 GiB bank, more than
    /// the lane share and the slack, leaves room for that configuration where
    /// the first owner's rows had none.
    @Test(.timeLimit(.minutes(5)), arguments: [false, true])
    func ownerRefusedAfterItsBridgeIsBuiltIsRebuiltNarrower(speculates: Bool) async throws {
        let slack = UInt64(NemotronSuperLoadFit.admissionSlackBytes)
        let bank: Int = 16 << 30
        let speculation = speculates
            ? [NemotronSuperLocalMTP.enabledKey: "1", NemotronSuperLocalMTP.depthKey: "3,2,2,2,1"] : [:]
        let environment = speculation.merging([Builder.maxConcurrentKey: "8", Self.memoryKey: "1",
            "DARKBLOOM_CBV2_HYBRID_PREFIX_BYTES": String(bank), NemotronSuperLocalKVBackend.key: "paged"]) { $1 }
        let admission = NemotronSuperServingPolicy.admissionKVBytes(requests: 8, speculates: speculates,
            environment: environment, contextTokens: 1024, kvBytesCapacity: 40 << 30, bankBytes: bank)
        // 64-wide attention heads, the paged kernels' minimum.
        let load = try await SuperMTPInstalledFixture.$attentionHeadDim.withValue(64) {
            try await Self.loadLosingRoomWhileInstalling(environment: environment, admissionKVBytes: admission,
                speculates: speculates, room: { $0[0] }, roomWhileBuilding: { $0[1] + slack })
        }
        #expect(load.failure == nil, "\(load.failure.map { "\($0)" } ?? "")")
        #expect(load.installs == 1 && load.headLoads == (speculates ? 1 : 0), "installed once")
        #expect(await load.transaction.fitAttempts == [
            .init(requests: 8, prefixBankBytes: bank, claimBytes: load.fits[0].chargedBytes, admitted: true,
                  lostAfterInstallation: true),
            .init(requests: 8, prefixBankBytes: 0, claimBytes: load.fits[1].chargedBytes, admitted: true),
        ])
        #expect(await load.bridge?.maxConcurrentRequests == 8)
        #expect(await load.bridge?.kvBackendKind == .paged)
        // The refused owner's lane is released and no claim is left: only the
        // served owner's reservations (one lane, one set of rows, no bank) and the ballast.
        let held = await load.budget.reservationBytesSnapshot()
        #expect(held.keys.filter(NemotronSuperLocalPrefill.isLaneReservationID).count == 1)
        #expect(held.keys.filter(NemotronSuperLocalKVBackend.isDecodeRowsReservationID).count == 1)
        #expect(held.keys.allSatisfy { !Prefix.isBankReservationID($0) })
        #expect(await load.budget.outstandingReservedBytes() == held.values.reduce(0, +))
        try await load.transaction.closeAfterDrain()
        await load.budget.release(requestID: "ballast")
        #expect(await load.budget.outstandingReservedBytes() == 0)
    }

    /// When nothing narrower fits beside the installed weights, the builder's
    /// refusal surfaces and nothing stays held. A managed load asks every
    /// narrower configuration (the narrowest with one byte less free than its
    /// owner shares, KV floor and slack: the slack is still required); a
    /// whole-grant claim has only its own.
    @Test(.timeLimit(.minutes(5)), arguments: [true, false])
    func ownerLostAfterInstallationFailsWhenNothingNarrowerFits(managed: Bool) async throws {
        let slack = UInt64(NemotronSuperLoadFit.admissionSlackBytes)
        let environment = [Builder.maxConcurrentKey: "8", Self.memoryKey: "1",
                           "DARKBLOOM_CBV2_HYBRID_PREFIX_BYTES": String(4 << 30)]
        let admission = NemotronSuperServingPolicy.admissionKVBytes(requests: 8, speculates: false) + (4 << 30)
        let load = try await Self.loadLosingRoomWhileInstalling(environment: environment,
            admissionKVBytes: managed ? admission : nil, speculates: false) { serving in
            managed ? serving[serving.count - 1] + slack - 1 : serving[0] - 1
        }
        #expect((load.failure as? Builder.Failure) == .loadAdmissionLost, "\(load.failure.map { "\($0)" } ?? "")")
        #expect(load.installs == 1)
        let attempts = await load.transaction.fitAttempts
        #expect(attempts.count == (managed ? 6 : 1) && attempts.count == load.fits.count)
        #expect(attempts.map(\.claimBytes) == load.fits.map(\.chargedBytes))
        #expect(attempts.first?.admitted == true && attempts.first?.lostAfterInstallation == true)
        #expect(attempts.dropFirst().allSatisfy { !$0.admitted })
        #expect(await load.transaction.phase == .closed)
        #expect(await load.transaction.residencySnapshot?.usedBytes == 0, "the installation is released")
        #expect(await load.budget.reservationBytesSnapshot().keys.sorted() == ["ballast"])
        #expect(await load.budget.outstandingReservedBytes() == load.ballast, "no claim is left")
        await load.budget.release(requestID: "ballast")
        #expect(await load.budget.outstandingReservedBytes() == 0)
    }

    /// A co-resident slot's small grant holds every request's fixed bytes and
    /// the minimum KV, not the round work, which the claim holds whole beside
    /// it as the round share: eight speculating requests load on a 3 GiB
    /// grant, below their 3.19 GiB round, at the configured width (with the
    /// round clamped into the grant, only one request kept a KV floor).
    @Test(.timeLimit(.minutes(5)))
    func smallCoResidentGrantServesTheConfiguredWidth() async throws {
        let grant: Int = 3 << 30
        let context = 1024
        let environment = [Builder.maxConcurrentKey: "8", NemotronSuperLocalMTP.enabledKey: "1",
                           NemotronSuperLocalMTP.depthKey: "3,2,2,2,1"]
        let admission = NemotronSuperServingPolicy.admissionKVBytes(requests: 8, speculates: true,
            environment: environment, contextTokens: context, kvBytesCapacity: grant)
        let shares = try Builder.pinnedOwnerShares(environment: environment, kvBytesCapacity: grant,
            speculates: true, contextTokens: context)
        #expect(shares.round > grant, "the round alone exceeds the grant")
        #expect(admission == grant + shares.round)
        let base = try SuperMTPInstalledFixture().staging()
        let staging = NemotronSuperLocalLoad.Staging(source: base.source, install: base.install,
                                                     head: base.head, pinned: true)
        let quote = try NemotronSuperInstallation.loadQuote(source: base.source, backendAllowanceBytes: 1 << 20)
        let headQuote = try #require(try base.head?.quote())
        let serving = try #require(shares.total) + grant
        let install = try NemotronSuperLoadClaim.bytes(installation: quote, head: headQuote,
            sequential: NemotronSuperLoadClaim.mayReturnStagingBuffers(), servingBytes: serving)
        let budget = Self.budget()
        let tensorBytes = base.source.tensors.values.reduce(0) { $0 + $1.layout.byteCount }
        let sizing = SlotSizingSnapshot(weightsBytes: tensorBytes, fp16KVBytesPerToken: 64,
            maxContextLength: context, defaultMaxTokens: 16)
        let transaction = NemotronSuperLocalLoad(budget: budget)
        let bridge = try await transaction.load(staging: { staging },
            tokenizer: TokenizerHandle(SuperTokenTextTokenizer()), eosTokenIDs: [63], sizing: sizing,
            kvBytesCapacity: grant, admissionKVBytes: admission, backendAllowanceBytes: 1 << 20,
            modelID: NemotronSuperLocalBinding.modelID, environment: environment)
        // One attempt: the configured eight, the grant as KV floor beside the shares.
        #expect(await transaction.fitAttempts == [.init(requests: 8, prefixBankBytes: 0,
            claimBytes: UInt64(install + serving), admitted: true)])
        #expect(await bridge.maxConcurrentRequests == 8)
        try await transaction.closeAfterDrain()
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
