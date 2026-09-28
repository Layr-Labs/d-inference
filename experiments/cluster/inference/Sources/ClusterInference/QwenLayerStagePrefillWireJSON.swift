import Foundation

/// Scan original bounded bytes before Foundation can normalize numbers or
/// discard duplicates. Known local content supplies the closed schema and all
/// values; semantic canonicalization never makes received request data trusted.
enum QwenLayerStagePrefillWireJSON {
    static func object(_ data: Data, maximumBytes: Int) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= maximumBytes else { throw ProbeError("Prefill wire packet exceeds its byte bound") }
        try validateWorkerJSON(data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProbeError("Prefill wire packet must be a JSON object")
        }
        return object
    }

    static func requireExact<T: Encodable>(_ actual: [String: Any], expected: T) throws {
        let expectedObject = try JSONSerialization.jsonObject(with: canonicalJSONData(expected))
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        guard try JSONSerialization.data(withJSONObject: actual, options: options)
            == JSONSerialization.data(withJSONObject: expectedObject, options: options) else {
            throw ProbeError("Prefill wire fields or values differ from the independently admitted local agreement")
        }
    }
}

/// Prepared after both models are loaded and the agreement is confirmed, before
/// rank zero starts its clock. Both ranks admit this before fresh context creation.
struct QwenLayerStagePrefillStartWirePacket {
    static let maximumEncodedBytes = 8 * 1024
    let agreementFingerprint: String
    private let data: Data

    init(agreement: QwenLayerStagePrefillStartAgreement) throws {
        self.agreementFingerprint = agreement.fingerprint
        self.data = try canonicalJSONData(Content(agreement: agreement))
        guard data.count <= Self.maximumEncodedBytes else { throw ProbeError("Encoded prefill start packet exceeds 8 KiB") }
    }

    private init(agreementFingerprint: String, data: Data) {
        self.agreementFingerprint = agreementFingerprint; self.data = data
    }

    func encoded() -> Data { data }

    static func decode(_ data: Data, expectedAgreement: QwenLayerStagePrefillStartAgreement) throws -> Self {
        let object = try QwenLayerStagePrefillWireJSON.object(data, maximumBytes: maximumEncodedBytes)
        try QwenLayerStagePrefillWireJSON.requireExact(object, expected: Content(agreement: expectedAgreement))
        return Self(agreementFingerprint: expectedAgreement.fingerprint, data: data)
    }

    private struct Content: Encodable {
        let version = QwenLayerStagePrefillMeasurementFlow.version
        let flow = QwenLayerStagePrefillMeasurementFlow.name
        let kind = "start"
        let agreementFingerprint: String
        let agreement: QwenLayerStagePrefillStartAgreement.Descriptor
        init(agreement: QwenLayerStagePrefillStartAgreement) {
            agreementFingerprint = agreement.fingerprint; self.agreement = agreement.descriptor
        }
    }
}
