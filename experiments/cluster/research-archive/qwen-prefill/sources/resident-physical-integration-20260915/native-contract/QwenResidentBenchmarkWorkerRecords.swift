import Foundation

struct QwenResidentBenchmarkWorkerReadyRecord<Execution: Encodable>: Encodable {
    let execution: Execution
    let initialResources: QwenResidentBenchmarkWorkerResources
    let loadedResources: QwenResidentBenchmarkWorkerResources
    let runtime: QwenDenseStageLoadRuntimeObservation
}

struct QwenResidentBenchmarkWorkerResultRecord<Execution: Encodable>: Encodable {
    let command: QwenResidentBenchmarkWorkerRun
    let step: QwenLongPrefillResidentRequestStep
    let execution: Execution
    let resourcesBeforeRequest: QwenResidentBenchmarkWorkerResources
    let resourcesAfterRequest: QwenResidentBenchmarkWorkerResources
}

/// Constructed only after the owner has returned from its actual release path.
/// Full CPU request records were already published; do not repeat them here.
struct QwenResidentBenchmarkWorkerReleasedRecord: Encodable {
    let completedRequestCount: Int
    let memory: [QwenStageMemoryObservation]
    let resourcesAfterRelease: QwenResidentBenchmarkWorkerResources
    let modelLoadCount = 1, modelReleased = true, allRequestStateRetired = true
    let correctnessOnly = true, throughputMeasurementValid = false
    let physicalTransferQualified = false, independentNumericalComparisonPerformed = false
}

struct QwenResidentBenchmarkWorkerStoppedRecord: Encodable {
    let completedRequestCount = 4
    let modelReleased = true, allRequestStateRetired = true
    let explicitShutdownAccepted = true
    let correctnessOnly = true, throughputMeasurementValid = false
    let physicalTransferQualified = false, independentNumericalComparisonPerformed = false
}
