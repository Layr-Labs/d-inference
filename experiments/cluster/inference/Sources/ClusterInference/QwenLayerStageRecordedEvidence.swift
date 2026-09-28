import Foundation

/// CPU-only identity of the independently verified full-model load. The layout
/// describes its deterministic loaded representation, not a resident content hash.
struct QwenRecordedSourceIdentity: Encodable {
    let artifactAggregateSHA256: String
    let sourceConfigurationSHA256: String
    let sourceParameterLayoutSHA256: String
    let planSHA256: String
    let bf16ConversionEnabled: Bool
    let embeddingActivationDType: String
    let sourceModelTensorBytes: Int
    let layerCount: Int
    let vocabularySize: Int
}

struct QwenRecordedState: Encodable, Equatable {
    struct Entry: Encodable, Equatable {
        let globalLayerIndex: Int
        let component: String
        let shape: [Int]
        let dtype: String
        let byteCount: Int
        let sha256: String

        var key: String { "\(globalLayerIndex)|\(component)" }
        var identity: String { "\(key)|\(shape)|\(dtype)|\(byteCount)|\(sha256)" }

        var validLogicalStorage: Bool {
            // The admitted kernel-size-one model has no convolution history.
            // Its public CBv2 spec explicitly permits [1,0,channels].
            if component == "conv", shape.count == 3, shape[0] == 1,
               shape[1] == 0, shape[2] > 0 { return byteCount == 0 }
            return !shape.isEmpty && shape.allSatisfy({ $0 > 0 }) && byteCount > 0
        }
    }
    let committedTokens: Int
    let entries: [Entry]
    let logicalByteCount: Int
    let fingerprint: String

    /// Both a single full-model snapshot and the disjoint stage snapshots use
    /// the same global key space. Local indices intentionally do not compare.
    init(snapshots: [CBv2OwnedStateSnapshot], plan: QwenLayerStagePlan,
         committedTokens: Int) throws {
        guard committedTokens > 0, !snapshots.isEmpty,
              snapshots.allSatisfy({ $0.committedTokens == committedTokens }) else {
            throw ProbeError("Recorded state snapshots have different token frontiers")
        }
        var expected = Set<String>()
        for layer in plan.stages.flatMap(\.layers) {
            let components: [String]
            switch layer.kind {
            case "full_attention": components = ["kv.keys", "kv.values", "kv.position_offsets"]
            case "linear_attention": components = ["conv", "ssm"]
            default: throw ProbeError("Recorded state has an unsupported layer policy")
            }
            for component in components { expected.insert("\(layer.globalIndex)|\(component)") }
        }
        let entries = snapshots.flatMap(\.entries).map {
            Entry(globalLayerIndex: $0.globalLayerIndex, component: $0.component,
                shape: $0.shape, dtype: $0.dtype, byteCount: $0.byteCount, sha256: $0.sha256)
        }.sorted { ($0.globalLayerIndex, $0.component) < ($1.globalLayerIndex, $1.component) }
        guard entries.count == expected.count, Set(entries.map(\.key)) == expected,
              entries.allSatisfy({ $0.validLogicalStorage && $0.sha256.count == 64 }) else {
            throw ProbeError("Recorded state lacks complete, disjoint global layer/component coverage")
        }
        var bytes = 0
        for entry in entries {
            let addition = bytes.addingReportingOverflow(entry.byteCount)
            guard !addition.overflow else { throw ProbeError("Recorded state byte total overflowed") }
            bytes = addition.partialValue
        }
        self.committedTokens = committedTokens; self.entries = entries; self.logicalByteCount = bytes
        self.fingerprint = sha256(Data((["cbv2-owned-state-v1", "tokens=\(committedTokens)"]
            + entries.map(\.identity)).joined(separator: "\n").utf8))
        // Preserve the established baseline snapshot fingerprint convention.
        if snapshots.count == 1, snapshots[0].fingerprint != fingerprint {
            throw ProbeError("Recorded state changed its original snapshot identity")
        }
    }

    func requireExact(_ candidate: QwenRecordedState) throws {
        guard committedTokens == candidate.committedTokens,
              entries.count == candidate.entries.count else {
            throw ProbeError("Recorded state frontier or entry count differs")
        }
        for (original, other) in zip(entries, candidate.entries) where original != other {
            throw ProbeError("Recorded state metadata or digest differs at global layer \(original.globalLayerIndex), \(original.component), frontier \(committedTokens)")
        }
        guard logicalByteCount == candidate.logicalByteCount, fingerprint == candidate.fingerprint else {
            throw ProbeError("Recorded complete state identity differs at frontier \(committedTokens)")
        }
    }
}

struct QwenRecordedFrameEvidence: Encodable {
    let frame: QwenLayerStageFrame
    let committedTokens: Int
    let outputKind: String
    let outputShape: [Int]
    let outputDType: String
    let state: QwenRecordedState
    let logits: QwenRecordedLogits?

    var fingerprint: String {
        sha256(Data([
            "qwen-recorded-frame-v1", "\(frame.sequence)|\(frame.phase.rawValue)|\(frame.tokenOffset)|\(frame.tokenCount)|\(frame.finalPromptChunk)",
            "tokens=\(committedTokens)", "\(outputKind)|\(outputShape)|\(outputDType)",
            state.fingerprint, logits?.record.logicalBytesSHA256 ?? "no-logits",
        ].joined(separator: "\n").utf8))
    }
}

/// Encodable evidence contains only values, strings, integers and owned CPU
/// Data inside logits. It cannot retain the baseline model/session/device state.
struct QwenLayerStageBaselineEvidence: Encodable {
    let kind = "qwen_layer_stage_recorded_baseline"
    let correctnessOnly = true
    let throughputMeasurementValid = false
    let request: QwenLayerStageRecordedRequest
    let source: QwenRecordedSourceIdentity
    let frames: [QwenRecordedFrameEvidence]
    let fingerprint: String
    let allRequestStateRetired: Bool

    init(request: QwenLayerStageRecordedRequest, source: QwenRecordedSourceIdentity,
         frames: [QwenRecordedFrameEvidence]) throws {
        guard frames.count == request.steps.count, frames.count <= 132,
              zip(frames, request.steps).allSatisfy({ evidence, step in
                  evidence.frame == step.frame && evidence.committedTokens == step.committedTokens
                      && (evidence.logits != nil) == step.expectsLogits
              }) else { throw ProbeError("Recorded baseline evidence does not cover its exact timeline") }
        self.request = request; self.source = source; self.frames = frames
        self.fingerprint = sha256(Data((["qwen-layer-stage-baseline-v1", request.fingerprint,
            sha256(try canonicalJSONData(source))] + frames.map(\.fingerprint)).joined(separator: "\n").utf8))
        self.allRequestStateRetired = true
    }
}
