import Foundation
import MLX

/// Reuse the existing immutable frame and EOS/length schedule. Its historical
/// Qwen type/prefix names do not select model math or grant resources. A distinct
/// Gemma profile ID prevents it from matching any registered Qwen admission.
enum Gemma4ForwardRequest {
    static func make(requestID: UUID, tokens: [Int], chunkSize: Int, outputCount: Int,
                     stopTokenIDs: Set<Int>, observedResidualDType: DType) throws -> QwenLayerStageGenerationRequest {
        guard [.float16, .bfloat16, .float32].contains(observedResidualDType) else {
            throw ProbeError("Gemma request needs the observed native residual type")
        }
        let profile = try QwenLayerStageGenerationProfile(identifier: "registered_gemma4_26b_forward_validation_v1",
            vocabularySize: 262144, hiddenSize: 2816, activationDType: String(describing: observedResidualDType),
            maximumPromptTokens: 8192, maximumChunkTokens: 512, maximumOutputTokens: 128, maximumContextTokens: 8320)
        return try .init(profile: profile, requestID: requestID, promptTokenIDs: tokens,
            chunkSize: chunkSize, outputCount: outputCount, stopTokenIDs: stopTokenIDs)
    }

    static func validate(_ request: QwenLayerStageGenerationRequest, dtype: DType) throws {
        guard request == (try make(requestID: request.requestID, tokens: request.promptTokenIDs,
            chunkSize: request.chunkSize, outputCount: request.outputCount,
            stopTokenIDs: request.stopTokenIDs, observedResidualDType: dtype)) else {
            throw ProbeError("Gemma request differs from its bounded forward profile")
        }
    }
}

/// Local correctness bridge, not wire framing or a physical storage attestation.
/// The mapping fingerprint names the shared exact source Plan. Each load keeps
/// its own actual parameter/storage receipt; neither replaces peer admission.
struct Gemma4ForwardBoundary {
    let requestSHA256: String
    let artifactSHA256: String
    let planSHA256: String
    let mappingSHA256: String
    let producerStageSHA256: String
    let frame: QwenLayerStageFrame
    let tokenIDsSHA256: String
    let array: MLXArray
    let payloadSHA256: String

    func requireOwned(tokens: Int, hidden: Int, dtype: DType) throws {
        guard array.shape == [1, tokens, hidden], array.dtype == dtype,
              array.nbytes == tokens * hidden * dtype.size,
              let storage = try array.evaluatedBufferInfo(), storage.isUnique,
              storage.isRowContiguous, storage.dataOffset == 0,
              storage.dataElements == array.size, storage.allocatedBytes >= array.nbytes,
              storage.allocatedBytes <= (try Memory.allocationFootprintUpperBound(byteCount: array.nbytes)),
              sha256(array.asData().data) == payloadSHA256 else {
            throw ProbeError("Gemma residual is not exact compact owned storage")
        }
    }

    func ownedCopy(check: () throws -> Void) throws -> Self {
        try MLX.withError { native in
            func checked() throws { try native.check(); try check(); try native.check() }
            do {
                try checked()
                let copy = try copySelectedTensor(array, selection: .all)
                try checked()
                guard copy.shape == array.shape, copy.dtype == array.dtype,
                      sha256(copy.asData().data) == payloadSHA256 else {
                    throw ProbeError("Gemma boundary copy changed native bytes")
                }
                try checked()
                return .init(requestSHA256: requestSHA256, artifactSHA256: artifactSHA256,
                    planSHA256: planSHA256, mappingSHA256: mappingSHA256,
                    producerStageSHA256: producerStageSHA256, frame: frame,
                    tokenIDsSHA256: tokenIDsSHA256, array: copy, payloadSHA256: payloadSHA256)
            } catch { try native.check(); throw error }
        }
    }
}

enum Gemma4ForwardOutput {
    case residual(Gemma4ForwardBoundary)
    case evaluationHandle(MLXArray)
    case logits(MLXArray)
}
