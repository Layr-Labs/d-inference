import Foundation

/// Only the selected target token and bounded identity metadata cross this wire.
/// No logit vector, CPU state snapshot, model object or teacher input is carried.
struct QwenLayerStagePrefillFirstTokenWirePacket {
    static let maximumEncodedBytes = 4 * 1024
    let agreementFingerprint: String
    let finalBoundaryEnvelopeSHA256: String
    let tokenID: Int
    private let data: Data
    var fingerprint: String { sha256(data) }

    /// Validate actual CPU selection evidence first. Never synthesize an expected
    /// receipt that discards a native producer's disagreeing source or frontier.
    init(selection: QwenLayerStagePrefillTokenReceipt, agreement: QwenLayerStagePrefillStartAgreement,
         finalBoundary: QwenLayerStagePrefillBoundaryEnvelope) throws {
        try finalBoundary.requireFinal(for: agreement)
        guard selection.identity == agreement.consumerIdentity,
              selection.recordedRequestFingerprint == agreement.request.fingerprint,
              selection.frame == agreement.request.steps.last?.frame,
              selection.committedTokens == agreement.request.request.promptCount,
              selection.vocabularySize == agreement.request.vocabularySize,
              selection.outputOrdinal == 0,
              selection.selectionPolicy == QwenLayerStagePrefillMeasurementFlow.selectionPolicy,
              (0..<agreement.request.vocabularySize).contains(selection.tokenID),
              selection.logitsShape == [1, agreement.request.vocabularySize],
              selection.logitsDType == agreement.descriptor.logitsDType,
              selection.selectionDType == "uint32", selection.allLogitsFinite else {
            throw ProbeError("Actual native token receipt differs from the agreed source, request, final frontier or selection policy")
        }
        self.agreementFingerprint = agreement.fingerprint
        self.finalBoundaryEnvelopeSHA256 = finalBoundary.fingerprint; self.tokenID = selection.tokenID
        self.data = try canonicalJSONData(Content(agreement: agreement, finalBoundary: finalBoundary, tokenID: selection.tokenID))
        guard data.count <= Self.maximumEncodedBytes else { throw ProbeError("Encoded first-token packet exceeds 4 KiB") }
    }

    private init(agreementFingerprint: String, finalBoundaryEnvelopeSHA256: String, tokenID: Int, data: Data) {
        self.agreementFingerprint = agreementFingerprint; self.finalBoundaryEnvelopeSHA256 = finalBoundaryEnvelopeSHA256
        self.tokenID = tokenID; self.data = data
    }

    func encoded() -> Data { data }

    static func decode(_ data: Data, expectedAgreement: QwenLayerStagePrefillStartAgreement,
                       finalBoundary: QwenLayerStagePrefillBoundaryEnvelope) throws -> Self {
        try finalBoundary.requireFinal(for: expectedAgreement)
        let object = try QwenLayerStagePrefillWireJSON.object(data, maximumBytes: maximumEncodedBytes)
        guard let token = BoundedProbeInput.integer(object["tokenID"]),
              (0..<expectedAgreement.request.vocabularySize).contains(token) else {
            throw ProbeError("First-token return requires an original integer inside the agreed vocabulary")
        }
        try QwenLayerStagePrefillWireJSON.requireExact(object,
            expected: Content(agreement: expectedAgreement, finalBoundary: finalBoundary, tokenID: token))
        return Self(agreementFingerprint: expectedAgreement.fingerprint,
            finalBoundaryEnvelopeSHA256: finalBoundary.fingerprint, tokenID: token, data: data)
    }

    private struct Content: Encodable {
        let version = QwenLayerStagePrefillMeasurementFlow.version
        let flow = QwenLayerStagePrefillMeasurementFlow.name
        let kind = "first_selected_token"
        let agreementFingerprint: String
        let epoch: String
        let requestFingerprint: String
        let recordedRequestFingerprint: String
        let consumerStageFingerprint: String
        let finalBoundaryEnvelopeSHA256: String
        let frame: QwenLayerStageFrame
        let committedTokens: Int
        let vocabularySize: Int
        let tokenOrdinal = 0
        let selectionPolicy = QwenLayerStagePrefillMeasurementFlow.selectionPolicy
        let tokenID: Int
        let logitsShape: [Int]
        let logitsDType: String
        let selectionDType = "uint32"
        let allLogitsFinite = true

        init(agreement: QwenLayerStagePrefillStartAgreement,
             finalBoundary: QwenLayerStagePrefillBoundaryEnvelope, tokenID: Int) {
            agreementFingerprint = agreement.fingerprint; epoch = agreement.descriptor.epoch
            requestFingerprint = agreement.request.request.fingerprint
            recordedRequestFingerprint = agreement.request.fingerprint
            consumerStageFingerprint = agreement.descriptor.consumerStageFingerprint
            finalBoundaryEnvelopeSHA256 = finalBoundary.fingerprint; frame = finalBoundary.boundary.frame
            committedTokens = agreement.request.request.promptCount; vocabularySize = agreement.request.vocabularySize
            self.tokenID = tokenID; logitsShape = [1, agreement.request.vocabularySize]
            logitsDType = agreement.descriptor.logitsDType
        }
    }
}

/// Sent only AFTER rank zero recorded its first-token stop timestamp. Rank one
/// waits for it before teardown, keeping teardown outside that measured interval.
/// This ACK and subsequent retirement are separate post-stop work.
enum QwenLayerStagePrefillPostStopAcknowledgement {
    static let elements = 64
    static let byteCount = 256

    static func values(token: QwenLayerStagePrefillFirstTokenWirePacket) -> [Int32] {
        let identity = "qwen-prefill-post-stop-v1|\(QwenLayerStagePrefillMeasurementFlow.name)|\(token.agreementFingerprint)|post_stop_release|\(token.fingerprint)"
        return sha256(Data(identity.utf8)).utf8.map(Int32.init)
    }

    static func validate(_ actual: [Int32], token: QwenLayerStagePrefillFirstTokenWirePacket) throws {
        guard actual == values(token: token) else {
            throw ProbeError("Prefill post-stop release differs from the exact token packet and agreement")
        }
    }
}
