import CryptoKit
import DarkbloomClusterSecurity
import Foundation
import MLX

/// What one protected transfer is, as both ranks expect it locally (S16): the
/// record kind, the request it belongs to, and a digest of the caller's own
/// metadata. Nothing here is learned from received bytes. Every record of a
/// keyed data plane carries one in its authenticated data, so a record of one
/// kind, request or position never opens as another; the record sequence
/// already fixes the order.
public struct CollectiveRecordScope: Sendable {
    let type: ClusterRecordType
    let requestID: UUID?
    let expectationSHA256: Data

    private init(type: ClusterRecordType, requestID: UUID?, expectationSHA256: Data) {
        self.type = type; self.requestID = requestID; self.expectationSHA256 = expectationSHA256
    }

    /// A session record: key confirmation, the load agreements, keep-warm.
    static func session(_ type: ClusterRecordType, _ label: String) -> Self {
        var bytes = Data("darkbloom/collective/session-record/v1\0".utf8)
        bytes.append(type.rawValue); bytes.append(Data(label.utf8))
        return .init(type: type, requestID: nil, expectationSHA256: Data(SHA256.hash(data: bytes)))
    }

    /// A request record, bound to the request and the generation agreement
    /// both ranks proved equal for it.
    static func request(_ type: ClusterRecordType, requestID: UUID, agreementFingerprint: String, _ label: String) -> Self {
        var bytes = Data("darkbloom/collective/request-record/v1\0".utf8)
        bytes.append(type.rawValue); bytes.append(Data(agreementFingerprint.utf8)); bytes.append(0)
        bytes.append(Data(label.utf8))
        return .init(type: type, requestID: requestID, expectationSHA256: Data(SHA256.hash(data: bytes)))
    }

    /// The same record kind and request with a further local label (a part of
    /// a two-transfer message, a segment index).
    func part(_ label: String) -> Self {
        var bytes = Data("darkbloom/collective/record-part/v1\0".utf8)
        bytes.append(expectationSHA256); bytes.append(Data(label.utf8))
        return .init(type: type, requestID: requestID, expectationSHA256: Data(SHA256.hash(data: bytes)))
    }

    /// One record of an array transfer: the array's shape and dtype, which
    /// chunk of how many, and its exact length, all bound.
    func expectation(shape: [Int], dtype: DType, chunk: Int, of chunks: Int,
                     length: Int) throws -> ClusterRecordTransferExpectation {
        var bytes = Data("darkbloom/collective/array-record/v1\0".utf8)
        bytes.append(expectationSHA256)
        bytes.append(Data(String(describing: dtype).utf8)); bytes.append(0)
        for value in shape + [chunk, chunks, length] {
            var big = UInt64(value).bigEndian
            withUnsafeBytes(of: &big) { bytes.append(contentsOf: $0) }
        }
        let context = try ClusterRecordContext(requestID: requestID, type: type,
            expectationSHA256: Data(SHA256.hash(data: bytes)))
        return try .init(context: context, length: .exact(length))
    }
}

/// Qualification only (`DARKBLOOM_CLUSTER_QUALIFICATION_TAMPER=<kind>:<n>`,
/// honoured only with the qualification switches): this rank flips one
/// ciphertext byte of the n-th record of that kind it sends, after sealing,
/// as an attacker on the link would. The peer must refuse it.
public struct CollectiveRecordTamper: Sendable, Equatable {
    public static let environmentName = QwenResidentQualificationSwitches.tamperEnvironmentName
    let type: ClusterRecordType
    let ordinal: Int

    static let names: [String: ClusterRecordType] = [
        "loadAgreement": .loadAgreement, "loadedReady": .loadedReady, "requestAgreement": .requestAgreement,
        "residualHeader": .residualHeader, "residualPayload": .residualPayload, "targetToken": .targetToken,
        "generationDecision": .generationDecision, "acknowledgement": .acknowledgement,
        "requestRetired": .requestRetired, "handoffHeader": .handoffHeader, "handoffState": .handoffState,
        "tokenRelay": .tokenRelay, "relayDecision": .relayDecision, "prefixAgreement": .prefixAgreement,
        "keepWarm": .keepWarm,
    ]

    public static func admit(environment: [String: String]) throws -> Self? {
        guard let text = environment[environmentName] else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let type = names[String(parts[0])], let ordinal = Int(parts[1]),
              String(ordinal) == parts[1], (1...1_000_000).contains(ordinal) else {
            throw ProbeError("\(environmentName) takes <record kind>:<ordinal>, for example residualPayload:3")
        }
        return .init(type: type, ordinal: ordinal)
    }
}

/// Qualification only (`DARKBLOOM_CLUSTER_QUALIFICATION_REKEY=records:<n>`,
/// honoured only with the qualification switches): the data plane's rekey
/// policy with a new key every n records per direction instead of 262,144,
/// so a short request crosses several key generations. Both ranks must be
/// given the same value: the policy is bound into the record keys.
public enum CollectiveRecordRekeyOverride {
    public static let environmentName = QwenResidentQualificationSwitches.rekeyEnvironmentName

    public static func admit(environment: [String: String]) throws -> ClusterRecordRekeyPolicy? {
        guard let text = environment[environmentName] else { return nil }
        do { return try ClusterRecordRekeyPolicy.qualification(text) } catch {
            throw ProbeError("\(environmentName) takes records:<2...\(ClusterRecordRekeyPolicy.dataPlane.records)>")
        }
    }
}
