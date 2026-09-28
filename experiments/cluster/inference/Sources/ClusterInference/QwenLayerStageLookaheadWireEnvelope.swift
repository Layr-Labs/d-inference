import Foundation

/// A distinct, closed v2 envelope around the unchanged v1 boundary contract.
/// Expectations come from local admission, never from the received object.
/// Not Decodable: all receive paths must scan bounded original JSON first.
struct QwenLayerStageLookaheadWireEnvelope: Equatable {
    static let version = 2
    static let flow = "prompt_lookahead_one_v1"
    static let maximumEncodedBytes = 16 * 1024

    let boundary: QwenLayerStageBoundaryWireHeader
    private let outerData: Data

    /// Pass the producer's actual native boundary metadata, not a replacement
    /// synthesized from expected fields. Validation precedes sender encoding.
    init(boundary: QwenLayerStageBoundaryWireHeader,
         expected: QwenLayerStageBoundaryWireExpectation) throws {
        try boundary.validate(expected: expected)
        let data = try canonicalJSONData(Content(boundary: boundary))
        try Self.requireByteBound(data)
        self.boundary = boundary
        self.outerData = data
    }

    private init(boundary: QwenLayerStageBoundaryWireHeader, validatedOuterData: Data) {
        self.boundary = boundary
        self.outerData = validatedOuterData
    }

    /// Exact sent/received bytes, including accepted insignificant whitespace.
    /// ACKs bind these bytes; re-encoding the nested object would change identity.
    func encoded() -> Data { outerData }

    static func decode(_ data: Data,
                       expected: QwenLayerStageBoundaryWireExpectation) throws -> Self {
        try requireByteBound(data)
        // This scanner visits the complete nested original input. It rejects
        // duplicate decoded keys and every fractional/exponent number lexeme
        // before Foundation can normalize NSNumber(1.0) or discard duplicates.
        try validateWorkerJSON(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "flow", "boundary"],
              BoundedProbeInput.integer(object["version"]) == version,
              object["flow"] as? String == flow,
              let nested = object["boundary"] as? [String: Any],
              let frame = nested["frame"] as? [String: Any],
              ["version", "byteCount"].allSatisfy({ BoundedProbeInput.integer(nested[$0]) != nil }),
              ["sequence", "tokenOffset", "tokenCount"].allSatisfy({ BoundedProbeInput.integer(frame[$0]) != nil }),
              let shape = nested["shape"] as? [Any], shape.count == 3,
              shape.allSatisfy({ BoundedProbeInput.integer($0) != nil }) else {
            throw ProbeError("Lookahead v2 envelope requires exact version/flow/fields and original integer JSON values")
        }
        // Only now may the nested dictionary be serialized. The unchanged v1
        // strict decoder proves its complete closed schema, types, intrinsic
        // bounds and agreement with independently admitted local expectations.
        let nestedData = try JSONSerialization.data(withJSONObject: nested, options: [.sortedKeys])
        let boundary = try QwenLayerStageBoundaryWireHeader.decode(nestedData, expected: expected)
        return Self(boundary: boundary, validatedOuterData: data)
    }

    private static func requireByteBound(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maximumEncodedBytes else {
            throw ProbeError("Lookahead v2 envelope is empty or exceeds 16 KiB")
        }
    }

    private struct Content: Encodable {
        let version = QwenLayerStageLookaheadWireEnvelope.version
        let flow = QwenLayerStageLookaheadWireEnvelope.flow
        let boundary: QwenLayerStageBoundaryWireHeader
    }
}
