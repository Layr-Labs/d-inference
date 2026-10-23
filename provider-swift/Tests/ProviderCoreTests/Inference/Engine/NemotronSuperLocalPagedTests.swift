// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
@testable import MLXLLM
import MLXLMCommon
import MLXVLM
import Testing
@testable import ProviderCore

private actor SuperPagedRun {
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

/// The Super owner's only KV storage, segmented native paged KV: unset or
/// `paged` selects it, contiguous storage and a disabled paged backend fail
/// the load instead of serving other storage, the engine's process-memory
/// owner charges pages and recurrent rows, the owner's decode-row workspace
/// is held like the prefill lane, text and images are served and every
/// charge retires.
struct NemotronSuperLocalPagedTests {
    typealias Builder = NemotronSuperLocalBridgeBuilder
    typealias Paged = NemotronSuperLocalKVBackend
    static let grant: Int = 2 << 30

    @Test func pagedStorageIsTheOnlyStorage() throws {
        #expect(try Paged.resolve(environment: [:]) == .paged)
        #expect(try Paged.resolve(environment: [Paged.key: " paged "]) == .paged)
        for value in ["contiguous", " contiguous "] {
            #expect(throws: Paged.Failure.contiguousUnsupported) {
                try Paged.resolve(environment: [Paged.key: value])
            }
        }
        for value in ["auto", "PAGED", "Contiguous", "1", ""] {
            #expect(throws: Paged.Failure.invalidBackend) {
                try Paged.resolve(environment: [Paged.key: value])
            }
        }
        // The fleet kill switch would degrade paged to contiguous storage.
        let killSwitch = EngineV2KVBackendPolicy.killSwitchEnvKey
        for environment in [[killSwitch: "0"], [killSwitch: "off", Paged.key: "paged"]] {
            #expect(throws: Paged.Failure.pagedDisabled) { try Paged.resolve(environment: environment) }
        }
        #expect(try Paged.resolve(environment: [killSwitch: "1"]) == .paged)
        #expect(try Paged.decodeRowsBytes(requests: 4, rowBytes: 100) == 400)
        #expect(try Paged.decodeRowsBytes(requests: 4, rowBytes: 0) == 0)
        #expect(throws: Paged.Failure.decodeRowsRefused) {
            try Paged.decodeRowsBytes(requests: 2, rowBytes: Int.max)
        }
        let id = Paged.decodeRowsReservationID()
        #expect(Paged.isDecodeRowsReservationID(id))
        #expect(!NemotronSuperLocalPrefill.isLaneReservationID(id))
        #expect(!NemotronSuperLocalPrefixCache.isBankReservationID(id))
        #expect(!Paged.isDecodeRowsReservationID(NemotronSuperLocalPrefill.laneReservationID()))
    }

    private static func budget() -> GlobalKVCacheBudget {
        GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: .max) })
    }

    private static func fixture() throws -> SuperMTPInstalledFixture.Installation {
        try SuperMTPInstalledFixture().make()
    }

    private static func lease(_ fixture: SuperMTPInstalledFixture.Installation, name: String,
                              budget: GlobalKVCacheBudget, speculates: Bool = false)
        async throws -> PendingModelLoadLease {
        let extra = speculates ? try NemotronSuperLocalMTP.loadSupplementBytes(fixture.headQuote) : 0
        return try #require(await budget.claimPendingLoad(requestID: "super-paged-\(name)",
            weightBytes: UInt64(fixture.installed.receipt.payloadBytes + extra),
            minimumKVBytes: UInt64(grant)))
    }

    private static func owner(_ fixture: SuperMTPInstalledFixture.Installation,
                              environment: [String: String], budget: GlobalKVCacheBudget,
                              name: String, speculation: NemotronSuperLocalMTP.Setting? = nil)
        async throws -> (Builder.Owner, PendingModelLoadLease) {
        let lease = try await lease(fixture, name: name, budget: budget,
            speculates: speculation != nil)
        return (try await make(fixture, environment: environment, budget: budget, lease: lease,
            speculation: speculation), lease)
    }

    private static func make(_ fixture: SuperMTPInstalledFixture.Installation,
                             environment: [String: String], budget: GlobalKVCacheBudget,
                             lease: PendingModelLoadLease,
                             speculation: NemotronSuperLocalMTP.Setting? = nil)
        async throws -> Builder.Owner {
        try await Builder.make(installed: fixture.installed,
            tokenizer: TokenizerHandle(SuperTokenTextTokenizer()), eosTokenIDs: [63],
            sizing: .init(weightsBytes: fixture.installed.receipt.payloadBytes,
                fp16KVBytesPerToken: 64, maxContextLength: 64, defaultMaxTokens: 16),
            kvBytesCapacity: grant, kvBudget: budget, loadLease: lease,
            construction: fixture.construction,
            mtp: speculation.map { .init(module: fixture.head, setting: $0) },
            environment: environment)
    }

    private static func run(_ owner: Builder.Owner, prompt: [Int]) async throws -> String {
        let events = SuperPagedRun()
        try await owner.localTextBinding().run(request: .init(model: NemotronSuperLocalBinding.modelID,
            messages: [], temperature: 0, max_tokens: 12), promptTokens: prompt) {
            await events.record($0)
        }
        #expect(await events.errors.isEmpty)
        return await events.text
    }

    private static func runImage(_ owner: Builder.Owner) async throws -> String {
        let events = SuperPagedRun()
        try await owner.localImageBinding().run(request: .init(model: NemotronSuperLocalBinding.modelID,
            messages: [], temperature: 0, max_tokens: 12),
            input: .init(promptTokens: [1, 18, 2],
                normalizedImages: [MLXRandom.normal([1, 1, 4, 4], key: MLXRandom.key(11))])) {
            await events.record($0)
        }
        #expect(await events.errors.isEmpty)
        return await events.text
    }

    static let prompts: [[Int]] = [[5, 9, 1, 4, 22, 7, 3, 8, 30], [1, 2, 3], [40, 41, 42, 43, 44, 2]]

    /// Two concurrent requests stream the same text as each served alone;
    /// the owner holds its lane and its two decode rows from build to
    /// retirement, a request adds no bridge reservation of its own, and
    /// nothing stays charged after close.
    @Test(.timeLimit(.minutes(3))) func pagedOwnerServesTextAndImagesThenRetires() async throws {
        let budget = Self.budget()
        let fixture = try Self.fixture()
        let (owner, lease) = try await Self.owner(fixture,
            environment: [Builder.maxConcurrentKey: "2", NemotronSuperLocalPrefill.chunkKey: "4"],
            budget: budget, name: "paged")
        #expect(await owner.bridge.kvBackendKind == .paged)
        let engine = try #require(await owner.bridge.ownedEngine as? EngineV2)
        #expect(engine.usesProcessMemoryOwner)
        let row = try Builder.requestWorkspaceBytes(try #require(fixture.installed.model).languageModel)
        #expect(row > 0 && owner.decodeRowsBytes == 2 * row)
        let held = await budget.reservationBytesSnapshot()
        #expect(held.filter { Paged.isDecodeRowsReservationID($0.key) }.values.map { Int($0) } == [2 * row])
        #expect(held.filter { NemotronSuperLocalPrefill.isLaneReservationID($0.key) }.count == 1)

        var alone: [String] = []
        for prompt in Self.prompts { alone.append(try await Self.run(owner, prompt: prompt)) }
        #expect(alone.allSatisfy { !$0.isEmpty })
        async let first = Self.run(owner, prompt: Self.prompts[0])
        async let second = Self.run(owner, prompt: Self.prompts[2])
        let together = try await [first, second]
        #expect(together == [alone[0], alone[2]])
        #expect(!(try await Self.runImage(owner)).isEmpty)
        #expect(await budget.reservationBytesSnapshot() == held)

        try await owner.closeAfterDrain()
        #expect(fixture.residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.reservationBytesSnapshot().isEmpty)
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    /// A builder asked for contiguous storage, or whose paged storage the
    /// fleet kill switch disables, fails before native setup and holds
    /// nothing; the same installation then builds a paged owner.
    @Test(.timeLimit(.minutes(2))) func otherStorageFailsTheBuildBeforeNativeSetup() async throws {
        let budget = Self.budget()
        let fixture = try Self.fixture()
        let lease = try await Self.lease(fixture, name: "refused", budget: budget)
        let refusals: [([String: String], Paged.Failure)] = [
            ([Paged.key: "contiguous"], .contiguousUnsupported),
            ([EngineV2KVBackendPolicy.killSwitchEnvKey: "0"], .pagedDisabled),
        ]
        for (environment, failure) in refusals {
            await #expect(throws: failure) {
                _ = try await Self.make(fixture, environment: environment, budget: budget, lease: lease)
            }
            #expect(await budget.reservationBytesSnapshot().isEmpty)
        }
        let owner = try await Self.make(fixture, environment: [:], budget: budget, lease: lease)
        #expect(await owner.bridge.kvBackendKind == .paged)
        try await owner.closeAfterDrain()
        #expect(fixture.residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    /// A configuration naming contiguous storage, or disabling paged KV,
    /// fails the load before its LOAD claim and the installation, so a retry
    /// never reinstalls the checkpoint.
    @Test(arguments: [
        ([Paged.key: "contiguous"], Paged.Failure.contiguousUnsupported),
        ([EngineV2KVBackendPolicy.killSwitchEnvKey: "0"], Paged.Failure.pagedDisabled),
    ])
    func otherStorageFailsTheLoadBeforeInstalling(environment: [String: String], failure: Paged.Failure)
        async throws {
        let base = try SuperMTPInstalledFixture().staging()
        let installs = SuperPrefixInstallCount()
        let staging = NemotronSuperLocalLoad.Staging(source: base.source, install: {
            installs.increment()
            return try base.install($0, $1, $2)
        }, head: nil)
        let budget = Self.budget()
        let load = NemotronSuperLocalLoad(budget: budget)
        var refusal: (any Error)?
        do {
            _ = try await load.load(staging: { staging }, tokenizer: TokenizerHandle(SuperTokenTextTokenizer()),
                eosTokenIDs: [63], sizing: .init(weightsBytes: 1 << 20, fp16KVBytesPerToken: 64,
                    maxContextLength: 64, defaultMaxTokens: 16),
                kvBytesCapacity: Self.grant, backendAllowanceBytes: 1 << 20,
                modelID: NemotronSuperLocalBinding.modelID, environment: environment)
        } catch {
            refusal = error
        }
        #expect(refusal as? Paged.Failure == failure)
        #expect(installs.count == 0)
        #expect(await load.fitAttempts.isEmpty)
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    /// Speculation on paged storage: greedy text equals the plain paged owner.
    @Test(.timeLimit(.minutes(3)), arguments: [
        NemotronSuperLocalMTP.Setting(depth: 3, verification: .serial),
        NemotronSuperLocalMTP.Setting(depth: 2, verification: .rectangularExact),
    ])
    func pagedSpeculationStreamsThePlainPagedText(_ setting: NemotronSuperLocalMTP.Setting)
        async throws {
        let budget = Self.budget()
        let plainFixture = try Self.fixture()
        let speculativeFixture = try Self.fixture()
        let environment = [NemotronSuperLocalPrefill.chunkKey: "4"]
        let (plain, plainLease) = try await Self.owner(plainFixture, environment: environment,
            budget: budget, name: "plain")
        let (speculative, speculativeLease) = try await Self.owner(speculativeFixture,
            environment: environment, budget: budget, name: "speculative", speculation: setting)
        #expect(speculative.speculates)
        #expect(await speculative.bridge.kvBackendKind == .paged)
        for prompt in Self.prompts {
            let speculativeText = try await Self.run(speculative, prompt: prompt)
            let plainText = try await Self.run(plain, prompt: prompt)
            #expect(!plainText.isEmpty && speculativeText == plainText, "prompt \(prompt)")
        }
        let engine = try #require(await speculative.bridge.ownedEngine as? EngineV2)
        #expect(try #require(engine.mtpMetricsSnapshot()).rounds > 0)
        for (owner, lease) in [(plain, plainLease), (speculative, speculativeLease)] {
            try await owner.closeAfterDrain()
            #expect(await budget.finishPendingLoad(lease))
        }
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    /// Exact text prefix reuse on paged storage, plain and speculating, with
    /// an operator's explicit `paged`: each owner holds its bank; after an
    /// unrelated request takes over the donor's freed pages, the next turn restores the
    /// deepest chunk boundary and streams what a cold paged owner streams;
    /// every charge retires.
    @Test(.timeLimit(.minutes(3)), arguments: [false, true])
    func pagedStorageRestoresExactTextPrefixes(speculates: Bool) async throws {
        let budget = Self.budget()
        let warmFixture = try Self.fixture()
        let coldFixture = try Self.fixture()
        let environment = [Paged.key: "paged", NemotronSuperLocalPrefill.chunkKey: "4",
                           PrefixCachePolicy.memoryEnvironmentFlag: "1"]
        let setting = speculates ? NemotronSuperLocalMTP.Setting(depth: 3) : nil
        let (warm, warmLease) = try await Self.owner(warmFixture, environment: environment,
            budget: budget, name: "prefix-warm", speculation: setting)
        let (cold, coldLease) = try await Self.owner(coldFixture, environment: environment,
            budget: budget, name: "prefix-cold", speculation: setting)
        #expect(await warm.bridge.kvBackendKind == .paged && warm.speculates == speculates)
        #expect(warm.prefixBankBytes > 0 && warm.prefixBankBytes == cold.prefixBankBytes)
        // The pool follows the grant minus the bank; the slot still claims the whole grant.
        #expect(await warm.bridge.slotKVBytesClaim() == Self.grant)
        let held = await budget.reservationBytesSnapshot()
        let banks = held.filter { NemotronSuperLocalPrefixCache.isBankReservationID($0.key) }
        #expect(banks.count == 2 && banks.values.allSatisfy { $0 == UInt64(warm.prefixBankBytes) })

        let warmBank = try #require((await warm.bridge.ownedEngine as? EngineV2)?.hybridPrefixCache)
        let donor = NemotronSuperLocalPrefixCacheTests.donor
        let adopter = NemotronSuperLocalPrefixCacheTests.adopter
        _ = try await Self.run(warm, prompt: donor)
        var published = false
        for _ in 0 ..< 500 where !published {
            published = warmBank.stats.entries == 1
            if !published { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(published)
        _ = try await Self.run(warm, prompt: Self.prompts[0])
        let restored = try await Self.run(warm, prompt: adopter)
        #expect(warmBank.stats.adoptions == 1)
        #expect(warmBank.stats.tokensSaved == donor.count / 4 * 4)
        let coldText = try await Self.run(cold, prompt: adopter)
        #expect(!coldText.isEmpty && restored == coldText)

        for (owner, fixture, lease) in [(warm, warmFixture, warmLease), (cold, coldFixture, coldLease)] {
            try await owner.closeAfterDrain()
            #expect(fixture.residency.snapshot.usedBytes == 0)
            #expect(await budget.finishPendingLoad(lease))
        }
        #expect(warmBank.stats.retainedBytes == 0)
        #expect(await budget.reservationBytesSnapshot().isEmpty)
        #expect(await budget.outstandingReservedBytes() == 0)
    }
}
