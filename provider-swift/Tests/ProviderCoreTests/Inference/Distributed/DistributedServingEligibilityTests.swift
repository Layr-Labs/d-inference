import Foundation
import Testing
import DarkbloomClusterProtocol
@testable import ProviderCore

/// Owner decision D4: a pair is served under a per-model grant that lists the
/// chip classes each role may run on; the single-Mac requirements of a model
/// are for solo serving and stay unchanged.
@Suite struct DistributedServingEligibilityTests {
    private let families: [ChipFamily] = [.m1, .m2, .m3, .m4, .m5, .m6, .unknown]
    private let q27 = "registered_qwen38_27b", q27Public = "EigenLabs/Qwen3.8-27B-4bit-mtp"
    private func cls(_ chip: String) -> ClusterNumericsClass { ClusterNumericsClass(chipName: chip)! }
    private func refusal(_ body: () throws -> Void) -> ClusterPairServingRefusal? {
        do { try body(); return nil } catch let refusal as ClusterPairServingRefusal { return refusal } catch { return nil }
    }

    /// A control-only member never reports a kernel capability, on any chip.
    @Test func memberNeverReportsAKernelCapability() {
        for family in families {
            let reported = DistributedServingEligibility.memberCapabilities(chipFamily: family)
            #expect(!reported.contains(.mlxNAX))
            #expect(reported.isSubset(of: [.appleM5]))
        }
        #expect(DistributedServingEligibility.memberCapabilities(chipFamily: .m5) == [.appleM5])
    }

    /// The 27B on an M3 Ultra and an M5 Max, in either order: the grant lists
    /// both classes for both roles, so every rank of both placements passes on
    /// its own Mac, although neither member meets the single-Mac requirements.
    @Test func grantAllowsAnM3UltraRankAndAnM5MaxRankForThe27B() throws {
        for placement in [[ClusterNumericsClass.appleM3Ultra, .appleM5Max], [.appleM5Max, .appleM3Ultra]] {
            try ClusterPairServingGrants.requirePlacement(placement, runtimeModelID: q27, publicModelID: q27Public)
            for (rank, numericsClass) in placement.enumerated() {
                try ClusterPairServingGrants.requireRank(rank, of: 2, numericsClass: numericsClass, runtimeModelID: q27, publicModelID: q27Public)
            }
        }
        let grant = try ClusterPairServingGrants.grant(runtimeModelID: q27, publicModelID: q27Public)
        #expect(grant.allowedNumericsClasses == [.appleM3Ultra, .appleM5Max])
        #expect(grant.allowedNumericsClasses(for: .decodingRank) == [.appleM3Ultra, .appleM5Max])
        #expect(grant.allowedNumericsClasses(for: .pipelineRank) == [.appleM3Ultra, .appleM5Max])
        for family in [ChipFamily.m3, .m5] {
            #expect(!ModelRuntimeRequirements.isEligible(modelID: q27Public,
                available: DistributedServingEligibility.memberCapabilities(chipFamily: family)))
        }
    }

    /// A class the grant does not list is refused for every rank, with the
    /// role, the class and the listed classes in the reason.
    @Test func aChipClassNotListedIsRefused() throws {
        for chip in ["Apple M4 Max", "Apple M5 Pro", "Apple M3 Max", "Apple M5 Ultra", "Apple M2 Ultra", "Apple M5"] {
            let numericsClass = cls(chip)
            for rank in 0..<2 {
                let refused = refusal { try ClusterPairServingGrants.requireRank(rank, of: 2, numericsClass: numericsClass,
                    runtimeModelID: q27, publicModelID: q27Public) }
                let role: ClusterPairServingRole = rank == 1 ? .decodingRank : .pipelineRank
                #expect(refused?.reason == .classNotAllowed(rank: rank, role: role, numericsClass: numericsClass,
                    allowed: [.appleM3Ultra, .appleM5Max]), "\(chip) rank \(rank)")
                let text = refused?.description ?? ""
                #expect(text.contains(numericsClass.rawValue) && text.contains("apple_m3_ultra or apple_m5_max"))
                #expect(text.contains(q27Public) && text.contains(q27) && text.contains("policy decision"))
            }
            // A placement with one unlisted rank is refused as a whole.
            #expect(refusal { try ClusterPairServingGrants.requirePlacement([.appleM3Ultra, numericsClass],
                runtimeModelID: q27, publicModelID: q27Public) } != nil)
        }
        // A grant restricts by role: the 9B ran with the M3 Ultra leading only.
        try ClusterPairServingGrants.requirePlacement([.appleM3Ultra, .appleM5Max], runtimeModelID: "registered_qwen35_9b", publicModelID: "Qwen3.5-9B")
        let mirrored = refusal { try ClusterPairServingGrants.requirePlacement([.appleM5Max, .appleM3Ultra],
            runtimeModelID: "registered_qwen35_9b", publicModelID: "Qwen3.5-9B") }
        #expect(mirrored?.reason == .classNotAllowed(rank: 0, role: .pipelineRank, numericsClass: .appleM5Max, allowed: [.appleM3Ultra]))
        // A chip with no class (a virtual machine, an unknown name) is refused.
        let unknown = refusal { try ClusterPairServingGrants.requireRank(1, of: 2, numericsClass: nil, runtimeModelID: q27, publicModelID: q27Public) }
        #expect(unknown?.reason == .unknownChip(rank: 1, role: .decodingRank))
        #expect(unknown?.description.contains("no numerics class") == true)
    }

    /// A member that claims `mlx_nax` (and `apple_m5`) meets the 27B's
    /// single-Mac requirements, and still gets no pair: a capability is not a
    /// class, makes none, and is not an input to the decision.
    @Test func aMemberClaimingNAXWithoutTheClassIsRefused() {
        let claimed: Set<ProviderRuntimeCapability> = [.appleM5, .mlxNAX, .modelRevisions]
        #expect(ModelRuntimeRequirements.isEligible(modelID: q27Public, available: claimed))
        for name in claimed.map(\.rawValue) + ["Apple M5 Max mlx_nax", "Apple mlx_nax", "apple_m5_max", "Apple M5 NAX"] {
            #expect(ClusterNumericsClass(chipName: name) == nil, "\(name) made a class")
        }
        for numericsClass in [ClusterNumericsClass(chipName: "Apple M5 Pro"), ClusterNumericsClass(chipName: "Apple M4 Max"), nil] {
            for rank in 0..<2 {
                #expect(refusal { try ClusterPairServingGrants.requireRank(rank, of: 2, numericsClass: numericsClass,
                    runtimeModelID: q27, publicModelID: q27Public) } != nil, "\(String(describing: numericsClass)) rank \(rank)")
            }
        }
        // The member loop admits a model by a grant only in the member role and
        // only for the model whose grant its rank passed; a claim admits nothing more.
        let member = loopConfig(role: .clusterMember, capabilities: [], granted: [q27Public])
        #expect(member.admitsModel(q27Public))
        #expect(!member.admitsModel("EigenLabs/Qwen3.8-27B-4bit"))
        #expect(!loopConfig(role: .clusterMember, capabilities: [], granted: []).admitsModel(q27Public))
        #expect(!loopConfig(role: .solo, capabilities: [], granted: [q27Public]).admitsModel(q27Public))
    }

    /// The grant is keyed by the runtime's model, which a setup cannot rename.
    @Test func renamingTheModelChangesNothing() throws {
        try ClusterPairServingGrants.requirePlacement([.appleM5Max, .appleM3Ultra], runtimeModelID: q27, publicModelID: "renamed/public-id")
        let renamed = refusal { try ClusterPairServingGrants.requireRank(1, of: 2, numericsClass: self.cls("Apple M4 Max"),
            runtimeModelID: q27, publicModelID: "renamed/public-id") }
        #expect(renamed?.description.contains("renamed/public-id") == true && renamed?.description.contains(q27) == true)
        // The 27B's public name on another runtime model gets that model's decision.
        let future = refusal { try ClusterPairServingGrants.requireRank(1, of: 2, numericsClass: .appleM5Max,
            runtimeModelID: "registered_future", publicModelID: q27Public) }
        #expect(future?.reason == .noGrant && future?.description.contains("has no grant") == true)
        let nine = refusal { try ClusterPairServingGrants.requireRank(1, of: 2, numericsClass: .appleM3Ultra,
            runtimeModelID: "registered_qwen35_9b", publicModelID: q27Public) }
        #expect(nine?.reason == .classNotAllowed(rank: 1, role: .decodingRank, numericsClass: .appleM3Ultra, allowed: [.appleM5Max]))
    }

    /// Single-Mac serving requirements are unchanged by any of this.
    @Test func singleMacRequirementsAreUnchanged() {
        #expect(ModelRuntimeRequirements.qwen38RequiredCapabilities == [.appleM5, .mlxNAX])
        for model in ModelRuntimeRequirements.qwen38ConcreteModelIDs {
            #expect(ModelRuntimeRequirements.requiredCapabilities(for: model) == [.appleM5, .mlxNAX])
            for (available, eligible) in [([], false), ([.appleM5], false), ([.mlxNAX], false), ([.appleM5, .mlxNAX], true)]
                as [(Set<ProviderRuntimeCapability>, Bool)] {
                #expect(ModelRuntimeRequirements.isEligible(modelID: model, available: available) == eligible)
                // A solo provider admits exactly what the requirements admit.
                #expect(loopConfig(role: .solo, capabilities: available, granted: [model]).admitsModel(model) == eligible)
            }
        }
        #expect(ModelRuntimeRequirements.requiredCapabilities(for: "Qwen3.5-9B").isEmpty)
        #expect(loopConfig(role: .solo, capabilities: [], granted: []).admitsModel("Qwen3.5-9B"))
    }

    /// Every model the runtime registers has exactly one decision: granted on
    /// listed classes, or withheld with the reason.
    @Test func everyRegisteredModelHasOneDecision() throws {
        let registered = ClusterRuntimeAdapter.allCases.flatMap { $0.registeredProfiles.map(\.runtimeModelID) }
        let granted = ClusterPairServingGrants.granted.map(\.runtimeModelID)
        let decided = granted + ClusterPairServingGrants.withheld.keys
        #expect(Set(decided) == Set(registered))
        #expect(decided.count == Set(decided).count)
        for grant in ClusterPairServingGrants.granted {
            #expect(!grant.decodingRankAllowedNumericsClasses.isEmpty && !grant.pipelineRankAllowedNumericsClasses.isEmpty && !grant.evidence.isEmpty)
            try ClusterPairServingGrants.requirePlacement([.appleM3Ultra, .appleM5Max], runtimeModelID: grant.runtimeModelID, publicModelID: "p")
        }
        for (model, reason) in ClusterPairServingGrants.withheld {
            let refused = refusal { try ClusterPairServingGrants.requirePlacement([.appleM3Ultra, .appleM5Max], runtimeModelID: model, publicModelID: "p") }
            #expect(refused?.reason == .withheld(reason))
            #expect(refused?.description.contains("not granted pair serving") == true)
        }
        #expect(ClusterPairServingGrants.acceptedCrossClassVerdicts == ["exact", "tokensEqualLogitsDiffer", "divergedAtNearTie"])
    }

    /// The product serves a model on a pair only with both halves: the grant
    /// (permission, chip classes per role) and a row of time budgets. Every
    /// granted model has its row; a withheld model has none; and the runtime's
    /// model, not the public name, selects both.
    @Test func everyGrantedModelHasItsTimeBudgetsAndNoWithheldModelDoes() throws {
        typealias Table = DistributedInstalledPairServingTable
        #expect(Table.rows.map(\.runtimeModelID) == ClusterPairServingGrants.granted.map(\.runtimeModelID))
        for grant in ClusterPairServingGrants.granted {
            let budgets = try Table.servingBudgets(runtimeModelID: grant.runtimeModelID, publicModelID: "renamed/public-id")
            #expect(budgets.startupAllowanceNanoseconds >= 90_000_000_000 && budgets.firstTokenMillisecondsPerPromptToken >= 1)
        }
        for model in ClusterPairServingGrants.withheld.keys {
            #expect(throws: DistributedInstalledServingRefusal.self) {
                _ = try Table.servingBudgets(runtimeModelID: model, publicModelID: q27Public)
            }
        }
        // The orders the other families' checks ran: the M3 Ultra leads, the M5 Max decodes. The
        // mirrored order of each is refused, for the rank whose class its role does not list.
        for model in ["registered_qwen35_35b_a3b", "registered_qwen36_35b_a3b", "registered_ternary_bonsai_2_27b", "registered_nemotron35_lightning"] {
            try ClusterPairServingGrants.requirePlacement([.appleM3Ultra, .appleM5Max], runtimeModelID: model, publicModelID: "p")
            let mirrored = refusal { try ClusterPairServingGrants.requirePlacement([.appleM5Max, .appleM3Ultra], runtimeModelID: model, publicModelID: "p") }
            #expect(mirrored?.reason == .classNotAllowed(rank: 0, role: .pipelineRank, numericsClass: .appleM5Max, allowed: [.appleM3Ultra]), "\(model)")
            let decoding = refusal { try ClusterPairServingGrants.requireRank(1, of: 2, numericsClass: .appleM3Ultra, runtimeModelID: model, publicModelID: "p") }
            #expect(decoding?.reason == .classNotAllowed(rank: 1, role: .decodingRank, numericsClass: .appleM3Ultra, allowed: [.appleM5Max]), "\(model)")
        }
    }

    @Test func rolesAndPlacementShape() {
        #expect(ClusterPairServingRole.of(rank: 0, rankCount: 2) == .pipelineRank)
        #expect(ClusterPairServingRole.of(rank: 1, rankCount: 2) == .decodingRank)
        #expect(ClusterPairServingRole.of(rank: 1, rankCount: 3) == .pipelineRank)
        #expect(ClusterPairServingRole.of(rank: 2, rankCount: 3) == .decodingRank)
        #expect(ClusterPairServingRole.of(rank: 0, rankCount: 1) == nil)
        #expect(ClusterPairServingRole.of(rank: 2, rankCount: 2) == nil)
        #expect(ClusterPairServingRole.of(rank: -1, rankCount: 2) == nil)
        #expect(refusal { try ClusterPairServingGrants.requirePlacement([.appleM5Max], runtimeModelID: q27, publicModelID: q27Public) }?.reason
            == .placementShape(rank: 0, rankCount: 1))
    }

    @Test func numericsClassSpelling() {
        #expect(ClusterNumericsClass.appleM3Ultra.rawValue == "apple_m3_ultra")
        #expect(ClusterNumericsClass.appleM5Max.rawValue == "apple_m5_max")
        #expect(ClusterNumericsClass(chipName: "Apple M4")?.rawValue == "apple_m4")
        #expect(ClusterNumericsClass(chipName: "apple m5 pro")?.rawValue == "apple_m5_pro")
        for name in ["Apple M1 (Virtual)", "Intel(R) Core(TM) i9", "", "Apple", "Apple M Max", "Apple M10 Max", "Apple M5 Max Extra", "M5 Max"] {
            #expect(ClusterNumericsClass(chipName: name) == nil, "\(name)")
        }
    }

    private func loopConfig(role: ProviderExecutionRole, capabilities: Set<ProviderRuntimeCapability>, granted: Set<String>) -> ProviderLoopConfig {
        ProviderLoopConfig(coordinatorURL: "ws://127.0.0.1:0/unused",
            hardware: HardwareInfo(machineModel: "fixture", chipName: "fixture", chipFamily: .m3, chipTier: .ultra,
                memoryGb: 256, memoryAvailableGb: 252, cpuCores: CpuCores(total: 32, performance: 24, efficiency: 8),
                gpuCores: 80, memoryBandwidthGbs: 819),
            models: [], config: ProviderConfig(provider: ProviderSettings(name: "pair-grant-test", memoryReserveGB: 1),
                backend: BackendSettings(model: nil, enabledModels: [], idleTimeoutMins: 0, preloadModels: []),
                coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)),
            runtimeCapabilities: capabilities, executionRole: role, pairServingGrantedModelIDs: granted)
    }
}
