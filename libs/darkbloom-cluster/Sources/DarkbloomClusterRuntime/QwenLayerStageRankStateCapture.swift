import Foundation

/// Validate only this stage's complete state coverage, including its explicit
/// local/global map. This does not assert equality with a baseline or other rank.
struct QwenLayerStageRankStateCapture {
    let entries: [QwenRecordedState.Entry]
    let logicalBytes: Int
    let fingerprint: String

    init(snapshot: CBv2OwnedStateSnapshot, stage: QwenLayerStagePlan.Stage,
         committedTokens: Int) throws {
        guard committedTokens > 0, snapshot.committedTokens == committedTokens,
              snapshot.entries.allSatisfy({
                  stage.layers.indices.contains($0.localLayerIndex)
                      && stage.layers[$0.localLayerIndex].localIndex == $0.localLayerIndex
                      && stage.layers[$0.localLayerIndex].globalIndex == $0.globalLayerIndex
              }) else { throw ProbeError("Rank snapshot differs from its local/global layer map or token frontier") }
        var expected = Set<String>()
        for layer in stage.layers {
            let components: [String]
            switch layer.kind {
            case "full_attention": components = ["kv.keys", "kv.values", "kv.position_offsets"]
            case "linear_attention": components = ["conv", "ssm"]
            default: throw ProbeError("Rank snapshot has an unsupported layer policy")
            }
            for component in components { expected.insert("\(layer.globalIndex)|\(component)") }
        }
        let entries = snapshot.entries.map {
            QwenRecordedState.Entry(globalLayerIndex: $0.globalLayerIndex, component: $0.component,
                shape: $0.shape, dtype: $0.dtype, byteCount: $0.byteCount, sha256: $0.sha256)
        }.sorted { ($0.globalLayerIndex, $0.component) < ($1.globalLayerIndex, $1.component) }
        guard entries.count == expected.count, Set(entries.map(\.key)) == expected,
              entries.allSatisfy({ $0.validLogicalStorage && qwenStageWireIsSHA256($0.sha256) }) else {
            throw ProbeError("Rank snapshot lacks complete disjoint native state components")
        }
        var logicalBytes = 0
        for entry in entries {
            let next = logicalBytes.addingReportingOverflow(entry.byteCount)
            guard !next.overflow else { throw ProbeError("Rank snapshot logical byte total overflow") }
            logicalBytes = next.partialValue
        }
        let fingerprint = sha256(Data((["cbv2-owned-state-v1", "tokens=\(committedTokens)"]
            + entries.map(\.identity)).joined(separator: "\n").utf8))
        guard fingerprint == snapshot.fingerprint else { throw ProbeError("Rank snapshot capture changed its state identity") }
        self.entries = entries; self.logicalBytes = logicalBytes; self.fingerprint = fingerprint
    }
}
