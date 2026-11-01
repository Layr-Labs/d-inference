import CryptoKit
import Foundation
import Network
import Security

/// DEBUG BUILDS ONLY: a local test coordinator's TLS certificate, pinned.
///
/// A member attaches native-pair control only on a real TLS connection
/// (`nativePairMemberAccepted`), and the default TLS parameters accept only
/// certificates the system trusts. A coordinator run locally for an
/// end-to-end proof serves a self-signed certificate; adding it to the
/// system's trust is a security-settings change, so a debug build instead
/// accepts exactly the one leaf certificate whose SHA-256 (of its DER bytes)
/// `DARKBLOOM_DEBUG_COORDINATOR_CERT_SHA256` names, and nothing else. Release
/// builds compile none of this: their coordinator connection always uses the
/// system's trust evaluation.
enum CoordinatorDebugCertificatePin {
    static let environmentKey = "DARKBLOOM_DEBUG_COORDINATOR_CERT_SHA256"

    /// TLS options for the coordinator connection, or nil for the system's
    /// default trust evaluation.
    static func tlsOptions(environment: [String: String] = ProcessInfo.processInfo.environment) -> NWProtocolTLS.Options? {
        #if DEBUG
        guard let pin = pinnedDigest(environment[environmentKey]) else { return nil }
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, complete in
            complete(matches(trust: sec_trust_copy_ref(trust).takeRetainedValue(), pin: pin))
        }, DispatchQueue(label: "darkbloom.coordinator.debug-certificate-pin"))
        return options
        #else
        return nil
        #endif
    }

    /// 64 lowercase hex characters, else nil (an unset or malformed pin pins nothing).
    static func pinnedDigest(_ value: String?) -> Data? {
        guard let value, value.utf8.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        var bytes = Data(capacity: 32), index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            bytes.append(UInt8(value[index..<next], radix: 16)!)
            index = next
        }
        return bytes
    }

    /// The leaf certificate's DER digest equals the pin.
    static func matches(trust: SecTrust, pin: Data) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return false }
        return Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data)) == pin
    }
}
