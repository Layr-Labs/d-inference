import Foundation
import Testing
import DarkbloomClusterProtocol
@testable import ProviderCore

/// A pair serves its owner any model a cluster stage adapter runs, on any
/// Apple silicon, in any sharded mode (owner, 2026-10-14 08:45: records never
/// block owner serving; chips and memory do not gate what is offered); public
/// traffic needs a per-model grant of mode families from passing records. The
/// single-Mac requirements of a model are for solo serving and stay unchanged.
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

    /// The 27B on an M3 Ultra and an M5 Max, in either order, in the mode
    /// family both orders' checks ran (the hand-off family), and on Macs no
    /// check ran (2x M4 Max): every rank of every placement passes on its own
    /// Mac, although no member meets the single-Mac requirements.
    @Test func grantAllowsAnyAppleSiliconRankForThe27B() throws {
        let m4max = cls("Apple M4 Max")
        for placement in [[ClusterChipClass.appleM3Ultra, .appleM5Max], [.appleM5Max, .appleM3Ultra], [m4max, m4max], [m4max, .appleM3Ultra]] {
            try ClusterPairServingGrants.requirePlacement(placement, runtimeModelID: q27, publicModelID: q27Public, mode: .phaseSplit)
            try ClusterPairServingGrants.requirePlacement(placement, runtimeModelID: q27, publicModelID: q27Public, cuts: [16], mode: .pipeline)
            for (rank, chipClass) in placement.enumerated() {
                try ClusterPairServingGrants.requireRank(rank, of: 2, chipClass: chipClass, runtimeModelID: q27, publicModelID: q27Public,
                                                         mode: .phaseSplitMTP)
            }
        }
        let grant = try ClusterPairServingGrants.grant(runtimeModelID: q27, publicModelID: q27Public)
        #expect(grant.qualifiedChipClasses == [.appleM3Ultra, .appleM5Max, .appleM5Ultra])
        for family in [ChipFamily.m3, .m4, .m5] {
            #expect(!ModelRuntimeRequirements.isEligible(modelID: q27Public,
                available: DistributedServingEligibility.memberCapabilities(chipFamily: family)))
        }
    }

    /// No chip class is listed: any Apple silicon may run any rank of a
    /// granted family, in any order. A chip with no class (a virtual machine,
    /// an unknown name) is refused, and a family no check passed is refused
    /// on every chip.
    @Test func anyAppleSiliconRunsAnyRankAndOnlyAClasslessChipIsRefused() throws {
        for chip in ["Apple M4 Max", "Apple M5 Pro", "Apple M3 Max", "Apple M2 Ultra", "Apple M5", "Apple M1 Pro"] {
            let chipClass = cls(chip)
            for rank in 0..<2 {
                try ClusterPairServingGrants.requireRank(rank, of: 2, chipClass: chipClass, runtimeModelID: q27, publicModelID: q27Public,
                                                         mode: .phaseSplit)
            }
            try ClusterPairServingGrants.requirePlacement([.appleM3Ultra, chipClass], runtimeModelID: q27, publicModelID: q27Public, mode: .phaseSplit)
            try ClusterPairServingGrants.requirePlacement([chipClass, chipClass], runtimeModelID: "registered_qwen35_9b", publicModelID: "Qwen3.5-9B",
                                                          cuts: [16], mode: .pipeline)
            // Tensor parallel is served for the owner on every chip; the 27B's bundled tensor_parallel_v1 records
            // (tp-engine, since round 6e) qualify that family for public traffic too.
            try ClusterPairServingGrants.requirePlacement([chipClass, chipClass], runtimeModelID: q27, publicModelID: q27Public,
                                                          cuts: [], mode: .tensorParallel)
            #expect(ClusterPairServingGrants.publicTrafficLine(runtimeModelID: q27, mode: .tensorParallel)
                .hasPrefix("qualified for public traffic in tensor parallel mode"))
            // A family no check of the model passed (the 35B A3B has no pipeline_mtp_v1 record) is served for the
            // owner on every chip, and not qualified for public traffic.
            try ClusterPairServingGrants.requirePlacement([chipClass, chipClass], runtimeModelID: "registered_qwen35_35b_a3b", publicModelID: "p",
                                                          cuts: [20], mode: .pipelineMTP)
            #expect(ClusterPairServingGrants.publicTrafficLine(runtimeModelID: "registered_qwen35_35b_a3b", mode: .pipelineMTP)
                == ClusterPairOwnerServing.notYetQualified)
        }
        // The rank order is free too: the M5 Ultra leads the 9B and the 27B.
        for model in [("registered_qwen35_9b", "Qwen3.5-9B"), (q27, q27Public)] {
            try ClusterPairServingGrants.requirePlacement([.appleM5Ultra, .appleM3Ultra], runtimeModelID: model.0, publicModelID: model.1, mode: .phaseSplitMTP)
            try ClusterPairServingGrants.requirePlacement([.appleM5Max, .appleM3Ultra], runtimeModelID: model.0, publicModelID: model.1, mode: .phaseSplit)
        }
        let unknown = refusal { try ClusterPairServingGrants.requireRank(1, of: 2, chipClass: nil, runtimeModelID: q27, publicModelID: q27Public) }
        #expect(unknown?.reason == .unknownChip(rank: 1, role: .decodingRank))
        #expect(unknown?.description.contains("not Apple silicon") == true)
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
        // A claim opens nothing: without the mode the rank is refused on any chip, and a classless chip always.
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
        try ClusterPairServingGrants.requirePlacement([.appleM5Max, .appleM3Ultra], runtimeModelID: q27, publicModelID: "renamed/public-id", mode: .phaseSplit)
        let renamed = refusal { try ClusterPairServingGrants.requireRank(1, of: 2, chipClass: self.cls("Apple M4 Max"),
            runtimeModelID: q27, publicModelID: "renamed/public-id", mode: nil) }
        #expect(renamed?.description.contains("renamed/public-id") == true && renamed?.description.contains(q27) == true)
        // The 27B's public name on another runtime model gets that model's decision.
        let future = refusal { try ClusterPairServingGrants.requireRank(1, of: 2, chipClass: .appleM5Max,
            runtimeModelID: "registered_future", publicModelID: q27Public) }
        #expect(future?.reason == .noStageAdapter && future?.description.contains("no cluster stage adapter") == true)
        try ClusterPairServingGrants.requireRank(1, of: 2, chipClass: .appleM3Ultra,
            runtimeModelID: "registered_qwen35_9b", publicModelID: q27Public, mode: .phaseSplit)
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

    /// Every model the runtime registers has exactly one decision: granted (on
    /// any Apple silicon), or withheld with the reason.
    @Test func everyRegisteredModelHasOneDecision() throws {
        let registered = ClusterRuntimeAdapter.allCases.flatMap { $0.registeredProfiles.map(\.runtimeModelID) }
        let granted = ClusterPairServingGrants.granted.map(\.runtimeModelID)
        let decided = granted + ClusterPairServingGrants.withheld.keys
        // Every decision is about a registered model, and none is both granted and withheld.
        #expect(Set(decided).isSubset(of: Set(registered)))
        #expect(decided.count == Set(decided).count)
        // A registered model with no decision has no record that passed or diverged: served for its owner, with no
        // public grant.
        for model in Set(registered).subtracting(decided) {
            try ClusterPairServingGrants.requirePlacement([.appleM3Ultra, .appleM5Max], runtimeModelID: model, publicModelID: "p",
                                                          cuts: [8], mode: .pipeline)
            #expect(refusal { _ = try ClusterPairServingGrants.grant(runtimeModelID: model, publicModelID: "p") }?.reason == .noGrant)
        }
        for grant in ClusterPairServingGrants.granted {
            #expect(!grant.qualifiedChipClasses.isEmpty && !grant.evidence.isEmpty)
            // Every placement a passed check ran is admitted, at its cuts and in its mode, unless a check of the same
            // shape diverged (then the divergence wins).
            let checks = ClusterPairServingGrants.records(runtimeModelID: grant.runtimeModelID)
            for qualification in grant.qualifications where !checks.failed.contains(where: {
                $0.chipClasses == qualification.chipClasses && $0.cuts == qualification.cuts && $0.family == qualification.family }) {
                try ClusterPairServingGrants.requirePlacement(qualification.chipClasses, runtimeModelID: grant.runtimeModelID,
                                                              publicModelID: "p", cuts: qualification.cuts, mode: qualification.mode)
            }
        }
        for (model, reason) in ClusterPairServingGrants.withheld {
            let refused = refusal { _ = try ClusterPairServingGrants.grant(runtimeModelID: model, publicModelID: "p") }
            #expect(refused?.reason == .withheld(reason))
            #expect(refused?.description.contains("not qualified for public traffic") == true)
            // Its owner is served away from the shapes that diverged.
            try ClusterPairServingGrants.requirePlacement([cls("Apple M4 Max"), cls("Apple M4 Max")], runtimeModelID: model, publicModelID: "p",
                                                          cuts: [6], mode: .pipeline)
        }
        #expect(ClusterPairServingGrants.acceptedCrossClassVerdicts == ["exact", "tokensEqualLogitsDiffer", "divergedAtNearTie"])
        // The records this build ships: every one is used, and they decide the models the runs decided.
        #expect(!ClusterPairServingGrants.records.isEmpty && ClusterPairServingGrants.decisions.ignored == 0)
        // A model with an uncontradicted passing record is granted; GPT-OSS and Gemma 4 QAT4 diverged on the bench pair at some
        // cuts and passed at others, so they are granted and restricted on the chips that diverged. Gemma 4 8-bit's one pass is
        // contradicted by a divergence of the same shape: withheld.
        #expect(Set(granted) == ["registered_qwen35_9b", "registered_qwen38_27b", "registered_qwen35_35b_a3b", "registered_qwen36_35b_a3b",
                                 "registered_ternary_bonsai_2_27b", "registered_nemotron35_lightning", "registered_mimo_v26_flash_mopd",
                                 "registered_gpt_oss_20b", "registered_gemma4_26b_qat_4bit", "registered_glm53_flash"])
        // registered_gemma4_26b has no record of its own: the two that named it ran the 8-bit artifact and are not shipped.
        #expect(Set(ClusterPairServingGrants.withheld.keys) == ["registered_gemma4_26b_8bit"])
        let gpt = ClusterPairServingGrants.records(runtimeModelID: "registered_gpt_oss_20b")
        #expect(gpt.restrictsShapes && Set(gpt.failed.flatMap(\.cuts)) == [4, 8, 10])
    }

    /// MiMo's grant follows its records, family by family: the pipeline ran
    /// with the M5 Ultra leading and the M3 Ultra holding the last layers and
    /// the head (cuts 47 and 14, both framings; short, 4,096 and 16,384
    /// prompts against the M5 Ultra's own reference), and the phase split (a
    /// hand-off mode, off by default) at cut 8. No MiMo check failed, so its
    /// records restrict no shape; each family is granted on any Apple silicon,
    /// in either order, at any cut the planner chooses.
    @Test func mimoIsGrantedInTheFamiliesItsChecksRan() throws {
        let model = "registered_mimo_v26_flash_mopd"
        let grant = try ClusterPairServingGrants.grant(runtimeModelID: model, publicModelID: "p",
            artifactSHA256: "2334547d8acc9898ad4a74570ce44d2b12390bbac8d4bc52c092eb5ad5cfe034")
        #expect(grant.qualifiedChipClasses == [.appleM3Ultra, .appleM5Ultra])
        let shapes = Set(grant.qualifications.map { "\($0.chipClasses.map(\.rawValue)) \($0.cuts) \($0.mode.rawValue)" })
        for expected: ClusterPairServingQualification in [
            .init(chipClasses: [.appleM5Ultra, .appleM3Ultra], cuts: [14], mode: .pipeline),
            .init(chipClasses: [.appleM5Ultra, .appleM3Ultra], cuts: [47], mode: .pipeline),
            .init(chipClasses: [.appleM5Ultra, .appleM3Ultra], cuts: [47], mode: .pipelineCompactDecode),
            .init(chipClasses: [.appleM3Ultra, .appleM5Ultra], cuts: [8], mode: .phaseSplit)] {
            #expect(shapes.contains("\(expected.chipClasses.map(\.rawValue)) \(expected.cuts) \(expected.mode.rawValue)"))
        }
        // 17 before round 6f, plus the two pipeline_mtp_v1 records (pp-mtp-records: 4K and 1K at cut 47).
        #expect(grant.evidence.hasPrefix("19 passing cross-cable qualification records"))
        #expect(!ClusterPairServingGrants.records(runtimeModelID: model).restrictsShapes)
        let m4max = cls("Apple M4 Max")
        for order in [[ClusterChipClass.appleM5Ultra, .appleM3Ultra], [.appleM3Ultra, .appleM5Ultra], [.appleM5Ultra, .appleM5Max], [m4max, m4max]] {
            try ClusterPairServingGrants.requirePlacement(order, runtimeModelID: model, publicModelID: "p", cuts: [40], mode: .pipeline)
            try ClusterPairServingGrants.requirePlacement(order, runtimeModelID: model, publicModelID: "p", cuts: [8], mode: .phaseSplit)
        }
        // Another artifact under the same registered model is not what the records ran.
        let foreign = refusal { _ = try ClusterPairServingGrants.grant(runtimeModelID: model, publicModelID: "p", artifactSHA256: String(repeating: "0", count: 64)) }
        #expect(foreign?.reason == .artifactNotQualified(installed: String(repeating: "0", count: 64),
                                                         qualified: ["2334547d8acc9898ad4a74570ce44d2b12390bbac8d4bc52c092eb5ad5cfe034"]))
    }

    /// Every model a stage adapter runs is served for its owner, with time
    /// budgets derived from its setup and its artifact's size (no per-model
    /// row): GPT-OSS and Gemma 4 QAT4 included. The runtime's model, not the
    /// public name, selects the decision.
    @Test func everyRegisteredModelIsServedForItsOwnerWithDerivedBudgets() throws {
        let registered = Set(ClusterRuntimeAdapter.allCases.flatMap { $0.registeredProfiles.map(\.runtimeModelID) })
        #expect(registered.isSuperset(of: ["registered_gpt_oss_20b", "registered_gemma4_26b_qat_4bit"]))
        for model in registered {
            let owner = try ClusterPairServingGrants.ownerServing(runtimeModelID: model, publicModelID: "renamed/public-id")
            #expect(owner.runtimeModelID == model)
            let budgets = DistributedInstalledTimeBudgets.derived(requestTimeoutSeconds: 600, maximumPromptTokens: 8192,
                artifactBytes: 16_000_000_000, largestStageShare: 0.5, lastRankLoadsEverything: false).budgets
            #expect(budgets.startupAllowanceNanoseconds >= 90_000_000_000 && budgets.firstTokenMillisecondsPerPromptToken >= 1)
        }
        // Each served family is served in both orders on the bench pair and on Macs no check ran.
        for model in ["registered_qwen35_35b_a3b", "registered_qwen36_35b_a3b", "registered_ternary_bonsai_2_27b", "registered_nemotron35_lightning",
                      "registered_qwen35_9b", q27] {
            for order in [[ClusterChipClass.appleM3Ultra, .appleM5Ultra], [.appleM5Ultra, .appleM3Ultra], [cls("Apple M4 Max"), cls("Apple M4 Max")]] {
                try ClusterPairServingGrants.requirePlacement(order, runtimeModelID: model, publicModelID: "p", mode: .pipeline)
                try ClusterPairServingGrants.requirePlacement(order, runtimeModelID: model, publicModelID: "p", mode: .phaseSplit)
            }
        }
    }

    /// Each grant rests on placements in the shape of the coordinator's parity
    /// qualification (one chip class per rank in rank order, `cuts`, `mode`);
    /// its qualified classes are exactly the classes those placements ran
    /// (evidence in words, not a list of allowed chips).
    @Test func grantsRestOnWellFormedQualifications() throws {
        for grant in ClusterPairServingGrants.granted {
            #expect(!grant.qualifications.isEmpty, "\(grant.runtimeModelID)")
            for qualification in grant.qualifications {
                #expect(qualification.isWellFormed, "\(grant.runtimeModelID) \(qualification)")
            }
            let placements = grant.qualifications.map { "\($0.chipClasses.map(\.rawValue)) \($0.cuts) \($0.mode.rawValue)" }
            #expect(placements.count == Set(placements).count, "\(grant.runtimeModelID) lists one placement twice")
            #expect(grant.qualifiedChipClasses == Set(grant.qualifications.flatMap(\.chipClasses)))
        }
        let q27 = try ClusterPairServingGrants.grant(runtimeModelID: "registered_qwen38_27b", publicModelID: "p")
        #expect(q27.qualifications.contains(.init(chipClasses: [.appleM3Ultra, .appleM5Max], cuts: [16], mode: .phaseSplitMTP)))
        #expect(q27.qualifications.contains(.init(chipClasses: [.appleM5Max, .appleM3Ultra], cuts: [48], mode: .phaseSplit)))
        #expect(ClusterPairServingGrant(runtimeModelID: q27.runtimeModelID, qualifications: [], evidence: "").families.isEmpty)
        // The coordinator's shape rules for a placement.
        #expect(!ClusterPairServingQualification(chipClasses: [.appleM3Ultra], cuts: [], mode: .pipeline).isWellFormed)
        #expect(!ClusterPairServingQualification(chipClasses: [.appleM3Ultra, .appleM5Max], cuts: [16, 20], mode: .pipeline).isWellFormed)
        #expect(!ClusterPairServingQualification(chipClasses: [.appleM3Ultra, .appleM5Max], cuts: [0], mode: .pipeline).isWellFormed)
        #expect(!ClusterPairServingQualification(chipClasses: [.appleM3Ultra, .appleM5Max, .appleM5Max], cuts: [20, 16], mode: .pipeline).isWellFormed)
        #expect(ClusterPairServingQualification(chipClasses: [.appleM3Ultra, .appleM5Max, .appleM5Max], cuts: [16, 20], mode: .pipeline).isWellFormed)
        // Modes are spelled as the coordinator's plan modes (`pipeline_mtp_v1` needs the
        // coordinator's protocol.ClusterPlanModes to list it before a plan may name it).
        #expect(Set(ClusterGenerationMode.allCases.map(\.rawValue))
            == ["pipeline_v1", "pipeline_compact_decode_v1", "phase_split_v1", "phase_split_mtp_v1",
                "tensor_parallel_v1", "pipeline_prefill_tensor_decode_v1", "pipeline_mtp_v1"])
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
