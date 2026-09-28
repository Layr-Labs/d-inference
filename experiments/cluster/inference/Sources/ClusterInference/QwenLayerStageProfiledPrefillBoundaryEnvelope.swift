import Foundation

/// Pure v4 only. Preserve original encoded bytes, including harmless whitespace:
/// ACKs and token packets bind those bytes under the new domain, not a re-encode.
struct QwenLayerStageProfiledPrefillBoundaryEnvelope {
    static let maximumEncodedBytes = 16 * 1024
    let agreementFingerprint: String
    let boundary: QwenLayerStageProfiledBoundaryWireHeader
    private let data: Data
    var wireBytesSHA256: String { sha256(data) }
    var fingerprint: String {
        QwenLayerStageProfiledWireHash.fingerprint(domain: QwenLayerStageProfiledWireHash.boundary, bytes: data)
    }

    init(boundary: QwenLayerStageProfiledBoundaryWireHeader,
         agreement: QwenLayerStageProfiledPrefillStartAgreement) throws {
        try boundary.validate(expected: agreement.boundaryExpectation(for: boundary.frame))
        self.agreementFingerprint = agreement.fingerprint; self.boundary = boundary
        data = try canonicalJSONData(Content(agreementFingerprint: agreement.fingerprint, boundary: boundary))
        guard data.count <= Self.maximumEncodedBytes else { throw ProbeError("Profiled boundary envelope exceeds 16 KiB") }
    }

    private init(agreementFingerprint: String, boundary: QwenLayerStageProfiledBoundaryWireHeader, data: Data) {
        self.agreementFingerprint = agreementFingerprint; self.boundary = boundary; self.data = data
    }

    func encoded() -> Data { data }

    static func decode(_ data: Data, agreement: QwenLayerStageProfiledPrefillStartAgreement,
                       expectedFrame: QwenLayerStageFrame) throws -> Self {
        let object = try QwenLayerStagePrefillWireJSON.object(data, maximumBytes: maximumEncodedBytes)
        guard Set(object.keys) == ["version", "flow", "kind", "agreementFingerprint", "boundary"],
              BoundedProbeInput.integer(object["version"]) == QwenLayerStageProfiledPrefillMeasurementFlow.version,
              object["flow"] as? String == QwenLayerStageProfiledPrefillMeasurementFlow.name,
              object["kind"] as? String == "boundary", object["agreementFingerprint"] as? String == agreement.fingerprint,
              let nested = object["boundary"] as? [String: Any] else {
            throw ProbeError("Profiled boundary envelope changes flow, agreement or closed outer fields")
        }
        // Preserve integer/bool distinctions before Foundation reserialization.
        // The raw scanner above already rejected fractional/exponent syntax.
        guard let frame = nested["frame"] as? [String: Any],
              ["version", "byteCount"].allSatisfy({ BoundedProbeInput.integer(nested[$0]) != nil }),
              ["sequence", "tokenOffset", "tokenCount"].allSatisfy({ BoundedProbeInput.integer(frame[$0]) != nil }),
              let shape = nested["shape"] as? [Any], shape.count == 3,
              shape.allSatisfy({ BoundedProbeInput.integer($0) != nil }) else {
            throw ProbeError("Profiled boundary dimensions/counts must retain original integer types")
        }
        let nestedData = try JSONSerialization.data(withJSONObject: nested, options: [.sortedKeys, .withoutEscapingSlashes])
        let boundary = try QwenLayerStageProfiledBoundaryWireHeader.decode(nestedData,
            expected: agreement.boundaryExpectation(for: expectedFrame))
        return Self(agreementFingerprint: agreement.fingerprint, boundary: boundary, data: data)
    }

    func requireFinal(for agreement: QwenLayerStageProfiledPrefillStartAgreement) throws {
        guard agreementFingerprint == agreement.fingerprint,
              boundary.frame == agreement.request.steps.last?.frame, boundary.frame.finalPromptChunk else {
            throw ProbeError("Profiled token requires the exact admitted final prompt boundary")
        }
        try boundary.validate(expected: agreement.boundaryExpectation(for: boundary.frame))
    }

    private struct Content: Encodable {
        let version = QwenLayerStageProfiledPrefillMeasurementFlow.version
        let flow = QwenLayerStageProfiledPrefillMeasurementFlow.name
        let kind = "boundary"
        let agreementFingerprint: String
        let boundary: QwenLayerStageProfiledBoundaryWireHeader
    }
}

enum QwenLayerStageProfiledPrefillBoundaryAcknowledgement {
    enum Phase: String, CaseIterable { case ready, received, consumed }
    static let elements = 64
    static let byteCount = 256

    static func values(envelope: QwenLayerStageProfiledPrefillBoundaryEnvelope, phase: Phase) -> [Int32] {
        let text = [QwenLayerStageProfiledWireHash.boundaryACK, QwenLayerStageProfiledPrefillMeasurementFlow.name,
            envelope.agreementFingerprint, phase.rawValue, envelope.fingerprint, envelope.wireBytesSHA256].joined(separator: "|")
        return sha256(Data(text.utf8)).utf8.map(Int32.init)
    }

    static func validate(_ actual: [Int32], envelope: QwenLayerStageProfiledPrefillBoundaryEnvelope, phase: Phase) throws {
        guard actual == values(envelope: envelope, phase: phase) else {
            throw ProbeError("Profiled boundary ACK differs from exact v4 bytes, domain, agreement or phase")
        }
    }
}
