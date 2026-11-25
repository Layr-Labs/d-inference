import Foundation

/// Retained metadata only. The logical allocator values are not live grants.
func checkNativeModelProfiles(_ inputs: QwenDenseProfileFixtureInputs) throws -> [String: Any] {
    var accepted: [String] = [], rejected: [String] = []
    func check(_ name: String, _ value: Bool) throws {
        guard value else { throw QwenDenseProfileError("Native profile fixture failed: " + name) }
        accepted.append(name)
    }
    func refuse(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { rejected.append(name); return }
        throw QwenDenseProfileError("Native profile fixture accepted: " + name)
    }
    func profile(_ input: QwenDenseProfileFixtureInput, _ definition: QwenResidentModelDefinition,
                 scoped: Bool) throws -> QwenRegisteredDenseModelProfile {
        try .admit(configuration: input.configuration, manifest: input.manifest,
            expectedArtifactAggregateSHA256: definition.specification.artifactSHA256,
            canonicalTensors: input.canonicalTensors, residentDefinition: scoped ? definition : nil)
    }
    let nineDefinition = try QwenResidentModelDefinition(model: .qwen35NineB)
    let largeDefinition = try QwenResidentModelDefinition(model: .qwen38TwentySevenB)
    let nine = try profile(inputs.nine, nineDefinition, scoped: false)
    let residentNine = try profile(inputs.nine, nineDefinition, scoped: true)
    let large = try profile(inputs.twentySeven, largeDefinition, scoped: false)
    let residentLarge = try profile(inputs.twentySeven, largeDefinition, scoped: true)
    try check("9B metadata fingerprint unchanged", nine.fingerprint == residentNine.fingerprint)
    try check("27B extended scope has distinct fingerprint", large.fingerprint != residentLarge.fingerprint)
    try check("Closed model definitions", nineDefinition.supportedCuts == [4, 8, 12, 16]
        && largeDefinition.supportedCuts == [4, 8, 12, 16, 32]
        && nineDefinition.supportsLookahead && !largeDefinition.supportsLookahead)
    try check("Separate profile identifiers", nineDefinition.profileID == "registered_qwen35_9b_greedy_generation_v1"
        && largeDefinition.profileID == "registered_qwen38_27b_greedy_generation_v1")
    for cut in nineDefinition.supportedCuts {
        let original = try nine.makePlanningPlan(stageCut: cut)
        let selected = try residentNine.makePlanningPlan(stageCut: cut)
        try check("9B Plan unchanged at \(cut)", original.fingerprint == selected.fingerprint)
        for role in QwenDenseStorageRole.allCases {
            let a = try QwenDenseStorageRequirement.derive(profile: nine, plan: original, role: role)
            let b = try QwenDenseStorageRequirement.derive(profile: residentNine, plan: selected, role: role)
            try check("9B encoded storage unchanged \(cut) \(role.rawValue)",
                try QwenDenseProfileIdentity.encodedFingerprint(a) == QwenDenseProfileIdentity.encodedFingerprint(b))
        }
    }
    // Independently replayed from all 1,847 retained canonical tensor names.
    let expected: [Int: ([Int], [Int])] = [
        4: ([118, 1729], [1_571_565_888, 13_561_236_160]),
        8: ([233, 1614], [2_427_970_176, 12_704_831_872]),
        12: ([348, 1499], [3_284_374_464, 11_848_427_584]),
        16: ([463, 1384], [4_140_778_752, 10_992_023_296]),
        32: ([923, 924], [7_566_395_904, 7_566_406_144]),
    ]
    for cut in largeDefinition.supportedCuts {
        let selected = try residentLarge.makePlanningPlan(stageCut: cut)
        let requirement = try QwenDenseStorageRequirement.derive(profile: residentLarge,
            plan: selected, role: .sequentialPair)
        try check("27B exact partition \(cut)", selected.stages.map(\.sourceRange) == [0..<cut, cut..<64]
            && requirement.stages.map(\.canonicalCount) == expected[cut]!.0
            && requirement.stages.map(\.activeBytes) == expected[cut]!.1
            && requirement.selectedActiveBytes == 15_132_802_048
            && requirement.selectedInertBytes == 30_720)
        try check("27B exact interval phase \(cut)", selected.stages.allSatisfy { stage in
            stage.layers.allSatisfy { layer in
                layer.globalIndex == stage.sourceRange.lowerBound + layer.localIndex
                    && layer.kind == ((layer.localIndex + 1) % 4 == 0 ? "full_attention" : "linear_attention")
            }
        })
        try check("27B planning grants no execution \(cut)", !residentLarge.runtimeExecutionAuthorized
            && !residentLarge.providerEligibilityEstablished && !requirement.runtimeExecutionAuthorized
            && !requirement.actualLoadedInventoryEstablished)
    }
    for cut in [4, 8, 12, 16, 20, 28, 60] {
        try refuse("Default27B planning scope still refuses \(cut)") { _ = try large.makePlanningPlan(stageCut: cut) }
    }
    for cut in [-4, 0, 3, 5, 20, 28, 36, 60, 64, 68] {
        try refuse("Native27B planning scope refuses \(cut)") { _ = try residentLarge.makePlanningPlan(stageCut: cut) }
    }
    try refuse("Crossed definition/source") {
        _ = try QwenRegisteredDenseModelProfile.admit(configuration: inputs.twentySeven.configuration,
            manifest: inputs.twentySeven.manifest, expectedArtifactAggregateSHA256: largeDefinition.specification.artifactSHA256,
            canonicalTensors: inputs.twentySeven.canonicalTensors, residentDefinition: nineDefinition)
    }
    let resource = try QwenDenseRegisteredResourceProfile(profile: residentLarge)
    let maximum = try resource.namedStateBudget(maximumTokens: 8320, chunkSize: 512)
    try check("27B exact maximum named state", maximum.conservativeStateAndBoundaryBytes == 1_616_248_896)
    try check("27B exact payload ceiling", resource.maximumManifestPayloadBytes == 16_320_415_757)
    try refuse("27B8321 context") { _ = try resource.namedStateBudget(maximumTokens: 8321, chunkSize: 1) }
    try refuse("27B513 chunk") { _ = try resource.namedStateBudget(maximumTokens: 8320, chunkSize: 513) }
    return ["accepted": accepted, "rejected": rejected, "acceptedCount": accepted.count,
        "rejectedCount": rejected.count, "modelPayloadRead": false, "nativeExecuted": false]
}
