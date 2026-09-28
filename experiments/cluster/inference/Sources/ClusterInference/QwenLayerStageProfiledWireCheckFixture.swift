import Foundation

/// Fabricated CPU metadata only; no model, native array, IO, clock or native allocation.
struct QwenLayerStageProfiledWireCheckFixture {
    let agreement: QwenLayerStageProfiledPrefillStartAgreement
    let start: QwenLayerStageProfiledPrefillStartWirePacket
    let first: QwenLayerStageProfiledPrefillBoundaryEnvelope
    let final: QwenLayerStageProfiledPrefillBoundaryEnvelope
    let selection: QwenLayerStagePrefillTokenReceipt
    let token: QwenLayerStageProfiledPrefillFirstTokenWirePacket

    init(policy: QwenLayerStageProfiledPrefillMeasurementFlow.SchedulingPolicy = .serial,
         dtype: String = "bfloat16", promptCount: Int = 8192, chunkSize: Int = 512, hiddenSize: Int = 128,
         requestID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
         artifactDigit: String = "b", tokenShift: Int = 0, arithmeticDigit: String = "5") throws {
        let source = try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: String(repeating: "a", count: 64),
            artifactAggregateSHA256: String(repeating: artifactDigit, count: 64),
            storageCommitmentSHA256: String(repeating: "c", count: 64), planFingerprint: String(repeating: "d", count: 64),
            producerStageFingerprint: String(repeating: "e", count: 64))
        let spec = try QwenLayerStageProfiledPrefillRequestSpec(profile: .longPrefill8KV1, requestID: requestID,
            batchSize: 1, promptCount: promptCount, chunkSize: chunkSize, outputCount: 1)
        let request = try QwenLayerStageProfiledPrefillRecordedRequest(request: spec, vocabularySize: 256,
            prompt: (0..<promptCount).map { ($0 + tokenShift) % 256 }, teacher: [])
        let agreement = try QwenLayerStageProfiledPrefillStartAgreement(epoch: String(repeating: "1", count: 32),
            request: request, sourceIdentity: source, consumerStageFingerprint: String(repeating: "f", count: 64),
            producerConstructionConfigurationSHA256: String(repeating: "2", count: 64),
            consumerConstructionConfigurationSHA256: String(repeating: "3", count: 64),
            bf16ConversionEnabled: false, arithmeticEnvironmentSHA256: String(repeating: arithmeticDigit, count: 64),
            hiddenSize: hiddenSize, nativeDType: dtype, logitsDType: dtype,
            schedulingPolicy: policy)
        func envelope(_ frame: QwenLayerStageFrame) throws -> QwenLayerStageProfiledPrefillBoundaryEnvelope {
            let expected = try agreement.boundaryExpectation(for: frame)
            let header = try QwenLayerStageProfiledBoundaryWireHeader(expected: expected,
                payloadSHA256: String(repeating: "4", count: 64))
            return try .init(boundary: header, agreement: agreement)
        }
        let final = try envelope(request.steps.last!.frame)
        let selection = QwenLayerStagePrefillTokenReceipt(identity: agreement.consumerIdentity,
            recordedRequestFingerprint: request.fingerprint, frame: request.steps.last!.frame,
            committedTokens: promptCount, vocabularySize: 256, outputOrdinal: 0,
            selectionPolicy: QwenLayerStageProfiledPrefillMeasurementFlow.selectionPolicy, tokenID: 7,
            logitsShape: [1, 256], logitsDType: dtype, selectionDType: "uint32", allLogitsFinite: true)
        self.agreement = agreement; self.start = try .init(agreement: agreement)
        self.first = try envelope(request.steps[0].frame); self.final = final; self.selection = selection
        self.token = try .init(selection: selection, agreement: agreement, finalBoundary: final)
    }
}

struct QwenLayerStageProfiledWireChecks {
    var accepted = 0
    var rejected: [String] = []

    mutating func reject(_ label: String, _ body: () throws -> Void) throws {
        do { try body() } catch { rejected.append(label); return }
        throw ProbeError("Profiled wire fixture admitted " + label)
    }

    static func changed(_ data: Data, _ mutate: (inout [String: Any]) -> Void) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        mutate(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func replaced(_ data: Data, _ old: String, _ new: String) throws -> Data {
        let text = String(decoding: data, as: UTF8.self)
        guard text.contains(old) else { throw ProbeError("Profiled wire fixture replacement missed its target") }
        return Data(text.replacingOccurrences(of: old, with: new).utf8)
    }
}
