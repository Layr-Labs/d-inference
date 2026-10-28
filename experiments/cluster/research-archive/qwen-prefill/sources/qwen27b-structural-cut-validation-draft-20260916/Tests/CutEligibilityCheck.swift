import Foundation
import DarkbloomClusterProtocol

private struct ModelInput: Decodable {
    let configuration, manifest: Data
    let canonicalTensors: [QwenDenseCanonicalTensor]
}
private struct Inputs: Decodable { let nine, twentySeven: ModelInput }

@main struct CutEligibilityCheck {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 1 else { throw ProbeError("Expected retained metadata input") }
        let (raw, inputSHA) = try readQualificationBytes(arguments[0], maximum: 4 * 1024 * 1024)
        let input = try JSONDecoder().decode(Inputs.self, from: raw)
        var accepted = [String](), rejected = [String]()
        func check(_ name: String, _ value: Bool) throws {
            guard value else { throw ProbeError("Cut check failed: " + name) }; accepted.append(name)
        }
        func refuse(_ name: String, _ body: () throws -> Void) throws {
            do { try body() } catch { rejected.append(name); return }
            throw ProbeError("Invalid cut input was accepted: " + name)
        }
        func profile(_ value: ModelInput, _ definition: QwenResidentModelDefinition?) throws -> QwenRegisteredDenseModelProfile {
            let spec: QwenDenseRegisteredSpecification
            if let definition { spec = definition.specification }
            else { spec = try QwenResidentModelDefinition(model: .qwen38TwentySevenB).specification }
            return try .admit(configuration: value.configuration, manifest: value.manifest,
                expectedArtifactAggregateSHA256: spec.artifactSHA256, canonicalTensors: value.canonicalTensors,
                residentDefinition: definition)
        }
        let definition = try QwenResidentModelDefinition(model: .qwen38TwentySevenB)
        let native = try profile(input.twentySeven, definition)
        let legacy = try profile(input.twentySeven, nil)
        let nineDefinition = try QwenResidentModelDefinition(model: .qwen35NineB)
        let nine = try profile(input.nine, nineDefinition)
        let legal = Array(stride(from: 4, through: 60, by: 4))
        try check("registered geometry is64 layers and interval4", native.geometry.layers == 64 && native.geometry.fullAttentionInterval == 4)
        try check("all15 structural cuts derive from registered geometry", definition.supportedCuts == legal)
        try check("ordinary9B cuts and planning fields unchanged", nineDefinition.supportedCuts == [4, 8, 12, 16] && nineDefinition.planningScopeFields.isEmpty)
        try check("ordinary9B profile identifier unchanged", try QwenResidentAdapterDefinition.profile(specification: nineDefinition.specification).identifier == QwenResidentAdapterDefinition.profileID)
        try refuse("ordinary profile remains27B-closed") { _ = try QwenResidentAdapterDefinition.profile(specification: definition.specification) }
        try refuse("legacy27B metadata scope does not silently expand") { _ = try legacy.makePlanningPlan(stageCut: 24) }
        try check("default legacy32Plan remains identical", try legacy.makePlanningPlan().fingerprint == native.makePlanningPlan(stageCut: 32).fingerprint)
        let page = 16_384
        func bound(_ bytes: Int) throws -> Int {
            guard bytes > 0, bytes < Int.max - 2 * page else { throw ProbeError("Fixture bound overflow") }
            let rounded = bytes > page ? ((bytes + page - 1) / page) * page : bytes
            return rounded + min(rounded - 1, 2 * page - 1)
        }
        for cut in legal {
            let plan = try native.makePlanningPlan(stageCut: cut)
            let pair = try QwenDenseStorageRequirement.derive(profile: native, plan: plan, role: .sequentialPair)
            try check("exact canonical conservation cut\(cut)", pair.selectedActiveBytes == 15_132_802_048 && pair.stages.map(\.canonicalCount).reduce(0, +) == 1847)
            try check("exact global and local layer coverage cut\(cut)", plan.stages.flatMap { $0.layers.map(\.globalIndex) } == Array(0..<64)
                && plan.stages.allSatisfy { $0.layers.map(\.localIndex) == Array(0..<$0.layers.count) })
            let local = try (0...1).map { rank in try QwenOwnedStageRequestBudget.derive(profile: native, plan: plan,
                rank: rank, maximumTokens: 8320, chunkSize: 512, bound: bound) }
            try check("prospective local-kind accounting cut\(cut)", local.map(\.attentionLayers).reduce(0, +) == 16
                && local.map(\.recurrentLayers).reduce(0, +) == 48 && local.allSatisfy { !$0.runtimeEnabled && $0.fullModelStateBytes == 1_628_012_333 })
            // Each local ledger retains its own host-snapshot and two boundary
            // arrays. Remove the second identical fixed term to recover the
            // unchanged full-model state formula exactly.
            let duplicate = try bound(34_078_720) + 2 * bound(10_485_760)
            try check("exact count/inverse accounting cut\(cut)", local.map(\.stateBytes).reduce(0, +) - duplicate == 1_628_012_333)
            if cut == 24 {
                try check("prospective24/40 exact weights", pair.stages.map(\.activeBytes) == [5_853_587_328, 9_279_214_720])
                try check("prospective24/40 exact tensor counts", pair.stages.map(\.canonicalCount) == [693, 1154])
                try check("prospective24/40 exact local state", local.map(\.stateBytes) == [644_972_463, 1_038_188_411])
            }
        }
        for cut in [Int.min, -4, 0, 1, 3, 5, 23, 25, 61, 63, 64, 68, Int.max] {
            try refuse("invalid native cut\(cut)") { _ = try native.makePlanningPlan(stageCut: cut) }
        }
        let plan = try native.makePlanningPlan(stageCut: 24)
        for (capacity, chunk) in [(0, 16), (8321, 512), (8320, 0), (8320, 513), (16, 32)] {
            try refuse("accounting bounds\(capacity)/\(chunk)") {
                _ = try QwenOwnedStageRequestBudget.derive(profile: native, plan: plan, rank: 0,
                    maximumTokens: capacity, chunkSize: chunk, bound: bound)
            }
        }
        for rank in [-1, 2] {
            try refuse("invalid accounting rank\(rank)") { _ = try QwenOwnedStageRequestBudget.derive(profile: native, plan: plan, rank: rank, maximumTokens: 8320, chunkSize: 512, bound: bound) }
        }
        try refuse("understated allocation bound") { _ = try QwenOwnedStageRequestBudget.derive(profile: native, plan: plan, rank: 0, maximumTokens: 8320, chunkSize: 512, bound: { $0 - 1 }) }
        try refuse("allocation arithmetic overflow") { _ = try QwenOwnedStageRequestBudget.derive(profile: native, plan: plan, rank: 0, maximumTokens: 8320, chunkSize: 512, bound: { _ in Int.max }) }
        try refuse("foreign profile/Plan accounting") { _ = try QwenOwnedStageRequestBudget.derive(profile: native, plan: nine.makePlanningPlan(), rank: 0, maximumTokens: 8320, chunkSize: 512, bound: bound) }
        try refuse("unsupported accounting model") { _ = try QwenOwnedStageRequestBudget.derive(profile: nine, plan: nine.makePlanningPlan(), rank: 0, maximumTokens: 8320, chunkSize: 512, bound: bound) }
        try refuse("active MTP remains closed") { _ = try QwenLayerStagePlan(configuration: input.twentySeven.configuration, ranges: [0..<24, 24..<64], activeMTP: true) }
        for key in ["num_hidden_layers", "full_attention_interval"] {
            var object = try JSONSerialization.jsonObject(with: input.twentySeven.configuration) as! [String: Any]
            var text = object["text_config"] as! [String: Any]; text[key] = 8; object["text_config"] = text
            let changed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try refuse("changed pinned geometry \(key)") { _ = try QwenRegisteredDenseModelProfile.admit(configuration: changed,
                manifest: input.twentySeven.manifest, expectedArtifactAggregateSHA256: definition.specification.artifactSHA256,
                canonicalTensors: input.twentySeven.canonicalTensors, residentDefinition: definition) }
        }
        try check("owner performs bounded syntax only", [1, 3, 24, 127].allSatisfy(Qwen27BQualificationScope.boundedCutSyntax)
            && [Int.min, 0, 128, Int.max].allSatisfy { !Qwen27BQualificationScope.boundedCutSyntax($0) })
        try qualificationEmit(["schema": "qwen27b_structural_cut_cpu_check_v1", "inputSHA256": inputSHA,
            "accepted": accepted, "rejected": rejected, "acceptedChecks": accepted.count, "rejectedChecks": rejected.count,
            "nativeModelExecuted": false, "perStageLedgerEnabled": false, "physicalQualification": false])
    }
}
