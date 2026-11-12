import Foundation
import CoreFoundation
import CryptoKit
import DarkbloomClusterProtocol

struct PeerSettings: Decodable {
    let host: String, user: String, knownHostsFile: String, identityFile: String, installedOwner: String
    let port: Int
}
struct TimingSettings: Decodable {
    let schema: String, cohortLabel: String, policyLabel: String
    let cpuQualification: Bool
    let clusterID: String, readyTemplateBase64: String, membershipEpoch: String
    let peers: [PeerSettings]
    let promptTokenIDs: [Int], stopTokenIDs: [Int], expectedTokenIDs: [Int]
    let outputCount: Int, chunkSize: Int, warmupCount: Int, measuredCount: Int
    let lifetimeSeconds: Int, startupSeconds: Int, requestSeconds: Int

    static func parse(_ raw: Data) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any], Set(object.keys) ==
            Set(["schema", "cohortLabel", "policyLabel", "cpuQualification", "clusterID", "readyTemplateBase64", "peers",
                 "membershipEpoch", "promptTokenIDs", "stopTokenIDs", "expectedTokenIDs", "outputCount", "chunkSize",
                 "warmupCount", "measuredCount", "lifetimeSeconds", "startupSeconds", "requestSeconds"]),
              let peers = object["peers"] as? [[String: Any]], peers.count == 2,
              peers.allSatisfy({ Set($0.keys) == Set(["host", "user", "knownHostsFile", "identityFile", "installedOwner", "port"]) }) else {
            throw QualificationFailure.invalid("Timing controller fields differ")
        }
        for key in ["outputCount", "chunkSize", "warmupCount", "measuredCount", "lifetimeSeconds", "startupSeconds", "requestSeconds"] {
            try requireInteger(object[key])
        }
        for peer in peers { try requireInteger(peer["port"]) }
        for key in ["promptTokenIDs", "stopTokenIDs", "expectedTokenIDs"] {
            guard let values = object[key] as? [Any] else { throw QualificationFailure.invalid("Token array required") }
            for value in values { try requireInteger(value) }
        }
        let value = try JSONDecoder().decode(Self.self, from: raw)
        try value.validate(); return value
    }
    static func requireInteger(_ value: Any?) throws {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)) else {
            throw QualificationFailure.invalid("Native integer field required")
        }
    }
    func validate() throws {
        guard schema == "darkbloom_owner_timing_cohort_v1", peers.count == 2,
              !cohortLabel.isEmpty, cohortLabel.utf8.count <= 64,
              cohortLabel.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              ["serial_v1", "one_chunk_lookahead_v1"].contains(policyLabel),
              (0...1).contains(warmupCount), (1...3).contains(measuredCount), warmupCount + measuredCount <= 4,
              (1...300).contains(lifetimeSeconds), (1...lifetimeSeconds).contains(startupSeconds),
              (1...min(120, lifetimeSeconds)).contains(requestSeconds),
              let epoch = UUID(uuidString: membershipEpoch), epoch.uuidString.lowercased() == membershipEpoch,
              promptTokenIDs.count == 8192, outputCount == 128, chunkSize == 512,
              stopTokenIDs.isEmpty, expectedTokenIDs.count == 128 else {
            throw QualificationFailure.invalid("Timing cohort geometry/identity outside bounds")
        }
        let template = try qualificationTemplate(readyTemplateBase64)
        guard template.profile.maximumPromptTokens >= 8192, template.profile.maximumOutputTokens >= 128,
              template.profile.maximumChunkTokens >= 512, template.profile.maximumContextTokens >= 8320,
              (promptTokenIDs + expectedTokenIDs).allSatisfy({ $0 >= 0 && $0 < template.profile.vocabularySize }) else {
            throw QualificationFailure.invalid("Template cannot admit the fixed timing geometry")
        }
    }
}
func timingTokenHash(_ values: [Int]) -> String {
    SHA256.hash(data: Data(values.map(String.init).joined(separator: ",").utf8)).map { String(format: "%02x", $0) }.joined()
}
