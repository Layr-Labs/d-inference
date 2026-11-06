import CryptoKit
import Foundation
import Testing
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
@testable import ProviderCore

/// Qwen3.8 27B's resident assistant on a coordinator-formed pair, once a build declares it public
/// (`ClusterPublicModels.tensorAssistant`): the declaration, the setup's own checks beside a cluster approval, the
/// resource policy that release facts, the approval and each committed start carry, and the guided setup's planning
/// under `auto`. This build declares Qwen3.8-27B's; each test declares one for the fixture's artifact
/// (`ClusterPublicModels.declarationOverride`), never a product path.
@Suite("Public Qwen tensor assistant", .serialized)
struct ClusterPublicTensorAssistantTests {
    static let report = "docs/reports/2026-11-01-qwen27-public-assistant.md"
    static let qualifiedAt = "2026-11-05T00:00:00Z"

    static func policy(depth: Int = 3, inventory: Character = "8",
                       verification: ClusterQwenTensorAssistantPolicy.Verification = .singleton) throws -> ClusterQwenTensorAssistantPolicy {
        try ClusterQwenTensorAssistantPolicy(depth: depth, inventorySHA256: ClusterApprovalMacs.hash(inventory), verification: verification)
    }

    /// This build's declaration with the fixture's Qwen3.8 27B artifact (`ClusterApprovalMacs.capability`) declared
    /// in both families, carrying `assistant`.
    static func declaration(_ assistant: ClusterQwenTensorAssistantPolicy?, artifact: Character = "b") throws -> [ClusterPublicModel] {
        var model = ClusterPublicModel(runtimeModelID: ClusterQwenTensorAssistantPolicy.runtimeModelID, catalogModelID: ClusterApprovalMacs.model,
            artifactSHA256: ClusterApprovalMacs.hash(artifact), families: [.pipeline, .tensorParallel], schedules: [1, 2],
            ranks: ClusterPublicModels.twoM5Ultras)
        model.tensorAssistant = try assistant.map {
            try ClusterPublicTensorAssistant(policy: $0, evidenceDocument: report, evidenceSHA256: ClusterApprovalMacs.hash("d"), qualifiedAt: Self.qualifiedAt)
        }
        return [model]
    }

    /// The facts both installations have and the approval a coordinator derives from them, with the resource policy
    /// of the fixture's capability as this build computes it under the current declaration.
    static func factsAndApproval(_ macs: ClusterApprovalMacs) throws -> (ClusterRuntimeApprovalFacts, ClusterRuntimeApproval) {
        let policy = NativePairMemberPolicy.hex(DistributedInstalledNativeStart.resourcePolicySHA256(macs.capability))
        let base = try macs.facts(), entry = base.models[0], template = macs.approval()
        let facts = try ClusterRuntimeApprovalFacts(nativeRuntimeSHA256: base.nativeRuntimeSHA256, metallibSHA256: base.metallibSHA256,
            resourceLibrarySHA256: base.resourceLibrarySHA256, placementPolicySHA256: base.placementPolicySHA256,
            models: [.init(model: entry.model, artifactSHA256: entry.artifactSHA256, capabilitySHA256: entry.capabilitySHA256,
                           profileSHA256: entry.profileSHA256, resourcePolicySHA256: policy)])
        let approval = ClusterRuntimeApproval(id: template.id, model: template.model, generation: template.generation,
            placementPolicySHA256: template.placementPolicySHA256, artifactSHA256: template.artifactSHA256,
            nativeRuntimeSHA256: template.nativeRuntimeSHA256, metallibSHA256: template.metallibSHA256,
            resourceLibrarySHA256: template.resourceLibrarySHA256, capabilitySHA256: template.capabilitySHA256,
            resourcePolicySHA256: policy, profileSHA256: template.profileSHA256, schedule: template.schedule,
            maximumTransportFrame: template.maximumTransportFrame, maximumPlaintext: template.maximumPlaintext,
            maximumRecords: template.maximumRecords, maximumCumulativePlaintext: template.maximumCumulativePlaintext,
            allowedNumericsClasses: template.allowedNumericsClasses, minimumMembers: template.minimumMembers,
            maximumMembers: template.maximumMembers, minimumMemberUsableBytes: template.minimumMemberUsableBytes,
            notAfter: template.notAfter)
        return (facts, approval)
    }

    /// Either verification may be declared (the local automatic policy verifies admitted cohorts); the report must be a
    /// Markdown record with its digest and an RFC 3339 qualification instant.
    @Test func aDeclarationNamesItsPolicyReportAndQualificationInstant() throws {
        let singleton = try Self.policy()
        let declared = try ClusterPublicTensorAssistant(policy: singleton, evidenceDocument: Self.report, evidenceSHA256: ClusterApprovalMacs.hash("d"), qualifiedAt: Self.qualifiedAt)
        #expect(declared.resourcePolicyFields == ["qwen27_tensor_assistant_v1", "depth=3",
            "--tp-mtp-inventory-sha256=" + ClusterApprovalMacs.hash("8"), "verification=singleton_ready_set_v1",
            "evidence=" + ClusterApprovalMacs.hash("d")])
        let cohort = try ClusterPublicTensorAssistant(policy: try Self.policy(verification: .admittedCohort), evidenceDocument: Self.report,
            evidenceSHA256: ClusterApprovalMacs.hash("d"), qualifiedAt: Self.qualifiedAt)
        #expect(cohort.resourcePolicyFields[3] == "verification=admitted_target_cohort_v1")
        for (document, digest, instant) in [("mainnet/qwen27.md", ClusterApprovalMacs.hash("d"), Self.qualifiedAt),
                                            ("docs/reports/a.txt", ClusterApprovalMacs.hash("d"), Self.qualifiedAt),
                                            (Self.report, "not-a-digest", Self.qualifiedAt),
                                            (Self.report, ClusterApprovalMacs.hash("d"), "2026-11-05")] {
            #expect(throws: (any Error).self) {
                try ClusterPublicTensorAssistant(policy: singleton, evidenceDocument: document, evidenceSHA256: digest, qualifiedAt: instant)
            }
        }
    }

    /// A release's facts: the model's serial-schedule tensor-parallel qualification rests on the declared assistant's
    /// report and instant; its one-chunk-lookahead one (the assistant needs serial prefill, so those pairs decode plain)
    /// and its pipeline ones on the model declaration's; without an assistant every one rests on the latter.
    @Test func theTensorParallelQualificationsRestOnTheAssistantsEvidence() throws {
        func qualifications(_ assistant: ClusterQwenTensorAssistantPolicy?) throws -> [ClusterRuntimeApprovalFacts.ParityQualification] {
            ClusterRuntimeApprovalFacts.parityQualifications(try Self.declaration(assistant)[0], metallibSHA256: ClusterApprovalMacs.hash("9"),
                inputModalities: ["text"], layers: 64, servesMedia: { _ in false })
        }
        let assisted = try qualifications(try Self.policy(verification: .admittedCohort)), plain = try qualifications(nil)
        #expect(assisted.map(\.mode) == [.pipeline, .pipeline, .tensorParallel, .tensorParallel])
        for (with, without) in zip(assisted, plain) {
            if with.mode == .tensorParallel && with.schedule == 1 {
                #expect(with.evidenceSHA256 == ClusterApprovalMacs.hash("d") && with.qualifiedAt == Self.qualifiedAt)
            } else {
                #expect(with == without)
            }
            #expect(without.evidenceSHA256 == ClusterPublicModels.evidenceSHA256 && without.qualifiedAt == ClusterPublicModels.qualifiedAt)
            #expect(with.requestEnvelope == without.requestEnvelope && with.cuts == without.cuts && with.schedule == without.schedule)
        }
        try ClusterRuntimeApprovalFacts.validate(assisted, of: ClusterApprovalMacs.model)
    }

    /// The lookup a setup's checks, its planning and every resource policy use: the declared model's artifact, in
    /// tensor parallel, else nothing. This build declares only Qwen3.8-27B's.
    @Test func theDeclaredAssistantBelongsToItsArtifactAndTensorParallel() throws {
        let declared = try Self.declaration(try Self.policy())
        let model = ClusterQwenTensorAssistantPolicy.runtimeModelID
        #expect(ClusterPublicModels.tensorAssistant(runtimeModelID: model, artifactSHA256: ClusterApprovalMacs.hash("b"), in: declared)?.policy
                == (try Self.policy()))
        #expect(ClusterPublicModels.tensorAssistant(runtimeModelID: model, artifactSHA256: ClusterApprovalMacs.hash("c"), in: declared) == nil)
        #expect(ClusterPublicModels.tensorAssistant(runtimeModelID: "registered_qwen35_9b", artifactSHA256: ClusterApprovalMacs.hash("b"),
                                                    in: declared) == nil)
        var pipelineOnly = declared
        pipelineOnly[0] = ClusterPublicModel(runtimeModelID: model, catalogModelID: ClusterApprovalMacs.model,
            artifactSHA256: ClusterApprovalMacs.hash("b"), families: [.pipeline], schedules: [1, 2], ranks: ClusterPublicModels.twoM5Ultras,
            tensorAssistant: declared[0].tensorAssistant)
        #expect(ClusterPublicModels.tensorAssistant(runtimeModelID: model, artifactSHA256: ClusterApprovalMacs.hash("b"), in: pipelineOnly) == nil)
        #expect(ClusterPublicModels.declared.filter { $0.tensorAssistant != nil }.map(\.runtimeModelID) == [model],
                "only Qwen3.8-27B declares an assistant, with its evidence")
        #expect(ClusterPublicModels.current == ClusterPublicModels.declared)
    }

    /// This build serves Qwen3.8-27B's assistant on pairs served through Darkbloom: the exact policy local clusters
    /// plan by themselves, with the registered artifact's head inventory, planned under `auto`, and its report is the
    /// evidence of the model's tensor-parallel parity qualifications. Before the declaration, a cluster served through
    /// Darkbloom planned no assistant and refused one.
    @Test func thisBuildDeclaresQwensAssistantForPairsServedThroughDarkbloom() throws {
        let artifact = "bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463"
        let declared = try #require(ClusterPublicModels.tensorAssistant(runtimeModelID: ClusterQwenTensorAssistantPolicy.runtimeModelID,
                                                                         artifactSHA256: artifact, in: ClusterPublicModels.declared))
        #expect(declared.policy == (try ClusterQwenTensorAssistantPolicy(depth: ClusterPlacementTensorAssistantSelection.automaticDepth,
            inventorySHA256: "6bf428caf645e41cfda642108fc9a21d199ca999e80907be7476e87026afb014", verification: .admittedCohort)))
        #expect(declared.evidenceDocument == "docs/reports/2026-11-05-qwen27-public-assistant.md")
        #expect(ClusterPlacementTensorAssistantSelection.discoveryMode(.auto, coordinator: true, declared: true) == .auto)
        let model = try #require(ClusterPublicModels.declared.first { $0.runtimeModelID == ClusterQwenTensorAssistantPolicy.runtimeModelID })
        let qualifications = ClusterRuntimeApprovalFacts.parityQualifications(model, metallibSHA256: ClusterApprovalMacs.hash("9"),
            inputModalities: ["text", "image"], layers: 64, servesMedia: { $0 == .tensorParallel })
        #expect(qualifications.filter { $0.mode == .tensorParallel }.map(\.evidenceSHA256)
                == [declared.evidenceSHA256, ClusterPublicModels.evidenceSHA256], "serial: the assistant's; one-chunk lookahead: plain")
        #expect(qualifications.filter { $0.mode == .pipeline }.allSatisfy { $0.evidenceSHA256 == ClusterPublicModels.evidenceSHA256 })
        // The envelope is the plain tensor-parallel one: logprobs, penalties, bias and media rows decode on the target path.
        #expect(qualifications.filter { $0.mode == .tensorParallel }.allSatisfy { $0.requestEnvelope.sampling && $0.requestEnvelope.tools
            && $0.requestEnvelope.vision })
    }

    /// The plan's public-traffic line: a tensor-parallel placement that decodes with the assistant is offered only
    /// for an artifact whose assistant this build declares.
    @Test func aPlanWithTheDeclaredAssistantSaysItIsQualifiedForPublicTraffic() throws {
        func line(_ models: [ClusterPublicModel], assistant: Bool) -> String {
            ClusterPairServingGrants.publicTrafficLine(runtimeModelID: ClusterQwenTensorAssistantPolicy.runtimeModelID,
                artifactSHA256: ClusterApprovalMacs.hash("b"), mode: .tensorParallel, tensorAssistant: assistant, publicModels: models)
        }
        let declared = try Self.declaration(try Self.policy()), undeclared = try Self.declaration(nil)
        #expect(line(declared, assistant: true).hasPrefix("qualified for public traffic in tensor parallel mode"), "\(line(declared, assistant: true))")
        #expect(line(undeclared, assistant: true) == ClusterPairOwnerServing.tensorAssistantNotOffered)
        #expect(line(undeclared, assistant: false) == line(declared, assistant: false))
    }

    /// Every assistant this build declares rests on a report whose SHA-256 the declaration names, as the model
    /// declaration's own does.
    @Test func everyDeclaredAssistantNamesItsReportsDigest() throws {
        var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while repository.lastPathComponent != "provider-swift", repository.path != "/" { repository.deleteLastPathComponent() }
        repository.deleteLastPathComponent()
        for assistant in ClusterPublicModels.declared.compactMap(\.tensorAssistant) {
            let report = try Data(contentsOf: repository.appendingPathComponent(assistant.evidenceDocument))
            #expect(assistant.evidenceSHA256 == SHA256.hash(data: report).map { String(format: "%02x", $0) }.joined(),
                    "\(assistant.evidenceDocument)")
        }
    }

    /// The resource policy is unchanged without a declaration (so every existing approval keeps its digest) and
    /// carries the declared assistant's launch arguments with one: each of depth, inventory and verification changes it.
    @Test func theResourcePolicyCarriesTheDeclaredAssistant() throws {
        let capability = try ClusterApprovalMacs.capability(runtime: ClusterApprovalMacs.hash("a"),
            shape: .qwen27TensorParallel(assistant: nil))
        func digest(_ fields: [String]) -> Data { Data(SHA256.hash(data: Data(fields.joined(separator: "\u{1F}").utf8))) }
        let legacy = digest(["darkbloom/installed-resource-policy/v1", capability.arithmeticPolicyID,
            capability.arithmeticPolicySHA256, capability.stateSemantics, capability.schedulingPolicy])
        #expect(DistributedInstalledNativeStart.resourcePolicySHA256(capability) == legacy)
        let declared = try ClusterPublicTensorAssistant(policy: try Self.policy(), evidenceDocument: Self.report,
                                                        evidenceSHA256: ClusterApprovalMacs.hash("d"), qualifiedAt: Self.qualifiedAt)
        let assisted = DistributedInstalledNativeStart.resourcePolicySHA256(capability, assistant: declared)
        #expect(assisted == digest(["darkbloom/installed-resource-policy/v1", capability.arithmeticPolicyID,
            capability.arithmeticPolicySHA256, capability.stateSemantics, capability.schedulingPolicy] + declared.resourcePolicyFields))
        #expect(assisted != legacy)
        try ClusterPublicModels.$declarationOverride.withValue(try Self.declaration(try Self.policy())) {
            #expect(DistributedInstalledNativeStart.resourcePolicySHA256(capability) == assisted)
        }
        var variants: Set<Data> = [legacy, assisted]
        for other in [try Self.policy(depth: 2), try Self.policy(inventory: "9")] {
            variants.insert(DistributedInstalledNativeStart.resourcePolicySHA256(capability, assistant:
                try ClusterPublicTensorAssistant(policy: other, evidenceDocument: Self.report, evidenceSHA256: ClusterApprovalMacs.hash("d"), qualifiedAt: Self.qualifiedAt)))
        }
        variants.insert(DistributedInstalledNativeStart.resourcePolicySHA256(capability, assistant:
            try ClusterPublicTensorAssistant(policy: try Self.policy(), evidenceDocument: Self.report, evidenceSHA256: ClusterApprovalMacs.hash("e"), qualifiedAt: Self.qualifiedAt)))
        #expect(variants.count == 5)
    }

    /// With the declaration, the whole coordinator path admits the declared assistant: both Macs save the approval
    /// beside it (each Mac's own check), and the plan's committed start and its runtime block (a model approval's)
    /// carry the resource policy the release facts name. An assistant other than the declared one is refused.
    @Test func onceDeclaredTheApprovalIsSavedBesideTheAssistantOnBothMacs() throws {
        let declared = try Self.policy()
        try ClusterPublicModels.$declarationOverride.withValue(try Self.declaration(declared)) {
            let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider",
                                               shape: .qwen27TensorParallel(assistant: declared))
            let (facts, approval) = try Self.factsAndApproval(macs)
            let result = macs.sync(.approvals([approval]), leaderFacts: facts, followerFacts: facts)
            #expect(result == .init(changed: true, line: ClusterApprovalLifetime.offeredLine(approval), note: .some(nil)))
            for mac in macs.macs {
                let saved = try macs.saved(mac)
                #expect(saved.configuration.nativeMember?.clusterApproval == approval, "rank \(mac.rank) saved no approval")
                #expect(saved.configuration.tensorAssistant == declared, "rank \(mac.rank)")
                let plan = try DistributedInstalledPlan(saved: saved, paths: mac.paths)
                let start = try DistributedInstalledNativeStart.common(plan: plan, epoch: UUID())
                guard case .servingV1(let serving) = start.permission else { Issue.record("not a serving start"); continue }
                #expect(NativePairMemberPolicy.hex(serving.resourcePolicySHA256) == approval.resourcePolicySHA256)
                #expect(DistributedInstalledNativeStart.runtimeBlock(plan: plan).resourcePolicySHA256 == approval.resourcePolicySHA256)
                // The workers are launched with the declared assistant's arguments.
                let arguments = try DistributedInstalledGenerationSelection.workerArguments(configuration: saved.configuration,
                                                                                         capability: saved.capability)
                #expect(arguments.suffix(4) == ["--mtp-depth", "3", ClusterQwenTensorAssistantPolicy.inventoryArgument,
                                                ClusterApprovalMacs.hash("8")])
                #expect(DistributedInstalledSpeculation(configuration: saved.configuration, capability: saved.capability)
                        == .init(enabled: true, offReason: DistributedInstalledSpeculation.enabledReason))
                // Its speed records say it served through Darkbloom with the assistant (`ClusterServedSpeedRecords.Setup.servedAs`).
                let facts = plan.observabilityFacts(membershipEpoch: nil)
                #expect(facts.serving == .darkbloom && facts.tensorAssistant == true)
            }
            // The release facts of the build that declared nothing name another resource policy: refused unchanged.
            let undeclared = try ClusterPublicModels.$declarationOverride.withValue(try Self.declaration(nil)) {
                try Self.factsAndApproval(macs)
            }
            #expect(undeclared.1.resourcePolicySHA256 != approval.resourcePolicySHA256)
        }
    }

    @Test func anAssistantOtherThanTheDeclaredOneIsRefusedBesideAnApproval() throws {
        for (setup, declaredAssistant, artifact) in [
            (try Self.policy(depth: 2), try Self.policy(), Character("b")),
            (try Self.policy(inventory: "9"), try Self.policy(), Character("b")),
            (try Self.policy(verification: .admittedCohort), try Self.policy(), Character("b")),
            (try Self.policy(), try Self.policy(), Character("c")),
        ] {
            try ClusterPublicModels.$declarationOverride.withValue(try Self.declaration(declaredAssistant, artifact: artifact)) {
                let macs = try ClusterApprovalMacs(coordinatorURL: "ws://127.0.0.1:9/ws/provider",
                                                   shape: .qwen27TensorParallel(assistant: setup))
                let (facts, approval) = try Self.factsAndApproval(macs)
                let before = try macs.macs.map(macs.bytes)
                let result = macs.sync(.approvals([approval]), leaderFacts: facts, followerFacts: facts)
                #expect(!result.changed && result.line?.hasPrefix(ClusterApprovalTensorAssistantTests.refusedHere) == true
                    && result.line?.hasSuffix(ClusterConfiguration.tensorAssistantServesLocally) == true, "\(result.line ?? "")")
                #expect(try macs.macs.map(macs.bytes) == before)
            }
        }
    }
}
