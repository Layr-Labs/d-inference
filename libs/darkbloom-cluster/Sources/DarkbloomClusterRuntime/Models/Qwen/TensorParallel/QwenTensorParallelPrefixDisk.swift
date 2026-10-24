import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// The SSD tier of a tensor-parallel rank's prompt-prefix cache. Each rank
/// keeps only its own shard: its heads' attention rows and recurrent state,
/// plus the replicated assistant's trusted history for a speculating owner,
/// in the encrypted records of `QwenStagePrefixDiskTier`. The record scope
/// outlives the owner process (plan and shares, the verified artifact and
/// this rank's storage commitment, both builds, the assistant policy), never
/// a membership epoch, so a restarted pair finds what the last one kept.
/// A record is only an offer: restoration stays a sealed two-rank vote and a
/// confirmation, both ranks or neither.
struct QwenTensorParallelPrefixDisk {
    let tier: QwenStagePrefixDiskTier
    /// The persistent part of every request scope on this rank.
    let planScope: String

    /// What names a directory of records: everything a restored shard's bytes
    /// depend on, from what each rank knows at load.
    static func planScope(plan: QwenTensorParallelPlan, planFingerprint: String, artifactAggregateSHA256: String,
                          storageCommitmentSHA256: String, rankBuildSHA256: [String],
                          assistantPolicy: String?) -> String {
        QwenStagePrefixDiskTier.planScope(
            planFingerprint: [planFingerprint, plan.name, "shares=" + plan.shares.map(String.init).joined(separator: ":")]
                .joined(separator: "|"),
            artifactAggregateSHA256: artifactAggregateSHA256, storageCommitmentSHA256: storageCommitmentSHA256,
            rankBuildSHA256: rankBuildSHA256, generationMode: "tensor_parallel_v1",
            prefillSchedule: "serial|assistant=" + (assistantPolicy ?? "none"))
    }

    /// A request scope on disk: the persistent plan scope plus the request's
    /// own grid and media identity (the resident scope's suffix).
    func scope(_ suffix: String) -> String { planScope + "|" + suffix }

    func frontiers(scope: String, tokens: [Int], maximumFrontier: Int) -> Set<Int> {
        Set(tier.frontiers(scope: scope, tokens: tokens, maximumFrontier: maximumFrontier))
    }
}

extension QwenTensorParallelBatchPrefixState {
    /// The record shape: the same arrays, no copies.
    var stageState: QwenStagePrefixState {
        .init(committedTokens: committedTokens, attention: attention, recurrent: recurrent)
    }

    /// A shard read from the SSD tier, charged by the same allocation bound as
    /// a capture of this frontier.
    init(stage: QwenStagePrefixState, allocationBound: (Int) throws -> Int) throws {
        let roots = stage.attention.values.flatMap { [$0.keys, $0.values] } + stage.recurrent.values.flatMap { [$0.conv, $0.ssm] }
        guard stage.committedTokens > 0, !roots.isEmpty,
              stage.attention.values.allSatisfy({ $0.keys.ndim == 4 && $0.keys.dim(2) == stage.committedTokens
                  && $0.values.shape == $0.keys.shape }) else {
            throw ProbeError("Qwen TP SSD prefix shard differs from its frontier")
        }
        let allocated = try QwenLongPrefillCheckedBytes.sum(roots.map {
            let bytes = try allocationBound($0.nbytes)
            guard bytes >= $0.nbytes, $0.nbytes > 0 else { throw ProbeError("Qwen TP prefix allocation bound differs") }
            return bytes
        })
        self.init(committedTokens: stage.committedTokens, attention: stage.attention, recurrent: stage.recurrent,
                  allocatedBytes: allocated)
    }
}

extension QwenTensorParallelBatchPrefixState {
    /// Whether this shard adopts into a request state of `geometry`: the
    /// checks `CBv2OwnedRequestState` makes when it adopts (every layer, this
    /// rank's shapes and dtypes), made before any page is written.
    func adopts(into geometry: CBv2RequestGeometry) -> Bool {
        guard attention.count == geometry.kinds.count, recurrent.count == geometry.recurrent.layers.count else { return false }
        for kind in geometry.kinds {
            let shape = [1, kind.kvHeads, kind.retainedTokens(atFrontier: committedTokens), kind.headDim]
            guard case .full = kind.attention, let layer = kind.modelLayerIndex, let pair = attention[layer],
                  pair.keys.shape == shape, pair.values.shape == shape,
                  pair.keys.dtype == geometry.kvDType, pair.values.dtype == geometry.kvDType else { return false }
        }
        return geometry.recurrent.layers.allSatisfy { layer in
            guard let pair = recurrent[layer.modelLayerIndex] else { return false }
            return pair.conv.shape == layer.convShape && pair.conv.dtype == layer.convDType
                && pair.ssm.shape == layer.ssmShape && pair.ssm.dtype == layer.ssmDType
        }
    }
}

extension QwenTensorParallelMTPPrefixState {
    /// The record shape: the target shard and the assistant's trusted history
    /// (`[1, f-1, H]` hidden rows, `[1, f-1]` tokens, the `[1, 1, H]` frontier
    /// row) as the record's speculative history.
    func stageState(assistant: Qwen35InlineMTPAssistant) -> QwenStagePrefixState? {
        guard let tensors = assistant.encodePrefixCheckpoint(self.assistant), tensors.count == 3 else { return nil }
        var state = target.stageState
        state.speculativeHistory = QwenMTPPrefixHistory(frontier: committedTokens,
            hidden: tensors[0], tokens: tensors[1], last: tensors[2])
        return state
    }

    /// A target shard and assistant history read from the SSD tier, rebound to
    /// this loaded assistant and checked against the prompt it was kept for.
    init(stage: QwenStagePrefixState, assistant: Qwen35InlineMTPAssistant, prompt: [Int],
         allocationBound: (Int) throws -> Int) throws {
        let frontier = stage.committedTokens
        guard let history = stage.speculativeHistory, history.frontier == frontier, frontier > 1, frontier <= prompt.count else {
            throw ProbeError("Qwen TP SSD assistant history differs from its prompt frontier")
        }
        // The codec compares the tokens in place: give it its own contiguous
        // copy of the prompt's (as the pipeline's adoption does).
        let tokens = MLXArray(prompt[1..<frontier].map(Int32.init), [1, frontier - 1])
        eval(tokens)
        guard let checkpoint = assistant.decodePrefixCheckpoint(tensors: [history.hidden, tokens, history.last],
                  prefixTokens: Array(prompt[0..<frontier])),
              let descriptors = assistant.prefixCheckpointTensorDescriptors(targetInputCount: frontier) else {
            throw ProbeError("Qwen TP SSD assistant history differs from its prompt frontier")
        }
        let target = try QwenTensorParallelBatchPrefixState(stage: stage, allocationBound: allocationBound)
        let assistantBytes = try QwenLongPrefillCheckedBytes.sum(descriptors.map {
            let bound = try allocationBound($0.byteCount)
            guard bound >= $0.byteCount, $0.byteCount > 0 else { throw ProbeError("Qwen TP assistant prefix allocation bound differs") }
            return bound
        })
        self.init(target: target, assistant: checkpoint,
                  allocatedBytes: try QwenLongPrefillCheckedBytes.sum([target.allocatedBytes, assistantBytes]))
    }
}
