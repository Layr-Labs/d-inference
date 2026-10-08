import Foundation

/// Two-rank text partition over an exact header profile, with no native capability.
struct Gemma4LayerStagePlan {
    let artifact: Gemma4ArtifactMetadata
    let stages: [Gemma4StageConstructionDescriptor]
    let mappings: [LayerStageTensorMapping]
    let replication: [LayerStageTiedEmbeddingReplication]
    let conservation: LayerStageStorageConservation
    let fingerprint: String

    init(artifact: Gemma4ArtifactMetadata, cut: Int) throws {
        guard (1..<artifact.text.globalLayerCount).contains(cut) else { throw ProbeError("Gemma cut must be in 1..<30") }
        let stages = try [
            Gemma4StageConstructionDescriptor(artifact: artifact, rank: 0, sourceLayerRange: 0..<cut),
            Gemma4StageConstructionDescriptor(artifact: artifact, rank: 1, sourceLayerRange: cut..<30),
        ]
        let embedding = Gemma4TensorInventory.prefix + "embed_tokens"
        let group = LayerStageTiedEmbeddingReplication(id: "gemma4-source-tied-embedding-v1",
            canonicalModule: embedding, sourceNames: ["biases", "scales", "weight"].map { embedding + "." + $0 },
            ingressRank: 0, outputRank: 1)
        let excluded = Set(artifact.excludedSourceNames)
        let mappings = try artifact.sources.filter { !excluded.contains($0.layout.canonicalName) }.map { source in
            let name = source.layout.canonicalName
            if group.sourceNames.contains(name) {
                return LayerStageTensorMapping(source: source, destinations: [
                    .init(rank: 0, localName: name, role: .ingressEmbedding, globalLayerIndex: nil),
                    .init(rank: 1, localName: name, role: .tiedOutputEmbedding, globalLayerIndex: nil),
                ], replicationGroupID: group.id)
            }
            if name == Gemma4TensorInventory.prefix + "norm.weight" {
                return LayerStageTensorMapping(source: source,
                    destinations: [.init(rank: 1, localName: name, role: .finalNorm, globalLayerIndex: nil)], replicationGroupID: nil)
            }
            guard let location = Gemma4StageConstructionDescriptor.layerPath(name) else {
                throw ProbeError("Unowned Gemma canonical tensor")
            }
            let rank = location.index < cut ? 0 : 1
            let stage = stages[rank]
            let local = Gemma4TensorInventory.prefix + "layers.\(location.index - stage.sourceLayerStart)." + location.suffix
            return LayerStageTensorMapping(source: source,
                destinations: [.init(rank: rank, localName: local, role: .layer, globalLayerIndex: location.index)], replicationGroupID: nil)
        }
        let conservation = try LayerStageStorageConservation.validate(sources: artifact.sources,
            mappings: mappings, excludedSourceNames: artifact.excludedSourceNames, allowedReplication: [group])
        guard conservation.selectedSourceTensorCount == 1339, conservation.destinationTensorCount == 1342,
              conservation.additionalReplicaBytes == 415_236_096,
              conservation.selectedSourcePayloadBytes == 14_467_688_508,
              conservation.excludedPayloadBytes == 1_140_925_536 else { throw ProbeError("Gemma partition accounting differs") }
        self.artifact = artifact; self.stages = stages; self.mappings = mappings; replication = [group]
        self.conservation = conservation
        fingerprint = sha256(Data(["gemma4-text-two-stage-plan-v1", artifact.fingerprint,
            stages[0].fingerprint, stages[1].fingerprint, conservation.fingerprint,
            "payloadVerified=false", "executionAuthorized=false"].joined(separator: "\n").utf8))
    }

    /// Actual later inventories must match the admitted model mapping, not just totals.
    func validateStorage(mappings candidate: [LayerStageTensorMapping], excludedSourceNames: [String]) throws -> LayerStageStorageConservation {
        let sorted = candidate.sorted { $0.source.layout.canonicalName < $1.source.layout.canonicalName }
        guard sorted == mappings, excludedSourceNames.sorted() == artifact.excludedSourceNames else {
            throw ProbeError("Gemma actual mapping/global indices/exclusions differ from admitted Plan")
        }
        let result = try LayerStageStorageConservation.validate(sources: artifact.sources,
            mappings: sorted, excludedSourceNames: excludedSourceNames, allowedReplication: replication)
        guard result == conservation else { throw ProbeError("Gemma storage accounting is not repeatable") }
        return result
    }
}
