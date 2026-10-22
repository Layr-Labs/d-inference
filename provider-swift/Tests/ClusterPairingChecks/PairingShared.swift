import CryptoKit
import Foundation
import DarkbloomClusterSecurity

/// Test stand-ins shared by the check and its terminal child: a software
/// P-256 identity in place of the Secure Enclave key, a signed test
/// attestation in place of the provider's, and the coordinator's roster bytes
/// written out from darkbloom-platform `ClusterRoster.Canonical`.
struct SoftwareIdentity: ClusterPairingIdentity {
    let key: P256.Signing.PrivateKey
    var identityPublicKey: Data { key.publicKey.x963Representation }

    init(_ key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) { self.key = key }

    /// A key kept in a private file, so a second run signs with the same key (as the Secure Enclave key does).
    init(persistedAt url: URL) throws {
        if let data = try? Data(contentsOf: url) { key = try P256.Signing.PrivateKey(rawRepresentation: data); return }
        key = P256.Signing.PrivateKey()
        FileManager.default.createFile(atPath: url.path, contents: key.rawRepresentation, attributes: [.posixPermissions: 0o600])
    }

    func pairingSignature(for message: Data) throws -> Data { try key.signature(for: message).derRepresentation }
}

enum TestAttestation {
    static let domain = Data("darkbloom-test-attestation\0".utf8)
    static let posture = ClusterPairingPeerPosture(chipName: "Test chip", hardwareModel: "Test1,1", osVersion: "26.0.0",
        sipEnabled: true, secureBootEnabled: true, authenticatedRootEnabled: true)

    static func make(_ identity: SoftwareIdentity, ephemeral: Data) throws -> Data {
        let signature = try identity.pairingSignature(for: domain + identity.identityPublicKey + ephemeral)
        return try JSONSerialization.data(withJSONObject: ["k": identity.identityPublicKey.base64EncodedString(),
            "e": ephemeral.base64EncodedString(), "s": signature.base64EncodedString()], options: [.sortedKeys])
    }

    static func verify(_ data: Data, identityKey: Data, ephemeral: Data) -> ClusterPairingPeerPosture? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              object["k"] == identityKey.base64EncodedString(), object["e"] == ephemeral.base64EncodedString(),
              let signature = object["s"].flatMap({ Data(base64Encoded: $0) }),
              let key = try? P256.Signing.PublicKey(x963Representation: identityKey),
              let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature),
              key.isValidSignature(parsed, for: domain + identityKey + ephemeral) else { return nil }
        return posture
    }
}

enum ReferenceRoster {
    static let domain = Data("darkbloom/cluster-roster/v1\u{0}".utf8)

    static func canonical(clusterID: String, generation: UInt64, members: [(pin: String, identityKey: Data)]) -> Data {
        var bytes = domain
        func u32(_ value: Int) { for shift in stride(from: 24, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) } }
        u32(clusterID.utf8.count); bytes.append(Data(clusterID.utf8))
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: generation >> UInt64(shift))) }
        u32(members.count)
        for member in members {
            bytes.append(hexDecode(member.pin)!)
            u32(member.identityKey.count); bytes.append(member.identityKey)
        }
        return bytes
    }

    static func hexDecode(_ text: String) -> Data? {
        let digits = Array(text.utf8)
        guard digits.count % 2 == 0 else { return nil }
        var data = Data()
        var index = 0
        while index < digits.count {
            guard let byte = UInt8(String(decoding: digits[index..<index + 2], as: UTF8.self), radix: 16) else { return nil }
            data.append(byte); index += 2
        }
        return data
    }
}

enum TestPairing {
    static func participant(_ identity: SoftwareIdentity, name: String = "Test Mac", interface: String = "lo0",
                            generation: UInt64 = 0, clusterID: String? = nil) -> ClusterPairingParticipant {
        ClusterPairingParticipant(identity: identity, name: name, interface: interface,
            attestation: { try TestAttestation.make(identity, ephemeral: $0) },
            knownGeneration: { _ in generation },
            clusterLabel: { local, peer in clusterID ?? ClusterPairingLabel.derived(pins: [local, peer]) })
    }

    static func storeBacked(_ identity: SoftwareIdentity, name: String, store: ClusterPairingStore, clusterID: String? = nil) -> ClusterPairingParticipant {
        .storeBacked(identity: identity, name: name, interface: "lo0", attestation: { try TestAttestation.make(identity, ephemeral: $0) },
                     store: store, clusterID: clusterID)
    }

    static let hooks = ClusterPairingHooks(verifyAttestation: { TestAttestation.verify($0, identityKey: $1, ephemeral: $2) },
        rosterCanonical: { ReferenceRoster.canonical(clusterID: $0, generation: $1, members: $2) })
}
