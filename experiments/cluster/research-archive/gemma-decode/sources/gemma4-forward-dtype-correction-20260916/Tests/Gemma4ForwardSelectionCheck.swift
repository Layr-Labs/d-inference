import Foundation

func checkGemmaForwardSelection(_ input: FixtureInputs, _ checks: FixtureChecks) throws {
    let sources = Dictionary(uniqueKeysWithValues: input.artifact.sources.map { ($0.layout.canonicalName, $0) })
    let excluded = Set(input.artifact.excludedSourceNames)
    let expectedText = Set(sources.keys).subtracting(excluded)
    let prefix = "language_model.model."
    let embedding = Set(["weight", "scales", "biases"].map { prefix + "embed_tokens." + $0 })
    let norm = prefix + "norm.weight"
    var fullIdentity: String?
    for cut in 1..<30 {
        let plan = try Gemma4LayerStagePlan(artifact: input.artifact, cut: cut)
        let full = try Gemma4ForwardSelection.make(plan: plan, target: .fullReference)
        let stages = try (0...1).map { try Gemma4ForwardSelection.make(plan: plan, target: .stage($0)) }
        let names = Set(full.map(\.localName))
        let rankNames = stages.map { Set($0.map { $0.source.layout.canonicalName }) }
        try checks.require("forward cut\(cut) full text and excluded coverage", names == expectedText
            && full.count == 1339 && names.isDisjoint(with: excluded)
            && full.allSatisfy { $0.localName == $0.source.layout.canonicalName })
        try checks.require("forward cut\(cut) exact whole tensor conservation",
            full.reduce(0) { $0 + $1.source.layout.byteCount } == 14_467_688_508
            && rankNames[0].union(rankNames[1]) == names
            && rankNames[0].intersection(rankNames[1]) == embedding)
        for rank in 0...1 {
            let selected = stages[rank]
            let descriptor = plan.stages[rank]
            let ledger = plan.conservation.ranks[rank]
            try checks.require("forward cut\(cut) rank\(rank) count and bytes",
                selected.count == ledger.tensorCount
                && selected.reduce(0) { $0 + $1.source.layout.byteCount } == ledger.logicalPayloadBytes
                && selected.map(\.localName) == selected.map(\.localName).sorted()
                && Set(selected.map(\.localName)).count == selected.count)
            // Compare actual source descriptors, not only totals. Packed expert
            // dimensions and offsets must remain the whole original tensor.
            for item in selected {
                guard sources[item.source.layout.canonicalName] == item.source,
                      item.sourceDType == ["BF16": "bfloat16", "U32": "uint32"][item.source.layout.sourceDType],
                      item.loadedDType == ["BF16": "bfloat16", "U32": "uint32"][item.source.layout.sourceDType]
                else { throw ProbeError("Forward selection changed source layout/dtype") }
                if let layer = Gemma4StageConstructionDescriptor.layerPath(item.source.layout.canonicalName) {
                    guard descriptor.sourceLayerRange.contains(layer.index),
                          item.localName == prefix + "layers.\(layer.index - descriptor.sourceLayerStart)." + layer.suffix
                    else { throw ProbeError("Forward selection lost the global/local layer join") }
                } else {
                    guard embedding.contains(item.localName) || (rank == 1 && item.localName == norm)
                    else { throw ProbeError("Forward selection changed non-layer ownership") }
                }
            }
        }
        try checks.require("forward cut\(cut) replica and head ownership",
            stages.flatMap { $0 }.count == 1342
            && stages.flatMap { $0 }.reduce(0) { $0 + $1.source.layout.byteCount } == 14_882_924_604
            && !rankNames[0].contains(norm) && rankNames[1].contains(norm))
        let identity = sha256(Data(full.map { "\($0.localName)|\($0.loadedDType)|\($0.source.sourceFile)|\($0.source.sourceOffset)|\($0.source.layout.shape)" }.joined(separator: "\n").utf8))
        if let fullIdentity { try checks.require("forward cut\(cut) full reference independent of split", identity == fullIdentity) }
        else { fullIdentity = identity }
        for invalidRank in [-1, 2, Int.max] {
            try checks.refuses("forward cut\(cut) rejects rank\(invalidRank)") {
                _ = try Gemma4ForwardSelection.make(plan: plan, target: .stage(invalidRank))
            }
        }
    }
}
