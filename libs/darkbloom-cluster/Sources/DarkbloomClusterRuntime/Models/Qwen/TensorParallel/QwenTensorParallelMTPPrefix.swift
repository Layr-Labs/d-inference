import MLX
import MLXLLM
import MLXLMCommon

/// A single original-grid frontier owns both the genuine target snapshot and
/// its assistant's normalized trusted history. The checkpoint is bound to the
/// loaded assistant instance; it cannot be attached to another LOAD.
struct QwenTensorParallelMTPPrefixState: QwenTensorParallelPrefixSnapshot {
    let target: QwenTensorParallelBatchPrefixState
    let assistant: any CBv2MTPPrefixCheckpoint
    let allocatedBytes: Int
    var committedTokens: Int { target.committedTokens }

    static func capture(target: any QwenTensorParallelMTPTarget, assistant: Qwen35InlineMTPAssistant,
                        requestState: any CBv2MTPRequestState, frontier: Int, limitBytes: Int,
                        allocationBound: (Int) throws -> Int, check: () throws -> Void) throws -> Self? {
        guard frontier > 1, frontier < target.request.promptCount,
              frontier % target.request.chunkSize == 0, target.state.committedTokens == frontier,
              let descriptors = assistant.prefixCheckpointTensorDescriptors(targetInputCount: frontier) else {
            throw ProbeError("Qwen TP assistant prefix differs from its target prompt frontier")
        }
        let assistantBytes = try QwenLongPrefillCheckedBytes.sum(descriptors.map {
            let bound = try allocationBound($0.byteCount)
            guard bound >= $0.byteCount, $0.byteCount > 0 else {
                throw ProbeError("Qwen TP assistant prefix allocation bound differs")
            }
            return bound
        })
        guard assistantBytes <= limitBytes,
              let snapshot = try QwenTensorParallelBatchPrefixState.capture(state: target.state,
                frontier: frontier, limitBytes: limitBytes - assistantBytes,
                allocationBound: allocationBound, check: check) else { return nil }
        guard let checkpoint = assistant.capturePrefixCheckpoint(requestState: requestState, targetInputCount: frontier),
              checkpoint.targetInputCount == frontier,
              let tensors = assistant.encodePrefixCheckpoint(checkpoint), tensors.count == descriptors.count,
              zip(tensors, descriptors).allSatisfy({ pair in
                  pair.0.shape == pair.1.shape && pair.0.dtype == pair.1.dtype.mlxDType && pair.0.nbytes == pair.1.byteCount
              }) else {
            throw ProbeError("Qwen TP assistant did not capture its confirmed trusted history")
        }
        eval(tensors); try check()
        return .init(target: snapshot, assistant: checkpoint,
                     allocatedBytes: try QwenLongPrefillCheckedBytes.sum([snapshot.allocatedBytes, assistantBytes]))
    }
}

typealias QwenTensorParallelMTPPrefixCache = QwenTensorParallelSnapshotCache<QwenTensorParallelMTPPrefixState>
