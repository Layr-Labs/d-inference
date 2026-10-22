import Foundation

func checkGemmaStagePlan(_ input: FixtureInputs, _ checks: FixtureChecks) throws {
    struct Table: Decodable {
        struct Cut: Decodable {
            let cut: Int
            let rankTensorCounts: [Int]
            let rankHeaderDerivedPayloadBytes: [Int]
            let rankSlidingLayerCounts: [Int]
            let rankFullLayerCounts: [Int]
        }
        let cuts: [Cut]
    }
    let expected = try JSONDecoder().decode(Table.self, from: FixtureInputs.read(input.root, "all-cuts.json"))
    try checks.require("all29 retained Python vectors present", expected.cuts.map(\.cut) == Array(1..<30))
    var fingerprints = Set<String>()
    for row in expected.cuts {
        let plan = try Gemma4LayerStagePlan(artifact: input.artifact, cut: row.cut)
        try checks.require("cut\(row.cut) counts and payload parity", plan.conservation.ranks.map(\.tensorCount) == row.rankTensorCounts
            && plan.conservation.ranks.map(\.logicalPayloadBytes) == row.rankHeaderDerivedPayloadBytes)
        try checks.require("cut\(row.cut) original geometry and complete layer coverage",
            plan.stages.flatMap(\.layers).map(\.globalIndex) == Array(0..<30)
            && plan.stages.flatMap(\.layers).map(\.kind) == input.artifact.text.layerKinds
            && plan.stages.allSatisfy { $0.globalLayerCount == 30 && $0.originalConfiguration == input.configuration })
        try checks.require("cut\(row.cut) attention phase parity",
            plan.stages.map { $0.layers.filter { $0.kind == .sliding }.count } == row.rankSlidingLayerCounts
            && plan.stages.map { $0.layers.filter { $0.kind == .full }.count } == row.rankFullLayerCounts)
        try checks.require("cut\(row.cut) exact replica conservation", plan.conservation.selectedSourceTensorCount == 1339
            && plan.conservation.destinationTensorCount == 1342 && plan.conservation.additionalReplicaBytes == 415_236_096
            && plan.conservation.destinationPayloadBytes == 14_882_924_604)
        try checks.require("cut\(row.cut) policy and final-layer responsibility",
            plan.stages.reduce(0) { $0 + $1.quantizationMappings.count } == 120
            && plan.stages[0].responsibility == .ingressResidual && plan.stages[1].responsibility == .finalLogits
            && plan.stages[0].finalPromptLayerGlobalIndex == nil && plan.stages[1].finalPromptLayerGlobalIndex == 29)
        try checks.require("cut\(row.cut) observed metadata matches sealed plan",
            try plan.validateStorage(mappings: Array(plan.mappings.reversed()), excludedSourceNames: input.artifact.excludedSourceNames) == plan.conservation)
        fingerprints.insert(plan.fingerprint)
    }
    try checks.require("distinct Plan identities for29 cuts", fingerprints.count == 29)
    let first = try Gemma4LayerStagePlan(artifact: input.artifact, cut: 1)
    try checks.require("nonperiod cut keeps full global5 at local4", first.stages[1].layers[4].globalIndex == 5
        && first.stages[1].layers[4].localIndex == 4 && first.stages[1].layers[4].kind == .full)
    let mapping = first.stages[1].quantizationMappings.first { $0.sourcePath == "language_model.model.layers.5.router.proj" }
    try checks.require("quantization relocates independently of full config", mapping?.localPath == "language_model.model.layers.4.router.proj"
        && mapping?.policy.bits == 8 && mapping?.policy.groupSize == 64)
    let plan15 = try Gemma4LayerStagePlan(artifact: input.artifact, cut: 15)
    let again = try Gemma4ArtifactMetadata.admit(configuration: input.configuration, manifest: input.manifest,
        index: input.index, headers: Array(input.headers.reversed()))
    try checks.require("header order cannot change Plan identity", try Gemma4LayerStagePlan(artifact: again, cut: 15).fingerprint == plan15.fingerprint)
    try checks.require("no execution or payload claim", !input.artifact.actualPayloadVerificationEstablished
        && !input.artifact.runtimeExecutionAuthorized && !plan15.conservation.payloadVerificationEstablished
        && !plan15.conservation.actualAllocationEstablished && plan15.stages.allSatisfy { !$0.nativeExecutionAuthorized })
    try checkExactCut15(input, plan15, checks)
}

private func checkExactCut15(_ input: FixtureInputs, _ plan: Gemma4LayerStagePlan, _ checks: FixtureChecks) throws {
    struct Expected: Decodable {
        struct Destination: Decodable { let rank: Int, localName: String, role: String }
        let name: String, file: String, dtype: String
        let shape: [Int], relativeOffset: Int, bytes: Int
        let destinations: [Destination]
    }
    let rows = try JSONDecoder().decode([Expected].self, from: FixtureInputs.read(input.root, "gemma-cut15-projections.json"))
    let headerBytes = Dictionary(uniqueKeysWithValues: input.headers.map { ($0.sourceFile, $0.data.count) })
    try checks.require("cut15 exact full mapping vector count", rows.count == plan.mappings.count)
    for (expected, actual) in zip(rows, plan.mappings) {
        let targets = expected.destinations.map { item in
            [String(item.rank), item.localName, item.role == "exclusiveLayer" ? "layer" : item.role].joined(separator: "|")
        }
        let actualTargets = actual.destinations.map { [String($0.rank), $0.localName, $0.role.rawValue].joined(separator: "|") }
        guard actual.source.layout.canonicalName == expected.name, actual.source.sourceFile == expected.file,
              actual.source.sourceOffset == 8 + headerBytes[expected.file]! + expected.relativeOffset,
              actual.source.layout.shape == expected.shape, actual.source.layout.sourceDType == expected.dtype,
              actual.source.layout.byteCount == expected.bytes, actualTargets == targets else {
            throw ProbeError("Exact retained Python mapping differs at " + expected.name)
        }
    }
    try checks.require("all1339 cut15 source/layout/destination vectors match", true)
}
