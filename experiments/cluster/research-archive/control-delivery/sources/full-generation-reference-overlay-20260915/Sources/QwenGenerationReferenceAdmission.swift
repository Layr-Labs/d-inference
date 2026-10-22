import Foundation

/// Reuses the exact registered source/prompt/arithmetic admission. Its output-one
/// budget is provenance only: generation recomputes the named terms at P+O.
/// Neither admission is a live OS/allocator permit.
struct QwenGenerationReferenceAdmission {
    let source: QwenRegistered9BLongPrefillReferenceAdmission
    let request: QwenLayerStageGenerationRequest
    let requirements: QwenGenerationReferenceRequirements

    init(source: QwenRegistered9BLongPrefillReferenceAdmission,
         request: QwenLayerStageGenerationRequest) throws {
        guard request.requestID == source.request.request.requestID,
              request.promptTokenIDs == source.request.promptTokenIDs,
              request.chunkSize == source.resource.chunkSize,
              request.profile.hiddenSize == source.resource.geometry.hiddenSize,
              request.profile.vocabularySize == source.request.vocabularySize,
              request.profile.activationDType == source.resource.requiredNativeDType,
              request.prefillFrameCount == source.request.steps.count,
              (1...128).contains(request.outputCount) else {
            throw ProbeError("Generation reference differs from its registered source or prompt admission")
        }
        self.source = source; self.request = request
        requirements = try .init(request: request, geometry: source.resource.geometry,
            namedTensorByteCeiling: source.resource.namedTensorByteCeiling)
    }
}

/// Named logical tensor terms, not a peak/RSS/allocator bound. The required
/// callback must independently apply live OS/allocator/timeout admission before
/// state creation and keep its check active during capture and retirement.
struct QwenGenerationReferenceRequirements: Encodable {
    let requestFingerprint: String
    let maximumTokens: Int
    let namedTensors: QwenLongPrefillTensorBudget
    let namedTensorByteCeiling: Int
    let maximumCapturedRowsSimultaneously = 2
    let capturedRowsCPUBytes: Int
    let temporaryFloat32RowBytes: Int
    let includesWeightsOrUnknownNativeWorkspace = false
    let resourceAdmissionPerformed = false

    init(request: QwenLayerStageGenerationRequest, geometry: QwenLongPrefillBudgetGeometry,
         namedTensorByteCeiling: Int) throws {
        let budget = try QwenLongPrefillTensorBudget.estimate(geometry: geometry,
            maximumTokens: request.maximumTokens, chunkSize: request.chunkSize)
        guard budget.conservativeStateAndBoundaryBytes <= namedTensorByteCeiling else {
            throw ProbeError("Generation reference exceeds the existing named-tensor ceiling")
        }
        let bytes = try qwenStageWireElementBytes(request.profile.activationDType)
        let product = QwenLongPrefillCheckedBytes.product
        self.requestFingerprint = request.fingerprint; maximumTokens = request.maximumTokens
        namedTensors = budget; self.namedTensorByteCeiling = namedTensorByteCeiling
        // One current capture plus the previous final-row candidate during
        // assignment; each has native bytes and complete Float32 CPU values.
        capturedRowsCPUBytes = try product([2, request.profile.vocabularySize, bytes + 4])
        temporaryFloat32RowBytes = try product([request.profile.vocabularySize, 4])
    }
}
