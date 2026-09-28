import Foundation

struct LayerStageStorageConservation: Encodable, Equatable {
    struct Rank: Encodable, Equatable {
        let rank: Int
        let tensorCount: Int
        let logicalPayloadBytes: Int
    }
    let sourceTensorCount: Int
    let sourcePayloadBytes: Int
    let excludedTensorCount: Int
    let excludedPayloadBytes: Int
    let selectedSourceTensorCount: Int
    let selectedSourcePayloadBytes: Int
    let destinationTensorCount: Int
    let destinationPayloadBytes: Int
    let additionalReplicaBytes: Int
    let ranks: [Rank]
    let fingerprint: String
    let payloadVerificationEstablished = false
    let actualAllocationEstablished = false

    static func validate(sources: [LayerStageSourceTensor], mappings: [LayerStageTensorMapping],
                         excludedSourceNames: [String],
                         allowedReplication: [LayerStageTiedEmbeddingReplication]) throws -> Self {
        guard (1...4096).contains(sources.count), mappings.count <= sources.count,
              Set(sources.map { $0.layout.canonicalName }).count == sources.count,
              Set(excludedSourceNames).count == excludedSourceNames.count,
              Set(mappings.map { $0.source.layout.canonicalName }).count == mappings.count,
              allowedReplication.count <= 1 else { throw ProbeError("Stage source/mapping coverage is duplicated or unbounded") }
        let byName = Dictionary(uniqueKeysWithValues: sources.map { ($0.layout.canonicalName, $0) })
        let excluded = Set(excludedSourceNames), selected = Set(mappings.map { $0.source.layout.canonicalName })
        guard excluded.isSubset(of: Set(byName.keys)), selected.isDisjoint(with: excluded),
              selected.union(excluded) == Set(byName.keys) else {
            throw ProbeError("Stage mapping does not exactly partition selected and excluded sources")
        }
        var groupBySource: [String: LayerStageTiedEmbeddingReplication] = [:]
        for group in allowedReplication {
            let suffixes: Set<String> = ["weight", "scales", "biases"]
            guard !group.id.isEmpty, group.id.utf8.count <= 128,
                  group.ingressRank == 0, group.outputRank == 1,
                  Set(group.sourceNames) == Set(suffixes.map { group.canonicalModule + "." + $0 }),
                  group.sourceNames.count == 3, Set(group.sourceNames).isSubset(of: selected) else {
                throw ProbeError("Invalid admitted tied embedding replica group")
            }
            for name in group.sourceNames {
                guard groupBySource.updateValue(group, forKey: name) == nil else {
                    throw ProbeError("Overlapping tied embedding groups")
                }
            }
        }
        var destinationKeys = Set<String>(), rankBytes = [0, 0], rankCounts = [0, 0]
        var replicaBytes = 0
        for mapping in mappings {
            let source = mapping.source, name = source.layout.canonicalName
            guard byName[name] == source, (1...2).contains(mapping.destinations.count) else {
                throw ProbeError("Mapping changed its source descriptor or destination count")
            }
            if let group = groupBySource[name] {
                let expected = [
                    LayerStageTensorDestination(rank: group.ingressRank, localName: name,
                        role: .ingressEmbedding, globalLayerIndex: nil),
                    LayerStageTensorDestination(rank: group.outputRank, localName: name,
                        role: .tiedOutputEmbedding, globalLayerIndex: nil),
                ]
                guard mapping.replicationGroupID == group.id, mapping.destinations == expected else {
                    throw ProbeError("Tied embedding is not the exact admitted two-rank replication")
                }
                replicaBytes = try QwenLongPrefillCheckedBytes.sum([replicaBytes, source.layout.byteCount])
            } else {
                guard mapping.replicationGroupID == nil, mapping.destinations.count == 1,
                      mapping.destinations[0].role != .tiedOutputEmbedding else {
                    throw ProbeError("Unadmitted source replication")
                }
            }
            for destination in mapping.destinations {
                guard (0...1).contains(destination.rank),
                      (destination.role == .layer
                        ? destination.globalLayerIndex.map { (0..<128).contains($0) } == true
                        : destination.globalLayerIndex == nil) else { throw ProbeError("Invalid destination role/index") }
                _ = try LayerStageTensorLayout(canonicalName: destination.localName,
                    shape: source.layout.shape, sourceDType: source.layout.sourceDType,
                    byteCount: source.layout.byteCount)
                guard destinationKeys.insert("\(destination.rank):\(destination.localName)").inserted else {
                    throw ProbeError("Stage destination collision")
                }
                rankCounts[destination.rank] += 1
                rankBytes[destination.rank] = try QwenLongPrefillCheckedBytes.sum([
                    rankBytes[destination.rank], source.layout.byteCount])
            }
        }
        let sum = QwenLongPrefillCheckedBytes.sum
        let sourceBytes = try sum(sources.map { $0.layout.byteCount })
        let excludedBytes = try sum(excluded.map { byName[$0]!.layout.byteCount })
        let selectedBytes = try sum(mappings.map { $0.source.layout.byteCount })
        let destinationBytes = try sum(rankBytes)
        guard rankCounts.allSatisfy({ $0 > 0 }), sourceBytes == (try sum([selectedBytes, excludedBytes])),
              destinationBytes == (try sum([selectedBytes, replicaBytes])) else {
            throw ProbeError("Stage source/replica byte conservation failed")
        }
        let identity = ["layer-stage-storage-conservation-v1",
            sha256(try canonicalJSONData(sources.sorted { $0.layout.canonicalName < $1.layout.canonicalName })),
            sha256(try canonicalJSONData(mappings.sorted { $0.source.layout.canonicalName < $1.source.layout.canonicalName })),
            sha256(try canonicalJSONData(excludedSourceNames.sorted())),
            sha256(try canonicalJSONData(allowedReplication)), "payloadVerified=false", "allocationVerified=false"]
        return .init(sourceTensorCount: sources.count, sourcePayloadBytes: sourceBytes,
            excludedTensorCount: excluded.count, excludedPayloadBytes: excludedBytes,
            selectedSourceTensorCount: mappings.count, selectedSourcePayloadBytes: selectedBytes,
            destinationTensorCount: destinationKeys.count, destinationPayloadBytes: destinationBytes,
            additionalReplicaBytes: replicaBytes,
            ranks: (0...1).map { Rank(rank: $0, tensorCount: rankCounts[$0], logicalPayloadBytes: rankBytes[$0]) },
            fingerprint: sha256(Data(identity.joined(separator: "\n").utf8)))
    }
}
