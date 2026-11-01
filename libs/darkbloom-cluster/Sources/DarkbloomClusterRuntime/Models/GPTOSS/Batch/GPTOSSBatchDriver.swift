import DarkbloomClusterProtocol
import Foundation

// Existing GPT-OSS call sites keep their typed lane reservation; the pure
// schedule is shared with MiMo without sharing either model's native state.
typealias GPTOSSBatchSession = IndependentHistoryBatchSession
typealias GPTOSSBatchExecutor = IndependentHistoryBatchExecutor
typealias GPTOSSBatchDriver<Executor: IndependentHistoryBatchExecutor> =
    IndependentHistoryBatchDriver<Executor, GPTOSSBatchReservation>

struct GPTOSSBatchReservation: IndependentHistoryBatchReservation {
    let request: QwenLayerStageGenerationRequest
    let allowance: GPTOSSResidentRequestAllowance
    let deadline: UInt64
    let prefillAllowance: QwenGenerationPrefillAllowance?
    /// Retain even the selected schedule's existing lookahead allowance,
    /// although batching transfers one original-grid prefill frame per step.
    let laneStateBytes: Int
    let nativeBytes: Int
    var hostBytes: Int { prefillAllowance?.extraHostBytes ?? 0 }

    init(request: QwenLayerStageGenerationRequest, allowance: GPTOSSResidentRequestAllowance,
         deadline: UInt64, prefillAllowance: QwenGenerationPrefillAllowance? = nil) throws {
        self.request = request; self.allowance = allowance; self.deadline = deadline
        self.prefillAllowance = prefillAllowance
        nativeBytes = try QwenLongPrefillCheckedBytes.sum([allowance.reservedBytes,
            prefillAllowance?.extraNativeBytes ?? 0])
        laneStateBytes = try QwenLongPrefillCheckedBytes.sum([nativeBytes,
            prefillAllowance?.extraHostBytes ?? 0])
    }
}
