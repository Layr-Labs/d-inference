import Foundation

/// CPU metadata checks only. No constructor, eval, model payload, or Collective.
public enum Gemma4ExpertMetadataChecks {
    public static func run(directory: String) throws -> Data {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        func data(_ name: String) throws -> Data {
            try BoundedProbeInput.data(root.appendingPathComponent(name), maximumBytes: 2_097_152)
        }
        let headers = try (1...3).map { index in
            let name = String(format: "model-%05d-of-00003.safetensors", index)
            return LayerStageCapturedTensorHeader(sourceFile: name, data: try data(name + ".header.json"))
        }
        let artifact = try Gemma4ArtifactMetadata.admit(configuration: data("config.json"),
            manifest: data("manifest.json"), index: data("model.safetensors.index.json"), headers: headers)
        let plan = try Gemma4LayerStagePlan(artifact: artifact, cut: 10)
        let original = try Gemma4ForwardSelection.make(plan: plan, target: .fullReference)
        var checks = 0
        func require(_ value: Bool) throws {
            guard value else { throw ProbeError("Gemma EP selected metadata control failed") }; checks += 1
        }
        func refuses(_ body: () throws -> Void) throws {
            do { try body() } catch { checks += 1; return }
            throw ProbeError("Gemma EP metadata control failed to refuse")
        }
        let maps = [[Array(0..<48), Array(48..<128)],
                    [(0..<128).filter { $0 % 3 == 0 }, (0..<128).filter { $0 % 3 != 0 }],
                    [Array(0..<32), Array(32..<128)]]
        var reports: [[String: Any]] = []
        for map in maps {
            for rank in 0..<2 {
                let partition = try Gemma4ExpertPartition(rank: rank, globalIDsByRank: map)
                let selected = try Gemma4ForwardSelection.make(plan: plan, target: .expertParallel(partition))
                try require(selected.count == 1339 && selected.map(\.localName) == original.map(\.localName))
                var bytes = 0, replicated = 0, expert = 0
                for (actual, before) in zip(selected, original) {
                    try require(actual.source == before.source && actual.localName == before.localName
                        && actual.sourceDType == before.sourceDType && actual.loadedDType == before.loadedDType)
                    if Gemma4ExpertSelection.expertNames.contains(actual.localName) {
                        try require(actual.selectedShape == [map[rank].count] + Array(before.selectedShape.dropFirst()))
                        try require(actual.selection == .axis(0, partition.ownership().expertRanges(rank: rank)))
                        expert += actual.selectedByteCount
                    } else {
                        try require(actual.selection == .all && actual.selectedShape == before.selectedShape
                            && actual.selectedByteCount == before.selectedByteCount)
                        replicated += actual.selectedByteCount
                    }
                    bytes += actual.selectedByteCount
                }
                try require(replicated == 1_621_321_788 && expert == map[rank].count * 30 * 3_345_408)
                let item = selected.first { Gemma4ExpertSelection.expertNames.contains($0.localName) }!
                var progress = Gemma4OrderedLoadProgress(expected: [item])
                let wrong = try Gemma4SelectedTensor(source: item.source, localName: item.localName)
                try refuses { try progress.begin(wrong) }
                try require(progress.failed && progress.completed == 0 && progress.pending == nil)
                let request = try Gemma4ForwardRequest.make(requestID: UUID(), tokens: Array(repeating: 0, count: 32),
                    chunkSize: 16, outputCount: 2, stopTokenIDs: [], observedResidualDType: .bfloat16)
                let budget = try Gemma4ShortResourceBudget.derive(plan: plan, target: .expertParallel(partition),
                    request: request, bound: { $0 })
                try require(budget.stateLayers.count == 30 && budget.expertResources != nil)
                try require(budget.selectedBounds.reduce(0,+) == bytes)
                reports.append(["rank":rank, "ownedExperts":map[rank].count, "selectedBytes":bytes,
                    "replicatedBytes":replicated, "expertBytes":expert, "partitionSHA256":partition.fingerprint])
            }
        }
        return try JSONSerialization.data(withJSONObject: ["schema":"gemma4_expert_metadata_checks_v1",
            "checks":checks, "ranks":reports, "modelConstructed":false, "payloadRead":false,
            "nativeExecutionAuthorized":false], options:[.sortedKeys])
    }
}
