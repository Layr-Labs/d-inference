import Foundation
import CoreFoundation
import CryptoKit
import DarkbloomClusterProtocol

enum CancellationCase: String, Decodable {
    case startedBeforeFirstToken, afterFirstDecode
}
struct CancellationPeer: Decodable {
    let host: String, user: String, knownHostsFile: String, identityFile: String, installedOwner: String
    let port: Int
}
struct CancellationSettings: Decodable {
    let schema: String, clusterID: String, readyTemplateBase64: String
    let cancellationCase: CancellationCase
    let cancellationEpoch: String, recoveryEpoch: String
    let peers: [CancellationPeer]
    let promptTokenIDs: [Int], expectedTokenIDs: [Int]
    let lifetimeSeconds: Int, startupSeconds: Int, requestSeconds: Int, beforeFirstDelayMilliseconds: Int

    static func parse(_ raw: Data) throws -> Self {
        var framed = raw; if framed.last != 10 { framed.append(10) }
        try validateClusterWorkerEnvelope(framed, commandStream: true)
        guard let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any], Set(object.keys) ==
            Set(["schema", "clusterID", "readyTemplateBase64", "cancellationCase", "cancellationEpoch", "recoveryEpoch",
                 "peers", "promptTokenIDs", "expectedTokenIDs", "lifetimeSeconds", "startupSeconds", "requestSeconds",
                 "beforeFirstDelayMilliseconds"]), let peers = object["peers"] as? [[String: Any]], peers.count == 2,
              peers.allSatisfy({ Set($0.keys) == Set(["host", "user", "port", "knownHostsFile", "identityFile", "installedOwner"]) }) else {
            throw QualificationFailure.invalid("Cancellation configuration fields differ")
        }
        func integer(_ value: Any?) throws {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  !["f", "d"].contains(String(cString: number.objCType)) else {
                throw QualificationFailure.invalid("Exact integer required")
            }
        }
        for key in ["lifetimeSeconds", "startupSeconds", "requestSeconds", "beforeFirstDelayMilliseconds"] { try integer(object[key]) }
        for peer in peers { try integer(peer["port"]) }
        for key in ["promptTokenIDs", "expectedTokenIDs"] {
            guard let values = object[key] as? [Any] else { throw QualificationFailure.invalid("Token array required") }
            for value in values { try integer(value) }
        }
        let result = try JSONDecoder().decode(Self.self, from: raw)
        try result.validate(); return result
    }

    func validate() throws {
        func canonical(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }
        guard schema == "darkbloom_owner_cancellation_recovery_v1", canonical(cancellationEpoch), canonical(recoveryEpoch),
              cancellationEpoch != recoveryEpoch, !clusterID.isEmpty, clusterID.utf8.count <= 128,
              (1...300).contains(lifetimeSeconds), (1...min(90, lifetimeSeconds)).contains(startupSeconds),
              (1...min(120, lifetimeSeconds)).contains(requestSeconds), (100...5000).contains(beforeFirstDelayMilliseconds),
              beforeFirstDelayMilliseconds < requestSeconds * 1000,
              peers.count == 2, promptTokenIDs.count == 8192, expectedTokenIDs.count == 128 else {
            throw QualificationFailure.invalid("Cancellation identity/geometry/deadline outside bounds")
        }
        let template = try qualificationTemplate(readyTemplateBase64)
        guard template.profile.maximumPromptTokens >= 8192, template.profile.maximumOutputTokens >= 128,
              template.profile.maximumChunkTokens >= 512, template.profile.maximumContextTokens >= 8320,
              (promptTokenIDs + expectedTokenIDs).allSatisfy({ $0 >= 0 && $0 < template.profile.vocabularySize }) else {
            throw QualificationFailure.invalid("Template cannot admit fixed 8192/512/128 geometry")
        }
    }
}

func cancellationTokenHash(_ values: [Int]) -> String {
    SHA256.hash(data: Data(values.map(String.init).joined(separator: ",").utf8)).map { String(format: "%02x", $0) }.joined()
}
