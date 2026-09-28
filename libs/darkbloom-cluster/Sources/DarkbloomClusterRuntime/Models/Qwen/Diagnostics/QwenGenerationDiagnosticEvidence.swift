import Foundation

/// CPU values only, emitted after the existing bilateral retirement. State is
/// the complete local stage; its hash is not a full-model state hash. Join both
/// disjoint global entry sets before comparing with the independent reference.
struct QwenGenerationDiagnosticEvidence: Encodable {
    let schema = "qwen_stage_generation_final_diagnostic_v1"
    let execution: QwenLayerStageGenerationResult
    let agreement: QwenLayerStageGenerationAgreement.Descriptor
    let requestFingerprint: String
    let profileFingerprint: String
    let rank: Int
    let sourceLayerStart: Int
    let sourceLayerEnd: Int
    let finalFrame: QwenLayerStageFrame
    let stateEntries: [QwenRecordedState.Entry]
    let logicalStateBytes: Int
    let stageStateSHA256: String
    /// Present only on rank1. Includes the complete Float32 values and the
    /// original native logical-byte hash; the private original Data is omitted.
    let finalLogits: QwenRecordedLogits?
    let captureBudget: QwenGenerationDiagnosticBudget
    let resourceObservationCount: Int
    let minimumObservedActualFreeBytes: Int
    let minimumObservedAllocatorLimitBytes: Int
    let actualAllocatorBoundsUsed = true
    let correctnessOnly = true
    let throughputMeasurementValid = false
    let stateBytesIncluded = false
    let intermediateLogitRowsCompared = false
    let independentNumericalComparisonPerformed = false
    let physicalTransferQualified = false

    /// Publication is separately bounded after native retirement. The encode
    /// cap limits output bytes; it is not a serialization allocation bound.
    func encoded() throws -> Data {
        let bytes = try canonicalJSONData(self)
        guard !bytes.isEmpty, bytes.count <= 16 * 1024 * 1024 else {
            throw ProbeError("Generation final diagnostic exceeds its output cap")
        }
        return bytes
    }
}
