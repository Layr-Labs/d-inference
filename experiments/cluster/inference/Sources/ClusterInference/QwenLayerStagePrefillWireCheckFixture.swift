import Foundation

/// Fabricated CPU metadata only, confined to codec checks. A native sender must
/// instead pass the actual receipt and actual boundary metadata from its context.
struct QwenLayerStagePrefillWireCheckFixture {
    let agreement: QwenLayerStagePrefillStartAgreement
    let start: QwenLayerStagePrefillStartWirePacket
    let first: QwenLayerStagePrefillBoundaryEnvelope
    let final: QwenLayerStagePrefillBoundaryEnvelope
    let selection: QwenLayerStagePrefillTokenReceipt
    let token: QwenLayerStagePrefillFirstTokenWirePacket

    init(policy: QwenLayerStagePrefillMeasurementFlow.SchedulingPolicy = .serial,
         dtype: String = "bfloat16", promptCount: Int = 65, chunkSize: Int = 32,
         requestID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
         artifactDigit: String = "b") throws {
        let source = try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: String(repeating: "a", count: 64),
            artifactAggregateSHA256: String(repeating: artifactDigit, count: 64),
            storageCommitmentSHA256: String(repeating: "c", count: 64), planFingerprint: String(repeating: "d", count: 64),
            producerStageFingerprint: String(repeating: "e", count: 64))
        let spec = try QwenLayerStageRequestSpec(requestID: requestID, promptCount: promptCount,
            chunkSize: chunkSize, outputCount: 1)
        let request = try QwenLayerStageRecordedRequest(request: spec, vocabularySize: 256,
            prompt: Array(0..<promptCount), teacher: [])
        let agreement = try QwenLayerStagePrefillStartAgreement(epoch: String(repeating: "1", count: 32),
            request: request, sourceIdentity: source, consumerStageFingerprint: String(repeating: "f", count: 64),
            producerConstructionConfigurationSHA256: String(repeating: "2", count: 64),
            consumerConstructionConfigurationSHA256: String(repeating: "3", count: 64),
            bf16ConversionEnabled: false, hiddenSize: 128, nativeDType: dtype, logitsDType: dtype,
            schedulingPolicy: policy)
        func envelope(_ frame: QwenLayerStageFrame) throws -> QwenLayerStagePrefillBoundaryEnvelope {
            let expected = try agreement.boundaryExpectation(for: frame)
            let header = try QwenLayerStageBoundaryWireHeader(expected: expected,
                payloadSHA256: String(repeating: "4", count: 64))
            return try .init(boundary: header, agreement: agreement)
        }
        let final = try envelope(request.steps.last!.frame)
        let selection = QwenLayerStagePrefillTokenReceipt(identity: agreement.consumerIdentity,
            recordedRequestFingerprint: request.fingerprint, frame: request.steps.last!.frame,
            committedTokens: promptCount, vocabularySize: 256, outputOrdinal: 0,
            selectionPolicy: QwenLayerStagePrefillMeasurementFlow.selectionPolicy, tokenID: 7,
            logitsShape: [1, 256], logitsDType: dtype, selectionDType: "uint32", allLogitsFinite: true)
        self.agreement = agreement; self.start = try .init(agreement: agreement)
        self.first = try envelope(request.steps[0].frame); self.final = final; self.selection = selection
        self.token = try .init(selection: selection, agreement: agreement, finalBoundary: final)
    }
}
