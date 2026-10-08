import Foundation
import CryptoKit
import DarkbloomClusterProtocol

public enum ClusterConfigurationCodec {
    public static let maximumBytes = 16 * 1024

    /// Accept bounded pretty JSON as input, preserving strings and checking
    /// duplicate keys/integer syntax before Foundation can discard information.
    public static func decode(_ data: Data, capability: ClusterRuntimeCapability,
                              capabilitySHA256: String) throws -> ClusterConfiguration {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ClusterConfigurationError.invalid("Cluster configuration exceeded its byte bound")
        }
        var scan = Data(), quoted = false, escaped = false
        for byte in data {
            if quoted {
                scan.append(byte)
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else {
                if byte == 34 { quoted = true }
                scan.append([9, 10, 13].contains(byte) ? 32 : byte)
            }
        }
        scan.append(10)
        try validateClusterWorkerEnvelope(scan, commandStream: true)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClusterConfigurationError.invalid("Cluster configuration must be an object")
        }
        var expected: Set<String> = ["schema", "clusterID", "memberID", "role", "publicModelID", "capabilitySHA256", "selectedPlanSHA256",
                                     "chunkTokens", "requestTimeoutSeconds", "peers", "coordinator", "trust", "tokenizerFiles"]
        if let schedule = object["prefillSchedule"] {
            guard let name = schedule as? String, ClusterPrefillSchedule(rawValue: name) != nil else {
                throw ClusterConfigurationError.invalid("Unknown or malformed prefill schedule")
            }
            expected.insert("prefillSchedule")
        }
        if let transport = object["transport"] {
            guard let name = transport as? String, ClusterConfiguration.Transport(rawValue: name) != nil else {
                throw ClusterConfigurationError.invalid("Unknown or malformed cluster transport")
            }
            expected.insert("transport")
        }
        if let attachment = object["nativeMember"] {
            guard let fields = attachment as? [String: Any] else {
                throw ClusterConfigurationError.invalid("Native member attachment must be a non-null object")
            }
            try ClusterNativeMemberAttachment.validateObject(fields)
            expected.insert("nativeMember")
        }
        try keys(object, expected)
        guard let peers = object["peers"] as? [[String: Any]], peers.count == 2,
              let coordinator = object["coordinator"] as? [String: Any],
              let trust = object["trust"] as? [String: Any],
              let files = object["tokenizerFiles"] as? [[String: Any]], (1...16).contains(files.count) else {
            throw ClusterConfigurationError.invalid("Malformed cluster configuration objects")
        }
        for peer in peers {
            try keys(peer, ["id", "rank", "host", "port", "user", "ownerExecutable", "workerExecutable", "modelDirectory", "runtimeBinarySHA256", "jacclDevice"])
        }
        try keys(coordinator, ["address", "port"])
        try keys(trust, ["identityFile", "knownHostsFile", "knownHostsSHA256"])
        for file in files { try keys(file, ["path", "sha256", "purpose"]) }
        let value = try JSONDecoder().decode(ClusterConfiguration.self, from: data)
        try value.validate(capability: capability, rawCapabilitySHA256: capabilitySHA256)
        return value
    }

    public static func encode(_ value: ClusterConfiguration, capability: ClusterRuntimeCapability,
                              capabilitySHA256: String) throws -> Data {
        try value.validate(capability: capability, rawCapabilitySHA256: capabilitySHA256)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value); data.append(10)
        guard data.count <= maximumBytes else { throw ClusterConfigurationError.invalid("Cluster configuration exceeded its byte bound") }
        return data
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func keys(_ value: [String: Any], _ expected: Set<String>) throws {
        guard Set(value.keys) == expected else { throw ClusterConfigurationError.invalid("Unknown or missing cluster configuration fields") }
    }
}
