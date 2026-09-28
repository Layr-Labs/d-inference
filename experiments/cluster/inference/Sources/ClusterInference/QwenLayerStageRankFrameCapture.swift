import Foundation

/// Only this CPU value crosses the per-frame observer boundary. Global indices
/// remain comparable to a separately recorded full-model baseline; UUID-bound
/// request/header fingerprints are compared only inside the fresh rank cohort.
struct QwenLayerStageRankFrameCapture: Encodable {
    let kind = "qwen_layer_stage_rank_frame_capture"
    let identity: QwenLayerStageSessionIdentity
    let frame: QwenLayerStageFrame
    let committedTokens: Int
    let sourceLayerStart: Int
    let sourceLayerEnd: Int
    let stateEntries: [QwenRecordedState.Entry]
    let logicalStateBytes: Int
    let stageStateSHA256: String
    let boundaryPayloadSHA256: String
    let boundaryShape: [Int]
    let boundaryDType: String
    let outputKind: String
    let outputShape: [Int]
    let outputDType: String
    let logits: QwenRecordedLogitValues?
}

struct QwenLayerStageRankFrameCompletion: Encodable {
    let kind = "qwen_layer_stage_rank_frame_completion"
    let capture: QwenLayerStageRankFrameCapture
    let headerSHA256: String
    /// Rank zero validated the consumed ACK. Rank one completed its ACK send;
    /// send completion alone cannot prove the peer validated that ACK.
    let completedTransportPhase: String
}

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
