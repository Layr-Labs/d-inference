// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// Complete SSD checkpoints of the Super owner, the default exact prefix
/// reuse. A routed owner without a bank keeps its chunk checkpoints in an
/// encrypted store: they restore exactly within the owner and, after the
/// owner is retired, in a new installation, engine and store on the same root
/// and key (a restart). Lookups and publications carry the SSD tier, another
/// scope never hits, and the store holds no shared-budget reservation.
struct NemotronSuperDurablePrefixCacheTests {
    typealias Evidence = NemotronSuperPrefixCacheEvidenceTests
    typealias Prefix = NemotronSuperLocalPrefixCache

    static let routing = Prefix.RoutingIdentity(modelAggregateHash: String(repeating: "d", count: 64),
                                                promptContractID: String(repeating: "e", count: 64))
    /// The disk identity a provider binary computes from its binary, metallib
    /// and numerics; a test process cannot, so both owners name the same one.
    static let disk = CBv2CompleteCheckpointIdentity(modelAggregateHash: routing.modelAggregateHash,
        promptContractID: routing.promptContractID, buildID: "super-durable-test",
        numericsFingerprint: "super-durable-test")

    /// An isolated store root and a persistent debug key file, as an offline
    /// restart benchmark uses: the store's files survive the owner.
    struct Disk {
        let directory: URL
        let environment: [String: String]

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("super-durable-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let key = directory.appendingPathComponent("cache.key")
            var bytes = [UInt8](repeating: 0, count: SSDDebugCacheKeyFile.keyByteCount)
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0 ... 255) }
            #expect(FileManager.default.createFile(atPath: key.path, contents: Data(bytes),
                                                   attributes: [.posixPermissions: 0o600]))
            environment = [
                NemotronSuperLocalPrefill.chunkKey: String(Evidence.chunk),
                "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1",
                SSDPrefixCacheFactory.testRootEnvironmentKey: directory.appendingPathComponent("root").path,
                "DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY": "1",
                SSDDebugCacheKeyFile.environmentKey: key.path,
                // The fixture's 256-token chunks: write from the second one up.
                SSDPrefixCachePolicy.minEffectiveTokensFlag: String(2 * Evidence.chunk),
            ]
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    /// The managed slot's catalog id.
    static let modelID = NemotronSuperServingPolicy.modelID

    @Test func ownersWithoutABankKeepDurableCheckpointsByDefault() {
        let base = [NemotronSuperLocalPrefill.chunkKey: "256"]
        #expect(Prefix.durableIdentity(environment: base, modelID: Self.modelID,
                                       routingIdentity: Self.routing) == Self.routing)
        // The operator's resident tier, the kill switch or a missing identity: none.
        #expect(Prefix.durableIdentity(environment: base.merging([Evidence.memoryKey: "1"]) { $1 },
            modelID: Self.modelID, routingIdentity: Self.routing) == nil)
        #expect(Prefix.durableIdentity(environment: base.merging(["DARKBLOOM_PREFIX_CACHE": "0"]) { $1 },
            modelID: Self.modelID, routingIdentity: Self.routing) == nil)
        #expect(Prefix.durableIdentity(environment: base, modelID: Self.modelID, routingIdentity: nil) == nil)
        // The qualification runner's id needs the global opt-in.
        #expect(Prefix.durableIdentity(environment: base, modelID: NemotronSuperLocalBinding.modelID,
                                       routingIdentity: Self.routing) == nil)
        #expect(Prefix.durableIdentity(environment: base.merging(["DARKBLOOM_PREFIX_CACHE": "1"]) { $1 },
            modelID: NemotronSuperLocalBinding.modelID, routingIdentity: Self.routing) == Self.routing)
        // The managed plan reserves no bank for them.
        let plan = NemotronSuperServingPolicy.loadPlan(base: base, mode: .auto, configuredConcurrency: nil,
            kvBytesCapacity: 100 << 30)
        #expect(plan.prefixBankBytes == 0 && plan.environment[Evidence.memoryKey] == nil)
        #expect(Prefix.durableIdentity(environment: plan.environment, modelID: Self.modelID,
                                       routingIdentity: Self.routing) == Self.routing)
    }

    @Test(.timeLimit(.minutes(4)), arguments: [false, true])
    func durableCheckpointsRestoreExactlyAcrossAnOwnerRestart(speculates: Bool) async throws {
        let disk = try Disk()
        defer { disk.remove() }
        let budget = Evidence.budget()
        let firstFixture = try SuperMTPInstalledFixture().make()
        let firstLease = try await Evidence.lease(firstFixture, "durable-first", budget: budget,
                                                  speculates: speculates)
        let first = try await Evidence.owner(firstFixture, environment: disk.environment, budget: budget,
            lease: firstLease, speculates: speculates, routing: Self.routing, modelID: Self.modelID,
            completeCheckpointIdentity: Self.disk)
        let store = try #require(first.bridge.ssdHybridCheckpointStore,
            "\(first.bridge.prefixCacheModelStatus()) \(String(describing: first.bridge.prefixCacheConstructionFailure))")
        #expect(first.prefixBankBytes == 0 && first.bridge.residentPrefixCacheEvidence == nil)
        #expect(await Self.ready(first))
        let advertised = try #require(first.bridge.durablePrefixCacheEvidenceSource?
            .prefixCacheAdvertisement(base: first.bridge.prefixCacheBaseStatus).capability)
        #expect(advertised.modelId == Self.modelID)
        #expect(advertised.modelAggregateHash == Self.routing.modelAggregateHash)
        #expect(advertised.promptContractId == Self.routing.promptContractID)
        #expect(advertised.enabled && advertised.ready)
        // The store keeps no checkpoint in the shared budget between requests.
        #expect(!(await budget.reservationBytesSnapshot()).keys.contains(where: Prefix.isBankReservationID))

        // The donor writes the chunk checkpoint at 512 (256 is below the floor).
        let donor = Evidence.Receipts()
        _ = try await Evidence.run(first, prompt: Evidence.donor, scope: "tenant-a", receipts: donor)
        #expect(donor.lookups.first?.outcome == .missAbsent && donor.lookups.first?.tier == .ssd)
        let published = await Evidence.eventually { !donor.ready.isEmpty }
        #expect(published)
        #expect(donor.ready.last?.tier == .ssd)
        #expect(donor.ready.last?.readyAnchors.last?.tokenCount == 512)
        #expect(store.stats().filesWritten > 0)

        // The next turn restores 512 tokens from the store; another tenant is
        // cold. A restored assistant history drafts as the cold one does.
        let warm = Evidence.Receipts()
        var restored = ""
        let restoredDrafting = try await Self.drafting(first) {
            restored = try await Evidence.run(first, prompt: Evidence.adopter, scope: "tenant-a", receipts: warm)
        }
        let hit = try #require(warm.lookups.first)
        #expect(hit.outcome == .hit && hit.tier == .ssd && hit.cachedTokens == 512, "\(hit)")
        #expect(warm.signal.prefixCacheHitTokens == 512)
        let other = Evidence.Receipts()
        var cold = ""
        let coldDrafting = try await Self.drafting(first) {
            cold = try await Evidence.run(first, prompt: Evidence.adopter, scope: "tenant-b", receipts: other)
        }
        #expect(other.lookups.first?.outcome == .missAbsent && other.lookups.first?.cachedTokens == 0)
        #expect(!cold.isEmpty && restored == cold)
        #expect(restoredDrafting == coldDrafting)
        #expect(!speculates || coldDrafting[0] > 0, "\(coldDrafting)")
        try await first.closeAfterDrain()
        #expect(await budget.reservationBytesSnapshot().isEmpty)
        #expect(await budget.finishPendingLoad(firstLease))

        // A restart: a new installation, engine and store on the same root and key.
        let secondFixture = try SuperMTPInstalledFixture().make()
        let secondLease = try await Evidence.lease(secondFixture, "durable-second", budget: budget,
                                                   speculates: speculates)
        let second = try await Evidence.owner(secondFixture, environment: disk.environment, budget: budget,
            lease: secondLease, speculates: speculates, routing: Self.routing, modelID: Self.modelID,
            completeCheckpointIdentity: Self.disk)
        #expect(await Self.ready(second))
        let again = Evidence.Receipts()
        var afterRestart = ""
        let restartDrafting = try await Self.drafting(second) {
            afterRestart = try await Evidence.run(second, prompt: Evidence.adopter, scope: "tenant-a",
                                                  receipts: again)
        }
        let restartHit = try #require(again.lookups.first)
        #expect(restartHit.outcome == .hit && restartHit.tier == .ssd && restartHit.cachedTokens == 512,
                "\(restartHit)")
        #expect(afterRestart == cold)
        #expect(restartDrafting == coldDrafting)
        try await second.closeAfterDrain()
        #expect(await budget.reservationBytesSnapshot().isEmpty)
        #expect(await budget.finishPendingLoad(secondLease))
    }

    /// Rounds, drafted and accepted tokens of the engine across `body`.
    static func drafting(_ owner: NemotronSuperLocalBridgeBuilder.Owner,
                         _ body: () async throws -> Void) async rethrows -> [Int] {
        let engine = await owner.bridge.ownedEngine as? EngineV2
        let before = engine?.mtpMetricsSnapshot()
        try await body()
        let after = engine?.mtpMetricsSnapshot()
        return [(after?.rounds ?? 0) - (before?.rounds ?? 0),
                (after?.draftedTokens ?? 0) - (before?.draftedTokens ?? 0),
                (after?.acceptedTokens ?? 0) - (before?.acceptedTokens ?? 0)]
    }

    /// The store scans its root before it advertises or restores.
    static func ready(_ owner: NemotronSuperLocalBridgeBuilder.Owner) async -> Bool {
        await Evidence.eventually { owner.bridge.prefixCacheModelStatus().state == .ready }
    }
}
