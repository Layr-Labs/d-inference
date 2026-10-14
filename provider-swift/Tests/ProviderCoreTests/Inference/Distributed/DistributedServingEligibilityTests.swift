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
    private func cls(_ chip: String) -> ClusterChipClass { ClusterChipClass(chipName: chip)! }
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
        for placement in [[ClusterChipClass.appleM3Ultra, .appleM5Max], [.appleM5Max, .appleM3Ultra]] {
            try ClusterPairServingGrants.requirePlacement(placement, runtimeModelID: q27, publicModelID: q27Public)
            for (rank, chipClass) in placement.enumerated() {
                try ClusterPairServingGrants.requireRank(rank, of: 2, chipClass: chipClass, runtimeModelID: q27, publicModelID: q27Public)
            }
        }
        let grant = try ClusterPairServingGrants.grant(runtimeModelID: q27, publicModelID: q27Public)
        #expect(grant.chipClasses == [.appleM3Ultra, .appleM5Max, .appleM5Ultra])
        #expect(grant.chipClasses(for: .decodingRank) == [.appleM3Ultra, .appleM5Max, .appleM5Ultra])
        #expect(grant.chipClasses(for: .pipelineRank) == [.appleM3Ultra, .appleM5Max])
        for family in [ChipFamily.m3, .m5] {
            #expect(!ModelRuntimeRequirements.isEligible(modelID: q27Public,
                available: DistributedServingEligibility.memberCapabilities(chipFamily: family)))
        }
    }

    /// A class the grant does not list is refused for every rank, with the
    /// role, the class and the listed classes in the reason.
    @Test func aChipClassNotListedIsRefused() throws {
        for chip in ["Apple M4 Max", "Apple M5 Pro", "Apple M3 Max", "Apple M2 Ultra", "Apple M5"] {
            let chipClass = cls(chip)
            for rank in 0..<2 {
                let refused = refusal { try ClusterPairServingGrants.requireRank(rank, of: 2, chipClass: chipClass,
                    runtimeModelID: q27, publicModelID: q27Public) }
                let role: ClusterPairServingRole = rank == 1 ? .decodingRank : .pipelineRank
                let allowed: [ClusterChipClass] = rank == 1 ? [.appleM3Ultra, .appleM5Max, .appleM5Ultra] : [.appleM3Ultra, .appleM5Max]
                #expect(refused?.reason == .classNotAllowed(rank: rank, role: role, chipClass: chipClass,
                    allowed: allowed), "\(chip) rank \(rank)")
                let text = refused?.description ?? ""
                #expect(text.contains(chipClass.rawValue) && text.contains(allowed.map(\.rawValue).joined(separator: " or ")))
                #expect(text.contains(q27Public) && text.contains(q27) && text.contains("policy decision"))
            }
            // A placement with one unlisted rank is refused as a whole.
            #expect(refusal { try ClusterPairServingGrants.requirePlacement([.appleM3Ultra, chipClass],
                runtimeModelID: q27, publicModelID: q27Public) } != nil)
        }
        // The M5 Ultra decodes the 9B and the 27B (its cross-cable checks ran as rank 1), and leads neither.
        for model in [("registered_qwen35_9b", "Qwen3.5-9B"), (q27, q27Public)] {
            try ClusterPairServingGrants.requirePlacement([.appleM3Ultra, .appleM5Ultra], runtimeModelID: model.0, publicModelID: model.1)
            #expect(refusal { try ClusterPairServingGrants.requirePlacement([.appleM5Ultra, .appleM3Ultra],
                runtimeModelID: model.0, publicModelID: model.1) } != nil, "\(model.1) led by the M5 Ultra")
        }
        // A grant restricts by role: the 9B ran with the M3 Ultra leading only.
        try ClusterPairServingGrants.requirePlacement([.appleM3Ultra, .appleM5Max], runtimeModelID: "registered_qwen35_9b", publicModelID: "Qwen3.5-9B")
        let mirrored = refusal { try ClusterPairServingGrants.requirePlacement([.appleM5Max, .appleM3Ultra],
            runtimeModelID: "registered_qwen35_9b", publicModelID: "Qwen3.5-9B") }
        #expect(mirrored?.reason == .classNotAllowed(rank: 0, role: .pipelineRank, chipClass: .appleM5Max, allowed: [.appleM3Ultra]))
        // A chip with no class (a virtual machine, an unknown name) is refused.
        let unknown = refusal { try ClusterPairServingGrants.requireRank(1, of: 2, chipClass: nil, runtimeModelID: q27, publicModelID: q27Public) }
        #expect(unknown?.reason == .unknownChip(rank: 1, role: .decodingRank))
        #expect(unknown?.description.contains("no chip class") == true)
    }

    /// A member that claims `mlx_nax` (and `apple_m5`) meets the 27B's
    /// single-Mac requirements, and still gets no pair: a capability is not a
    /// class, makes none, and is not an input to the decision.
    @Test func aMemberClaimingNAXWithoutTheClassIsRefused() {
        let claimed: Set<ProviderRuntimeCapability> = [.appleM5, .mlxNAX, .modelRevisions]
        #expect(ModelRuntimeRequirements.isEligible(modelID: q27Public, available: claimed))
        for name in claimed.map(\.rawValue) + ["Apple M5 Max mlx_nax", "Apple mlx_nax", "apple_m5_max", "Apple M5 NAX"] {
            #expect(ClusterChipClass(chipName: name) == nil, "\(name) made a class")
        }
        for chipClass in [ClusterChipClass(chipName: "Apple M5 Pro"), ClusterChipClass(chipName: "Apple M4 Max"), nil] {
            for rank in 0..<2 {
                #expect(refusal { try ClusterPairServingGrants.requireRank(rank, of: 2, chipClass: chipClass,
                    runtimeModelID: q27, publicModelID: q27Public) } != nil, "\(String(describing: chipClass)) rank \(rank)")
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
        let renamed = refusal { try ClusterPairServingGrants.requireRank(1, of: 2, chipClass: self.cls("Apple M4 Max"),
            runtimeModelID: q27, publicModelID: "renamed/public-id") }
        #expect(renamed?.description.contains("renamed/public-id") == true && renamed?.description.contains(q27) == true)
        // The 27B's public name on another runtime model gets that model's decision.
        let future = refusal { try ClusterPairServingGrants.requireRank(1, of: 2, chipClass: .appleM5Max,
            runtimeModelID: "registered_future", publicModelID: q27Public) }
        #expect(future?.reason == .noGrant && future?.description.contains("has no grant") == true)
        let nine = refusal { try ClusterPairServingGrants.requireRank(1, of: 2, chipClass: .appleM3Ultra,
            runtimeModelID: "registered_qwen35_9b", publicModelID: q27Public) }
        #expect(nine?.reason == .classNotAllowed(rank: 1, role: .decodingRank, chipClass: .appleM3Ultra, allowed: [.appleM5Max, .appleM5Ultra]))
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
        // Every decision is about a registered model, and none is both granted and withheld.
        #expect(Set(decided).isSubset(of: Set(registered)))
        #expect(decided.count == Set(decided).count)
        // A registered model with no decision has no record that passed or diverged: refused as having no grant.
        for model in Set(registered).subtracting(decided) {
            #expect(refusal { try ClusterPairServingGrants.requirePlacement([.appleM3Ultra, .appleM5Max], runtimeModelID: model, publicModelID: "p") }?.reason == .noGrant)
        }
        for grant in ClusterPairServingGrants.granted {
            #expect(!grant.decodingRankChipClasses.isEmpty && !grant.pipelineRankChipClasses.isEmpty && !grant.evidence.isEmpty)
            try ClusterPairServingGrants.requirePlacement([.appleM3Ultra, .appleM5Max], runtimeModelID: grant.runtimeModelID, publicModelID: "p")
        }
        for (model, reason) in ClusterPairServingGrants.withheld {
            let refused = refusal { try ClusterPairServingGrants.requirePlacement([.appleM3Ultra, .appleM5Max], runtimeModelID: model, publicModelID: "p") }
            #expect(refused?.reason == .withheld(reason))
            #expect(refused?.description.contains("not granted pair serving") == true)
        }
        #expect(ClusterPairServingGrants.acceptedCrossClassVerdicts == ["exact", "tokensEqualLogitsDiffer", "divergedAtNearTie"])
        // The records this build ships: every one is used, and they decide the models the runs decided.
        #expect(!ClusterPairServingGrants.records.isEmpty && ClusterPairServingGrants.decisions.ignored == 0)
        #expect(Set(granted) == ["registered_qwen35_9b", "registered_qwen38_27b", "registered_qwen35_35b_a3b", "registered_qwen36_35b_a3b",
                                 "registered_ternary_bonsai_2_27b", "registered_nemotron35_lightning"])
        // registered_gemma4_26b has no record of its own: the two that named it ran the 8-bit artifact and are not shipped.
        #expect(Set(ClusterPairServingGrants.withheld.keys) == ["registered_gpt_oss_20b",
                                                                "registered_gemma4_26b_8bit", "registered_gemma4_26b_qat_4bit"])
        #expect(ClusterPairServingGrants.withheld["registered_gpt_oss_20b"]?.contains("diverged at cuts 4, 8 and 10") == true)
    }

    /// The product serves a model on a pair only with both halves: the grant
    /// (permission, chip classes per role) and a row of time budgets. Every
    /// granted model has its row; a withheld model has none; and the runtime's
    /// model, not the public name, selects both.
    @Test func everyGrantedModelHasItsTimeBudgetsAndNoWithheldModelDoes() throws {
        typealias Table = DistributedInstalledPairServingTable
        #expect(Set(Table.rows.map(\.runtimeModelID)) == Set(ClusterPairServingGrants.granted.map(\.runtimeModelID)))
        for grant in ClusterPairServingGrants.granted {
            let budgets = try Table.servingBudgets(runtimeModelID: grant.runtimeModelID, publicModelID: "renamed/public-id")
            #expect(budgets.startupAllowanceNanoseconds >= 90_000_000_000 && budgets.firstTokenMillisecondsPerPromptToken >= 1)
        }
        for model in ClusterPairServingGrants.withheld.keys {
            #expect(throws: DistributedInstalledServingRefusal.self) {
                _ = try Table.servingBudgets(runtimeModelID: model, publicModelID: q27Public)
            }
        }
        // The orders the other families' checks ran: the M3 Ultra leads, the M5 Max or the M5 Ultra decodes.
        // The mirrored order of each is refused, for the rank whose class its role does not list.
        for model in ["registered_qwen35_35b_a3b", "registered_qwen36_35b_a3b", "registered_ternary_bonsai_2_27b", "registered_nemotron35_lightning"] {
            try ClusterPairServingGrants.requirePlacement([.appleM3Ultra, .appleM5Max], runtimeModelID: model, publicModelID: "p")
            let mirrored = refusal { try ClusterPairServingGrants.requirePlacement([.appleM5Max, .appleM3Ultra], runtimeModelID: model, publicModelID: "p") }
            #expect(mirrored?.reason == .classNotAllowed(rank: 0, role: .pipelineRank, chipClass: .appleM5Max, allowed: [.appleM3Ultra]), "\(model)")
            let decoding = refusal { try ClusterPairServingGrants.requireRank(1, of: 2, chipClass: .appleM3Ultra, runtimeModelID: model, publicModelID: "p") }
            #expect(decoding?.reason == .classNotAllowed(rank: 1, role: .decodingRank, chipClass: .appleM3Ultra, allowed: [.appleM5Max, .appleM5Ultra]), "\(model)")
        }
    }

    /// Each grant rests on placements in the shape of the coordinator's parity
    /// qualification (one chip class per rank in rank order, `cuts`, `mode`),
    /// and its role classes are exactly the classes those placements ran in
    /// each role: a class cannot be listed for a role no passed check ran it in.
    @Test func grantsRestOnWellFormedQualifications() throws {
        for grant in ClusterPairServingGrants.granted {
            #expect(!grant.qualifications.isEmpty, "\(grant.runtimeModelID)")
            for qualification in grant.qualifications {
                #expect(qualification.isWellFormed, "\(grant.runtimeModelID) \(qualification)")
            }
            let placements = grant.qualifications.map { "\($0.chipClasses.map(\.rawValue)) \($0.cuts) \($0.mode.rawValue)" }
            #expect(placements.count == Set(placements).count, "\(grant.runtimeModelID) lists one placement twice")
            #expect(grant.decodingRankChipClasses == Set(grant.qualifications.compactMap(\.chipClasses.last)))
        }
        let q27 = try ClusterPairServingGrants.grant(runtimeModelID: "registered_qwen38_27b", publicModelID: "p")
        #expect(q27.qualifications.contains(.init(chipClasses: [.appleM3Ultra, .appleM5Max], cuts: [16], mode: .phaseSplitMTP)))
        #expect(q27.qualifications.contains(.init(chipClasses: [.appleM5Max, .appleM3Ultra], cuts: [48], mode: .phaseSplit)))
        // Without its mirrored-order checks the 27B would be granted the order the others have, and no more.
        let normalOrderOnly = ClusterPairServingGrant(runtimeModelID: q27.runtimeModelID,
            qualifications: q27.qualifications.filter { $0.chipClasses.first == .appleM3Ultra }, evidence: "")
        #expect(normalOrderOnly.decodingRankChipClasses == [.appleM5Max, .appleM5Ultra] && normalOrderOnly.pipelineRankChipClasses == [.appleM3Ultra])
        #expect(ClusterPairServingGrant(runtimeModelID: q27.runtimeModelID, qualifications: [], evidence: "").chipClasses.isEmpty)
        // The coordinator's shape rules for a placement.
        #expect(!ClusterPairServingQualification(chipClasses: [.appleM3Ultra], cuts: [], mode: .pipeline).isWellFormed)
        #expect(!ClusterPairServingQualification(chipClasses: [.appleM3Ultra, .appleM5Max], cuts: [16, 20], mode: .pipeline).isWellFormed)
        #expect(!ClusterPairServingQualification(chipClasses: [.appleM3Ultra, .appleM5Max], cuts: [0], mode: .pipeline).isWellFormed)
        #expect(!ClusterPairServingQualification(chipClasses: [.appleM3Ultra, .appleM5Max, .appleM5Max], cuts: [20, 16], mode: .pipeline).isWellFormed)
        #expect(ClusterPairServingQualification(chipClasses: [.appleM3Ultra, .appleM5Max, .appleM5Max], cuts: [16, 20], mode: .pipeline).isWellFormed)
        // Modes are spelled as the coordinator's plan modes.
        #expect(Set(ClusterGenerationMode.allCases.map(\.rawValue))
            == ["pipeline_v1", "pipeline_compact_decode_v1", "phase_split_v1", "phase_split_mtp_v1",
                "tensor_parallel_v1", "pipeline_prefill_tensor_decode_v1"])
        // Tensor parallel cuts no layer range; its hybrid names its prefill cut.
        #expect(ClusterPairServingQualification(chipClasses: [.appleM3Ultra, .appleM5Max], cuts: [], mode: .tensorParallel).isWellFormed)
        #expect(!ClusterPairServingQualification(chipClasses: [.appleM3Ultra, .appleM5Max], cuts: [16], mode: .tensorParallel).isWellFormed)
        #expect(ClusterPairServingQualification(chipClasses: [.appleM3Ultra, .appleM5Max], cuts: [16], mode: .pipelinePrefillTensorDecode).isWellFormed)
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

    @Test func chipClassSpelling() {
        #expect(ClusterChipClass.appleM3Ultra.rawValue == "apple_m3_ultra")
        #expect(ClusterChipClass.appleM5Max.rawValue == "apple_m5_max")
        #expect(ClusterChipClass(chipName: "Apple M4")?.rawValue == "apple_m4")
        #expect(ClusterChipClass(chipName: "apple m5 pro")?.rawValue == "apple_m5_pro")
        for name in ["Apple M1 (Virtual)", "Intel(R) Core(TM) i9", "", "Apple", "Apple M Max", "Apple M10 Max", "Apple M5 Max Extra", "M5 Max"] {
            #expect(ClusterChipClass(chipName: name) == nil, "\(name)")
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

/// Synthetic chip classes for the tests. Product code names no chip.
extension ClusterChipClass {
    static let appleM3Ultra = ClusterChipClass(chipName: "Apple M3 Ultra")!
    static let appleM5Max = ClusterChipClass(chipName: "Apple M5 Max")!
    static let appleM5Ultra = ClusterChipClass(chipName: "Apple M5 Ultra")!
}
