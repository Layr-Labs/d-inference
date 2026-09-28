import Foundation

struct QwenDenseProfileFixtureInput: Decodable {
    let configuration: Data, manifest: Data
    let canonicalTensors: [QwenDenseCanonicalTensor]
}
struct QwenDenseProfileFixtureInputs: Decodable {
    let nine: QwenDenseProfileFixtureInput
    let twentySeven: QwenDenseProfileFixtureInput
}
struct QwenDenseProfileCheckResult: Encodable {
    let kind = "qwen_registered_dense_profile_check", schemaVersion = 1
    let accepted: [String], rejected: [String]
    let acceptedChecks: Int, rejectedChecks: Int
    let metadataOnly = true, runtimeExecutionAuthorized = false
    let artifactPayloadRead = false, currentResourceObservationPerformed = false
    init(accepted: [String], rejected: [String]) {
        self.accepted = accepted; self.rejected = rejected
        self.acceptedChecks = accepted.count; self.rejectedChecks = rejected.count
    }
}

/// Caller supplies retained CPU fixture metadata. No file/environment/clock,
/// model/MLX or network operation occurs in this function. Positive reserve
/// examples are deliberately artificial and never qualify a device or permit.
func checkQwenRegisteredDenseProfiles(_ inputs: QwenDenseProfileFixtureInputs) throws -> QwenDenseProfileCheckResult {
    var accepted: [String] = [], rejected: [String] = []
    func require(_ name: String, _ value: Bool) throws {
        guard value else { throw QwenDenseProfileError("Profile fixture failed: " + name) }
        accepted.append(name)
    }
    func reject(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { rejected.append(name); return }
        throw QwenDenseProfileError("Profile fixture accepted invalid case: " + name)
    }
    let artifact9 = "127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b"
    let artifact27 = "bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463"
    func admit(_ input: QwenDenseProfileFixtureInput, artifact: String,
               tensors: [QwenDenseCanonicalTensor]? = nil, config: Data? = nil, manifest: Data? = nil)
        throws -> QwenRegisteredDenseModelProfile {
        try .admit(configuration: config ?? input.configuration, manifest: manifest ?? input.manifest,
            expectedArtifactAggregateSHA256: artifact, canonicalTensors: tensors ?? input.canonicalTensors)
    }
    let nine = try admit(inputs.nine, artifact: artifact9)
    let large = try admit(inputs.twentySeven, artifact: artifact27)
    let plan9 = try nine.makePlanningPlan(), plan27 = try large.makePlanningPlan()
    let full9 = try QwenDenseStorageRequirement.derive(profile: nine, plan: plan9, role: .fullReference)
    let full27 = try QwenDenseStorageRequirement.derive(profile: large, plan: plan27, role: .fullReference)
    let old = try QwenRegistered9BLongPrefillAdmission.admit(configuration: inputs.nine.configuration,
        expectedArtifactAggregateSHA256: artifact9, promptCount: 8192, chunkSize: 512, outputCount: 1,
        batchSize: 1, teacherTokenCount: 0, nativeDType: "bfloat16", bf16ConversionEnabled: true)
    let oldPlan = try QwenLongPrefillStageCut.makePlan(configuration: inputs.nine.configuration, stageCut: nil)
    try require("9B existing geometry and complete budget equality", full9.namedStateBudget == old.budget && nine.geometry == old.geometry)
    try require("9B exact existing default Plan", plan9.fingerprint == oldPlan.fingerprint && plan9.stages[0].sourceRange == 0..<16)
    try require("9B final logical state compatibility", full9.finalState.componentCount == 72 && full9.finalState.logicalBytes == 319_946_784)
    try require("27B full exact metadata", large.model == .qwen38TwentySevenB && large.geometry.layers == 64 &&
        large.canonicalTensors.count == 1847 && large.sourceTensorBytes == 15_132_802_048 && large.largestSourceTensorBytes == 635_699_200)
    try require("27B independent state term vector", [full27.namedStateBudget.convolutionBytesPerLayer,
        full27.namedStateBudget.ssmBytesPerLayer, full27.namedStateBudget.kvCapacityBytesPerAttentionLayer,
        full27.namedStateBudget.boundaryBytes, full27.namedStateBudget.threeRecurrentGenerationsBytes,
        full27.namedStateBudget.allKVCapacityAndOffsetsBytes, full27.namedStateBudget.largestSingleHostStateComponentBytes,
        full27.namedStateBudget.twoBoundaryArraysBytes, full27.namedStateBudget.conservativeStateAndBoundaryBytes] ==
        [122880, 3145728, 67117056, 10485760, 470679552, 1073872960, 33558528, 20971520, 1599082560])
    try require("27B independent final state", full27.finalState.componentCount == 144 && full27.finalState.logicalBytes == 690_815_040 &&
        full27.finalState.convolutionShape == [1, 3, 10240] && full27.finalState.ssmShape == [1, 48, 128, 128])
    try require("27B fusion replacement separate from state", full27.fusionReplacementBytes == 2_278_195_200 &&
        full27.partialNamedBufferLedgerBytes == 19_645_779_008 && !full27.isWholeProcessMemoryBound)
    try require("27B complete selected ownership", full27.stages.map(\.canonicalCount) == [923, 924] &&
        full27.stages.map(\.activeBytes) == [7_566_395_904, 7_566_406_144] && full27.stages.map(\.inertBytes) == [20_480, 10_240])
    for profile in [nine, large] {
        let plan = try profile.makePlanningPlan()
        try require(profile.model.rawValue + " raw metadata retained", profile.configuration == (profile.model == .qwen35NineB ? inputs.nine.configuration : inputs.twentySeven.configuration) &&
            profile.manifest == (profile.model == .qwen35NineB ? inputs.nine.manifest : inputs.twentySeven.manifest))
        try require(profile.model.rawValue + " no execution or payload permission", !profile.runtimeExecutionAuthorized &&
            !profile.actualPayloadVerificationEstablished && !profile.providerEligibilityEstablished)
        var identities = Set<String>()
        for role in QwenDenseStorageRole.allCases {
            let requirement = try QwenDenseStorageRequirement.derive(profile: profile, plan: plan, role: role)
            identities.insert(requirement.fingerprint)
            try require(profile.model.rawValue + " role " + role.rawValue, requirement.modelProfileFingerprint == profile.fingerprint &&
                requirement.planFingerprint == plan.fingerprint && requirement.partialNamedBufferLedgerBytes > requirement.selectedActiveBytes &&
                !requirement.runtimeExecutionAuthorized && !requirement.actualLoadedInventoryEstablished)
        }
        try require(profile.model.rawValue + " every role has distinct identity", identities.count == 5)
    }
    for role in [QwenDenseStorageRole.stage0, .stage1] {
        let requirement = try QwenDenseStorageRequirement.derive(profile: large, plan: plan27, role: role)
        try require("27B balanced per-process " + role.rawValue, requirement.partialNamedBufferLedgerBytes == 10_168_019_488 &&
            requirement.finalState.logicalBytes == 345_407_520 && requirement.finalState.componentCount == 72 &&
            requirement.namedStateBudget.conservativeStateAndBoundaryBytes == 826_806_304)
    }
    for cut in [4, 8, 12, 16, 20, 24, 28] {
        let plan = try nine.makePlanningPlan(stageCut: cut)
        let old = try QwenLongPrefillStageCut.makePlan(configuration: inputs.nine.configuration, stageCut: cut)
        let requirement = try QwenDenseStorageRequirement.derive(profile: nine, plan: plan, role: .sequentialPair)
        try require("9B selected cut unchanged " + String(cut), plan.fingerprint == old.fingerprint &&
            requirement.selectedActiveBytes == 5_038_041_600 && requirement.selectedInertBytes == 24_576)
    }
    for (label, input, artifact) in [("9B", inputs.nine, artifact9), ("27B", inputs.twentySeven, artifact27)] {
        let profile = try admit(input, artifact: artifact)
        try require(label + " unordered inventory deterministic", try admit(input, artifact: artifact,
            tensors: Array(input.canonicalTensors.reversed())).fingerprint == profile.fingerprint)
        try reject(label + " changed raw configuration bytes") { _ = try admit(input, artifact: artifact, config: input.configuration + Data([32])) }
        try reject(label + " changed raw manifest bytes") { _ = try admit(input, artifact: artifact, manifest: input.manifest + Data([32])) }
        var root = try JSONSerialization.jsonObject(with: input.configuration) as! [String: Any]
        var text = root["text_config"] as! [String: Any]; text["num_key_value_heads"] = 2; root["text_config"] = text
        let wrongGeometry = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        try reject(label + " changed declared geometry") { _ = try admit(input, artifact: artifact, config: wrongGeometry) }
        try reject(label + " wrong expected artifact") { _ = try admit(input, artifact: String(repeating: "0", count: 64)) }
        try reject(label + " missing canonical tensor") { _ = try admit(input, artifact: artifact, tensors: Array(input.canonicalTensors.dropLast())) }
        try reject(label + " duplicated canonical tensor") { _ = try admit(input, artifact: artifact, tensors: input.canonicalTensors + [input.canonicalTensors[0]]) }
        var changed = input.canonicalTensors
        let old = changed[0]
        changed[0] = .init(name: old.name + "_changed", shape: old.shape, sourceDType: old.sourceDType, byteCount: old.byteCount)
        try reject(label + " coherently sized wrong name") { _ = try admit(input, artifact: artifact, tensors: changed) }
        if let index = input.canonicalTensors.firstIndex(where: { $0.shape.count == 2 && $0.shape[0] != $0.shape[1] }) {
            changed = input.canonicalTensors; let old = changed[index]
            changed[index] = .init(name: old.name, shape: Array(old.shape.reversed()), sourceDType: old.sourceDType, byteCount: old.byteCount)
            try reject(label + " coherent same-byte wrong shape") { _ = try admit(input, artifact: artifact, tensors: changed) }
        } else { throw QwenDenseProfileError("Fixture lacks asymmetric shape") }
        changed = input.canonicalTensors
        changed[0] = .init(name: old.name, shape: old.shape, sourceDType: old.sourceDType == "BF16" ? "F16" : "U32", byteCount: old.byteCount)
        try reject(label + " coherent same-width wrong dtype") { _ = try admit(input, artifact: artifact, tensors: changed) }
    }
    try reject("9B config with27B manifest") { _ = try admit(inputs.nine, artifact: artifact9, manifest: inputs.twentySeven.manifest) }
    try reject("27B with9B canonical inventory") { _ = try admit(inputs.twentySeven, artifact: artifact27, tensors: inputs.nine.canonicalTensors) }
    try reject("oversized configuration") { _ = try admit(inputs.nine, artifact: artifact9, config: Data(repeating: 0, count: 1_048_577)) }
    for cut in [0, 3, 5, 31, 33, 64, Int.max] {
        try reject("27B invalid cut " + String(cut)) { _ = try large.makePlanningPlan(stageCut: cut) }
    }
    try reject("27B unqualified24/40 planning scope") { _ = try large.makePlanningPlan(stageCut: 24) }
    try reject("foreign model Plan") { _ = try QwenDenseStorageRequirement.derive(profile: large, plan: plan9, role: .stage0) }
    try reject("structural Plan cannot bypass selected scope") {
        let plan = try QwenLayerStagePlan(configuration: inputs.twentySeven.configuration, ranges: [0..<24, 24..<64])
        _ = try QwenDenseStorageRequirement.derive(profile: large, plan: plan, role: .stage1)
    }
    for tensor in [QwenDenseCanonicalTensor(name: "bad\nname", shape: [1], sourceDType: "BF16", byteCount: 2),
        .init(name: "valid", shape: [0], sourceDType: "BF16", byteCount: 0),
        .init(name: "valid", shape: [1], sourceDType: "BOOL", byteCount: 1),
        .init(name: "valid", shape: [Int(Int32.max), Int(Int32.max), 4], sourceDType: "F32", byteCount: 1)] {
        try reject("invalid tensor " + tensor.name + String(describing: tensor.shape)) { try tensor.validate() }
    }
    func planning(requirement: String? = nil, policy: String = String(repeating: "a", count: 64),
                  workspace: Int = 1, allocator: Int = 1, cpu: Int = 1, os: Int = 1, ceiling: Int = Int.max)
        throws -> QwenDenseResourcePlanningInput {
        try .init(policySHA256: policy, requirementFingerprint: requirement ?? full27.fingerprint,
            nativeWorkspaceReserveBytes: workspace, allocatorAndFrameworkReserveBytes: allocator,
            cpuMetadataAndEvidenceReserveBytes: cpu, operatingSystemReserveBytes: os, totalProcessPlanningCeilingBytes: ceiling)
    }
    let synthetic = try planning()
    let result = try QwenDenseResourcePlan.calculate(requirement: full27, input: synthetic)
    try require("positive reserve remains unverified non-permit", result.fitsCallerPlanningCeiling && !result.runtimeExecutionAuthorized &&
        !result.callerResourcePolicyProvenanceVerified && !result.currentOSOrRuntimeAdmissionPerformed && !synthetic.provenanceVerified)
    let insufficient = try QwenDenseResourcePlan.calculate(requirement: full27, input: planning(ceiling: 1))
    try require("insufficient planning ceiling reports refusal", !insufficient.fitsCallerPlanningCeiling && insufficient.unassignedPlanningHeadroomBytes == 0)
    try reject("resource planning wrong requirement identity") { _ = try QwenDenseResourcePlan.calculate(requirement: full27, input: planning(requirement: full9.fingerprint)) }
    try reject("resource planning full-to-stage role replay") {
        let stage = try QwenDenseStorageRequirement.derive(profile: large, plan: plan27, role: .stage0)
        _ = try QwenDenseResourcePlan.calculate(requirement: stage, input: planning())
    }
    for value in ["", "1", String(repeating: "A", count: 64), String(repeating: "x", count: 64)] {
        try reject("invalid policy identity " + value) { _ = try planning(policy: value) }
    }
    for value in [0, -1] {
        try reject("workspace reserve " + String(value)) { _ = try planning(workspace: value) }
        try reject("allocator reserve " + String(value)) { _ = try planning(allocator: value) }
        try reject("CPU reserve " + String(value)) { _ = try planning(cpu: value) }
        try reject("OS reserve " + String(value)) { _ = try planning(os: value) }
        try reject("total ceiling " + String(value)) { _ = try planning(ceiling: value) }
    }
    try reject("reserve addition overflow") { _ = try QwenDenseResourcePlan.calculate(requirement: full27, input: planning(workspace: Int.max)) }
    try reject("ledger plus reserve overflow") { _ = try QwenDenseResourcePlan.calculate(requirement: full27,
        input: planning(workspace: Int.max - 3)) }
    return .init(accepted: accepted, rejected: rejected)
}
