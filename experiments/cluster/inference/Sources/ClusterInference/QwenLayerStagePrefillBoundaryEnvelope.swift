import Foundation

/// Pure v3 envelope only; no receive allocation, native transport or schedule.
/// Both scheduling policies retain the same three boundary ACK phases.
struct QwenLayerStagePrefillBoundaryEnvelope {
    static let maximumEncodedBytes = 16 * 1024
    let agreementFingerprint: String
    let boundary: QwenLayerStageBoundaryWireHeader
    private let data: Data
    var fingerprint: String { sha256(data) }

    init(boundary: QwenLayerStageBoundaryWireHeader,
         agreement: QwenLayerStagePrefillStartAgreement) throws {
        try boundary.validate(expected: agreement.boundaryExpectation(for: boundary.frame))
        self.agreementFingerprint = agreement.fingerprint; self.boundary = boundary
        self.data = try canonicalJSONData(Content(agreementFingerprint: agreement.fingerprint, boundary: boundary))
        guard data.count <= Self.maximumEncodedBytes else { throw ProbeError("Encoded prefill boundary exceeds 16 KiB") }
    }

    private init(agreementFingerprint: String, boundary: QwenLayerStageBoundaryWireHeader, data: Data) {
        self.agreementFingerprint = agreementFingerprint; self.boundary = boundary; self.data = data
    }

    func encoded() -> Data { data }

    static func decode(_ data: Data, agreement: QwenLayerStagePrefillStartAgreement,
                       expectedFrame: QwenLayerStageFrame) throws -> Self {
        let object = try QwenLayerStagePrefillWireJSON.object(data, maximumBytes: maximumEncodedBytes)
        guard Set(object.keys) == ["version", "flow", "kind", "agreementFingerprint", "boundary"],
              BoundedProbeInput.integer(object["version"]) == QwenLayerStagePrefillMeasurementFlow.version,
              object["flow"] as? String == QwenLayerStagePrefillMeasurementFlow.name,
              object["kind"] as? String == "boundary", object["agreementFingerprint"] as? String == agreement.fingerprint,
              let nested = object["boundary"] as? [String: Any],
              let frame = nested["frame"] as? [String: Any],
              ["version", "byteCount"].allSatisfy({ BoundedProbeInput.integer(nested[$0]) != nil }),
              ["sequence", "tokenOffset", "tokenCount"].allSatisfy({ BoundedProbeInput.integer(frame[$0]) != nil }),
              let shape = nested["shape"] as? [Any], shape.count == 3,
              shape.allSatisfy({ BoundedProbeInput.integer($0) != nil }) else {
            throw ProbeError("Measurement boundary has incompatible flow, agreement, fields or original integer types")
        }
        let nestedData = try JSONSerialization.data(withJSONObject: nested, options: [.sortedKeys])
        let boundary = try QwenLayerStageBoundaryWireHeader.decode(nestedData,
            expected: agreement.boundaryExpectation(for: expectedFrame))
        return Self(agreementFingerprint: agreement.fingerprint, boundary: boundary, data: data)
    }

    func requireFinal(for agreement: QwenLayerStagePrefillStartAgreement) throws {
        guard agreementFingerprint == agreement.fingerprint,
              boundary.frame == agreement.request.steps.last?.frame,
              boundary.frame.finalPromptChunk else { throw ProbeError("Token return requires this agreement's exact final prompt boundary") }
        try boundary.validate(expected: agreement.boundaryExpectation(for: boundary.frame))
    }

    private struct Content: Encodable {
        let version = QwenLayerStagePrefillMeasurementFlow.version
        let flow = QwenLayerStagePrefillMeasurementFlow.name
        let kind = "boundary"
        let agreementFingerprint: String
        let boundary: QwenLayerStageBoundaryWireHeader
    }
}

enum QwenLayerStagePrefillBoundaryAcknowledgement {
    enum Phase: String, CaseIterable { case ready, received, consumed }
    static let elements = 64
    static let byteCount = 256

    static func values(envelope: QwenLayerStagePrefillBoundaryEnvelope, phase: Phase) -> [Int32] {
        let identity = "qwen-stage-ack-v3|\(QwenLayerStagePrefillMeasurementFlow.name)|\(envelope.agreementFingerprint)|\(phase.rawValue)|\(envelope.fingerprint)"
        return sha256(Data(identity.utf8)).utf8.map(Int32.init)
    }

    static func validate(_ actual: [Int32], envelope: QwenLayerStagePrefillBoundaryEnvelope, phase: Phase) throws {
        guard actual == values(envelope: envelope, phase: phase) else {
            throw ProbeError("Prefill boundary ACK differs from the exact v3 envelope, agreement or phase")
        }
    }
}
