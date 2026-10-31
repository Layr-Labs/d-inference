import CryptoKit
import DarkbloomClusterRemote
import DarkbloomClusterSecurity
import Foundation

/// The provider's half of the pairing ceremony (S17): this Mac's Secure
/// Enclave key (the attestation signer, so the pin the other Mac stores is the
/// pin the coordinator derives from this Mac's attestation), its attestation
/// bound to the ceremony's ephemeral key, the verification of the other Mac's
/// attestation, and the roster bytes the coordinator checks.
public enum ClusterPairingProvider {
    /// An attestation older or newer than this is refused.
    static let attestationSkewSeconds: Double = 600

    public enum Failure: Error, CustomStringConvertible {
        case noSecureEnclaveKey
        case ephemeralKey

        public var description: String {
            switch self {
            case .noSecureEnclaveKey: return "This Mac has no usable Secure Enclave signing key."
            case .ephemeralKey:
                return "This build signs with a key that lasts one process (no keychain entitlement), so a pin would not survive a restart. "
                    + "Use the signed release build" + Self.debugHint
            }
        }

        #if DEBUG
        static let debugHint = ", or set DARKBLOOM_DEBUG_SE_KEY_FILE in this debug build."
        #else
        static let debugHint = "."
        #endif
    }

    /// The attestation signer as the ceremony's identity.
    struct SignerIdentity: ClusterPairingIdentity {
        let signer: any AttestationSigner
        let identityPublicKey: Data

        init(_ signer: any AttestationSigner) throws {
            guard let raw = Data(base64Encoded: signer.publicKeyBase64), raw.count == 64 else { throw Failure.noSecureEnclaveKey }
            self.signer = signer; identityPublicKey = Data([4]) + raw
        }

        func pairingSignature(for message: Data) throws -> Data { try signer.sign(message) }
    }

    /// This Mac's pairing identity; refuses a key that would not survive a restart.
    public static func identity() throws -> any ClusterPairingIdentity {
        guard let chosen = ProviderLoop.clusterPairingSigner() else { throw Failure.noSecureEnclaveKey }
        guard chosen.persistent else { throw Failure.ephemeralKey }
        return try SignerIdentity(chosen.signer)
    }

    /// "Apple M3 Ultra, 256 GB": what the other Mac shows. Never a host name.
    public static func displayName(chipName: String) -> String {
        let gigabytes = ProcessInfo.processInfo.physicalMemory / (1 << 30)
        let chip = chipName.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7F }.map(String.init).joined()
        return String("\(chip.isEmpty ? "Mac" : chip), \(gigabytes) GB".prefix(ClusterPairingPolicy.maximumNameBytes))
    }

    public static func participant(identity: any ClusterPairingIdentity, chipName: String, interface: String,
                                   store: ClusterPairingStore, clusterID: String?) -> ClusterPairingParticipant {
        let signer = (identity as? SignerIdentity)?.signer
        return ClusterPairingParticipant.storeBacked(identity: identity, name: displayName(chipName: chipName), interface: interface,
            attestation: { ephemeral in
                guard let signer else { throw Failure.noSecureEnclaveKey }
                return try AttestationBuilder(identity: signer).buildAttestationJSON(encryptionPublicKey: ephemeral.base64EncodedString())
            }, store: store, clusterID: clusterID)
    }

    public static let hooks = ClusterPairingHooks(verifyAttestation: { attestation, identityKey, ephemeralKey in
        verifyAttestation(attestation, identityKey: identityKey, ephemeralKey: ephemeralKey, now: Date())
    }, rosterCanonical: { clusterID, generation, members in
        try ClusterRoster.canonical(clusterID: clusterID, generation: generation,
            keys: members.map { ($0.pin, $0.identityKey.base64EncodedString()) })
    })

    /// The other Mac's signed attestation: its signature verifies under the
    /// key it names, that key is the identity key it pairs with, it binds this
    /// ceremony's ephemeral key, the Secure Enclave was available, and it is fresh.
    static func verifyAttestation(_ data: Data, identityKey: Data, ephemeralKey: Data, now: Date) -> ClusterPairingPeerPosture? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let signed = try? decoder.decode(SignedAttestation.self, from: data), AttestationBuilder.verify(signed) else { return nil }
        let blob = signed.attestation
        guard let named = Data(base64Encoded: blob.publicKey),
              named == identityKey.dropFirst() || named == identityKey,
              blob.encryptionPublicKey == ephemeralKey.base64EncodedString(), blob.secureEnclaveAvailable,
              abs(blob.timestamp.timeIntervalSince(now)) <= attestationSkewSeconds else { return nil }
        func clean(_ text: String) -> String {
            String(text.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7F }.map(String.init).joined().prefix(64))
        }
        return ClusterPairingPeerPosture(chipName: clean(blob.chipName), hardwareModel: clean(blob.hardwareModel),
            osVersion: clean(blob.osVersion), sipEnabled: blob.sipEnabled, secureBootEnabled: blob.secureBootEnabled,
            authenticatedRootEnabled: blob.authenticatedRootEnabled)
    }
}

/// The pins a roster registration (v3) must agree with: a saved roster may
/// list only this Mac's own key and keys this Mac pinned in a ceremony, so a
/// setup file alone can never make a member trust another Mac.
public enum ClusterPairingRosterCheck {
    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case notPaired
        case identityChanged
        case unpinnedMember(String)
        case keyDiffers(String)
        case storeUnreadable(String)

        public var description: String {
            switch self {
            case .notPaired: return "Run `darkbloom cluster` on both Macs to pair them. (This Mac has not paired with the other members.)"
            case .identityChanged: return "This Mac's Secure Enclave key is not the one it paired with; pair again."
            case .unpinnedMember(let pin): return "The roster names a member this Mac never paired with (pin \(pin.prefix(16))…); pair with it first."
            case .keyDiffers(let pin): return "The roster's key for member \(pin.prefix(16))… is not the key this Mac pinned."
            case .storeUnreadable(let reason): return "The pairing store cannot be trusted: \(reason)"
            }
        }
    }

    /// Every roster member other than `localPin` must be pinned with the same key.
    public static func verify(roster: ClusterRoster, localPin: String, store: ClusterPairingStore) throws {
        let records: ClusterPairingRecords?
        do { records = try store.load() } catch { throw Refusal.storeUnreadable("\(error)") }
        guard let records else { throw Refusal.notPaired }
        guard records.localPin == localPin else { throw Refusal.identityChanged }
        for member in roster.members where member.pin != localPin {
            guard let pinned = records.pairing(peerPin: member.pin) else { throw Refusal.unpinnedMember(member.pin) }
            guard pinned.peerIdentityKey == member.sePublicKey else { throw Refusal.keyDiffers(member.pin) }
        }
    }

    /// The roster a pairing produced, in the registration's form.
    public static func roster(of record: ClusterPairingRecord) -> ClusterRoster {
        ClusterRoster(generation: record.roster.generation, members: record.roster.members.map {
            ClusterRoster.Member(pin: $0.pin, sePublicKey: $0.sePublicKey, signature: $0.signature)
        })
    }
}
