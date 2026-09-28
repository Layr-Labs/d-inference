import Foundation

/// Selected scalar only. This packet carries no logits, cache state or models.
struct QwenLayerStageProfiledPrefillFirstTokenWirePacket {
    static let maximumEncodedBytes = 4 * 1024
    let agreementFingerprint: String
    let finalBoundaryEnvelopeFingerprint: String
    let finalBoundaryWireBytesSHA256: String
    let tokenID: Int
    private let data: Data
    var wireBytesSHA256: String { sha256(data) }
    var fingerprint: String {
        QwenLayerStageProfiledWireHash.fingerprint(domain: QwenLayerStageProfiledWireHash.token, bytes: data)
    }

    /// Validate actual local selection evidence. A future native producer must
    /// not substitute fabricated expected receipts for its observed identity,
    /// frontier, dtype, finiteness or token before entering this initializer.
    init(selection: QwenLayerStagePrefillTokenReceipt,
         agreement: QwenLayerStageProfiledPrefillStartAgreement,
         finalBoundary: QwenLayerStageProfiledPrefillBoundaryEnvelope) throws {
        try finalBoundary.requireFinal(for: agreement)
        guard selection.identity == agreement.consumerIdentity,
              selection.recordedRequestFingerprint == agreement.request.fingerprint,
              selection.frame == agreement.request.steps.last?.frame,
              selection.committedTokens == agreement.request.request.promptCount,
              selection.vocabularySize == agreement.request.vocabularySize, selection.outputOrdinal == 0,
              selection.selectionPolicy == QwenLayerStageProfiledPrefillMeasurementFlow.selectionPolicy,
              (0..<agreement.request.vocabularySize).contains(selection.tokenID),
              selection.logitsShape == [1, agreement.request.vocabularySize],
              selection.logitsDType == agreement.descriptor.logitsDType,
              selection.selectionDType == "uint32", selection.allLogitsFinite else {
            throw ProbeError("Actual profiled token selection differs from admitted source/history/frontier/native arithmetic")
        }
        agreementFingerprint = agreement.fingerprint
        finalBoundaryEnvelopeFingerprint = finalBoundary.fingerprint
        finalBoundaryWireBytesSHA256 = finalBoundary.wireBytesSHA256; tokenID = selection.tokenID
        data = try canonicalJSONData(Content(agreement: agreement, finalBoundary: finalBoundary, tokenID: selection.tokenID))
        guard data.count <= Self.maximumEncodedBytes else { throw ProbeError("Profiled token packet exceeds 4 KiB") }
    }

    private init(agreement: QwenLayerStageProfiledPrefillStartAgreement,
                 finalBoundary: QwenLayerStageProfiledPrefillBoundaryEnvelope, tokenID: Int, data: Data) {
        agreementFingerprint = agreement.fingerprint
        finalBoundaryEnvelopeFingerprint = finalBoundary.fingerprint
        finalBoundaryWireBytesSHA256 = finalBoundary.wireBytesSHA256
        self.tokenID = tokenID; self.data = data
    }

    func encoded() -> Data { data }

    static func decode(_ data: Data, expectedAgreement: QwenLayerStageProfiledPrefillStartAgreement,
                       finalBoundary: QwenLayerStageProfiledPrefillBoundaryEnvelope) throws -> Self {
        try finalBoundary.requireFinal(for: expectedAgreement)
        let object = try QwenLayerStagePrefillWireJSON.object(data, maximumBytes: maximumEncodedBytes)
        guard let token = BoundedProbeInput.integer(object["tokenID"]),
              (0..<expectedAgreement.request.vocabularySize).contains(token) else {
            throw ProbeError("Profiled token must be an original integer inside the local vocabulary")
        }
        try QwenLayerStagePrefillWireJSON.requireExact(object,
            expected: Content(agreement: expectedAgreement, finalBoundary: finalBoundary, tokenID: token))
        return Self(agreement: expectedAgreement, finalBoundary: finalBoundary, tokenID: token, data: data)
    }

    private struct Content: Encodable {
        let version = QwenLayerStageProfiledPrefillMeasurementFlow.version
        let flow = QwenLayerStageProfiledPrefillMeasurementFlow.name
        let kind = "first_selected_token"
        let profile: QwenLayerStagePrefillProfile
        let profileFingerprint: String
        let agreementFingerprint: String
        let epoch: String
        let requestFingerprint: String
        let recordedRequestFingerprint: String
        let consumerStageFingerprint: String
        let finalBoundaryEnvelopeFingerprint: String
        let finalBoundaryWireBytesSHA256: String
        let frame: QwenLayerStageFrame
        let committedTokens: Int
        let vocabularySize: Int
        let tokenOrdinal = 0
        let selectionPolicy = QwenLayerStageProfiledPrefillMeasurementFlow.selectionPolicy
        let tokenID: Int
        let logitsShape: [Int]
        let logitsDType: String
        let selectionDType = "uint32"
        let allLogitsFinite = true

        init(agreement: QwenLayerStageProfiledPrefillStartAgreement,
             finalBoundary: QwenLayerStageProfiledPrefillBoundaryEnvelope, tokenID: Int) {
            let profile = agreement.request.request.profile
            self.profile = profile; profileFingerprint = profile.fingerprint
            agreementFingerprint = agreement.fingerprint; epoch = agreement.descriptor.epoch
            requestFingerprint = agreement.request.request.fingerprint
            recordedRequestFingerprint = agreement.request.fingerprint
            consumerStageFingerprint = agreement.descriptor.consumerStageFingerprint
            finalBoundaryEnvelopeFingerprint = finalBoundary.fingerprint
            finalBoundaryWireBytesSHA256 = finalBoundary.wireBytesSHA256; frame = finalBoundary.boundary.frame
            committedTokens = agreement.request.request.promptCount; vocabularySize = agreement.request.vocabularySize
            self.tokenID = tokenID; logitsShape = [1, agreement.request.vocabularySize]
            logitsDType = agreement.descriptor.logitsDType
        }
    }
}

/// Permission for the receiver's post-stop diagnostic/teardown work. The native
/// owner must send only after recording the first-token stop timestamp.
enum QwenLayerStageProfiledPrefillPostStopAcknowledgement {
    static let elements = 64
    static let byteCount = 256

    static func values(token: QwenLayerStageProfiledPrefillFirstTokenWirePacket) -> [Int32] {
        let text = [QwenLayerStageProfiledWireHash.postStop, QwenLayerStageProfiledPrefillMeasurementFlow.name,
            token.agreementFingerprint, "post_stop_release", token.fingerprint, token.wireBytesSHA256].joined(separator: "|")
        return sha256(Data(text.utf8)).utf8.map(Int32.init)
    }

    static func validate(_ actual: [Int32], token: QwenLayerStageProfiledPrefillFirstTokenWirePacket) throws {
        guard actual == values(token: token) else {
            throw ProbeError("Profiled post-stop release differs from exact v4 token bytes/domain/agreement")
        }
    }
}
