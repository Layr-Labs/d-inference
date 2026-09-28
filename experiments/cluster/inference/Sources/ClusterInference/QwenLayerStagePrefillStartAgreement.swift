import Foundation

enum QwenLayerStagePrefillMeasurementFlow {
    static let version = 3
    static let name = "bounded_prefill_measurement_v1"
    static let selectionPolicy = "mlx_argmax_all_axes_with_finite_guard_v1"

    /// Both choices use the same ready/received/consumed boundary handshake.
    /// This changes local prompt preparation order, not numerical arithmetic.
    enum SchedulingPolicy: String, Encodable, CaseIterable {
        case serial = "serial_v1"
        case promptLookaheadOne = "prompt_lookahead_one_v1"
    }
}

/// Locally constructed from verified source metadata and already prepared token
/// IDs. Wire contents never create or replace the request supplied to a context.
struct QwenLayerStagePrefillStartAgreement {
    struct Descriptor: Encodable {
        let version: Int
        let flow: String
        let schedulingPolicy: QwenLayerStagePrefillMeasurementFlow.SchedulingPolicy
        let epoch: String
        let requestID: String
        let requestFingerprint: String
        let recordedRequestFingerprint: String
        let promptCount: Int
        let chunkSize: Int
        let outputCount: Int
        let batchSize: Int
        let frameCount: Int
        let promptTokenIDsSHA256: String
        let sourceConfigurationSHA256: String
        let artifactAggregateSHA256: String
        let storageCommitmentSHA256: String
        let planFingerprint: String
        let producerStageFingerprint: String
        let consumerStageFingerprint: String
        let producerConstructionConfigurationSHA256: String
        let consumerConstructionConfigurationSHA256: String
        let bf16ConversionEnabled: Bool
        let hiddenSize: Int
        let nativeDType: String
        let logitsDType: String
        let vocabularySize: Int
        let selectionPolicy: String
    }

    let request: QwenLayerStageRecordedRequest
    let sourceIdentity: QwenLayerStageWireSourceIdentity
    let descriptor: Descriptor
    let fingerprint: String

    init(epoch: String, request: QwenLayerStageRecordedRequest,
         sourceIdentity: QwenLayerStageWireSourceIdentity, consumerStageFingerprint: String,
         producerConstructionConfigurationSHA256: String, consumerConstructionConfigurationSHA256: String,
         bf16ConversionEnabled: Bool, hiddenSize: Int, nativeDType: String, logitsDType: String,
         schedulingPolicy: QwenLayerStagePrefillMeasurementFlow.SchedulingPolicy) throws {
        guard epoch.utf8.count == 32,
              epoch.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (1...128).contains(request.request.promptCount), (1...32).contains(request.request.chunkSize),
              request.request.outputCount == 1, request.teacherTokenIDs.isEmpty,
              !request.steps.isEmpty, request.steps.count <= 128,
              request.steps.allSatisfy({ $0.frame.phase == .prefill }),
              request.steps.last?.committedTokens == request.request.promptCount,
              (1...8192).contains(hiddenSize), (1...262_144).contains(request.vocabularySize),
              [consumerStageFingerprint, producerConstructionConfigurationSHA256,
               consumerConstructionConfigurationSHA256].allSatisfy(qwenStageWireIsSHA256) else {
            throw ProbeError("Prefill agreement requires a fresh epoch, bounded output-one request and verified stage metadata")
        }
        _ = try qwenStageWireElementBytes(nativeDType)
        _ = try qwenStageWireElementBytes(logitsDType)
        let descriptor = Descriptor(version: QwenLayerStagePrefillMeasurementFlow.version,
            flow: QwenLayerStagePrefillMeasurementFlow.name, schedulingPolicy: schedulingPolicy, epoch: epoch,
            requestID: request.request.requestID.uuidString.lowercased(), requestFingerprint: request.request.fingerprint,
            recordedRequestFingerprint: request.fingerprint, promptCount: request.request.promptCount,
            chunkSize: request.request.chunkSize, outputCount: 1, batchSize: 1, frameCount: request.steps.count,
            promptTokenIDsSHA256: sha256(Data(request.promptTokenIDs.map(String.init).joined(separator: ",").utf8)),
            sourceConfigurationSHA256: sourceIdentity.sourceConfigurationSHA256,
            artifactAggregateSHA256: sourceIdentity.artifactAggregateSHA256,
            storageCommitmentSHA256: sourceIdentity.storageCommitmentSHA256,
            planFingerprint: sourceIdentity.planFingerprint, producerStageFingerprint: sourceIdentity.producerStageFingerprint,
            consumerStageFingerprint: consumerStageFingerprint,
            producerConstructionConfigurationSHA256: producerConstructionConfigurationSHA256,
            consumerConstructionConfigurationSHA256: consumerConstructionConfigurationSHA256,
            bf16ConversionEnabled: bf16ConversionEnabled, hiddenSize: hiddenSize, nativeDType: nativeDType,
            logitsDType: logitsDType,
            vocabularySize: request.vocabularySize, selectionPolicy: QwenLayerStagePrefillMeasurementFlow.selectionPolicy)
        self.request = request; self.sourceIdentity = sourceIdentity; self.descriptor = descriptor
        self.fingerprint = sha256(Data("qwen-prefill-start-agreement-v1\n".utf8) + (try canonicalJSONData(descriptor)))
    }

    func boundaryExpectation(for frame: QwenLayerStageFrame) throws -> QwenLayerStageBoundaryWireExpectation {
        guard let step = request.steps.first(where: { $0.frame == frame }) else {
            throw ProbeError("Measurement boundary does not belong to the local prompt timeline")
        }
        return try .init(request: request.request, frame: frame, tokenIDs: step.tokenIDs,
            sourceIdentity: sourceIdentity, hiddenSize: descriptor.hiddenSize, nativeDType: descriptor.nativeDType)
    }

    /// CPU identity only. The native sender must compare its actual receipt to
    /// this value before constructing a selected-token wire packet.
    var consumerIdentity: QwenLayerStageSessionIdentity {
        .init(stageIndex: 1, requestFingerprint: descriptor.requestFingerprint,
            artifactAggregateSHA256: descriptor.artifactAggregateSHA256,
            storageCommitmentSHA256: descriptor.storageCommitmentSHA256,
            bf16ConversionEnabled: descriptor.bf16ConversionEnabled,
            sourceConfigurationSHA256: descriptor.sourceConfigurationSHA256,
            constructionConfigurationSHA256: descriptor.consumerConstructionConfigurationSHA256,
            planFingerprint: descriptor.planFingerprint, stageFingerprint: descriptor.consumerStageFingerprint,
            activationDType: descriptor.nativeDType)
    }
}
