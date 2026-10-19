import CryptoKit
import Foundation
import DarkbloomClusterSecurity

/// An explicit existing pair, retained through quotation and launch. A newer
/// pairing never silently redirects an in-flight private calibration.
struct GLM5NextCalibrationInstalledPair {
    let clusterID: String
    let localIdentity: Data
    let peerIdentity: Data
    let record: ClusterPairingRecord
    let signer: any AttestationSigner
    private let records: ClusterPairingRecords
    private let store: ClusterPairingStore

    static func load(clusterID: String, peerPin: String, store: ClusterPairingStore = .default(),
                     loadSigner: () throws -> any AttestationSigner = existingSigner) throws -> Self {
        guard let records = try store.load(),
              let record = records.pairing(peerPin: peerPin), record.clusterID == clusterID,
              let local = Data(base64Encoded: records.localIdentityKey),
              let peer = Data(base64Encoded: record.peerIdentityKey), local != peer else {
            throw GLM5NextCalibrationDocument.invalid("The requested installed pair is unavailable")
        }
        let roster = ClusterRoster(generation: record.roster.generation, members: record.roster.members.map {
            .init(pin: $0.pin, sePublicKey: $0.sePublicKey, signature: $0.signature)
        })
        guard roster.members.count == 2,
              Set(roster.members.map(\.pin)) == Set([records.localPin, peerPin]),
              roster.members.first(where: { $0.pin == records.localPin })?.sePublicKey == records.localIdentityKey,
              roster.members.first(where: { $0.pin == peerPin })?.sePublicKey == record.peerIdentityKey else {
            throw GLM5NextCalibrationDocument.invalid("Calibration requires the exact paired two-member roster")
        }
        try roster.verify(clusterID: clusterID)
        let canonical = try roster.canonical(clusterID: clusterID)
        guard SHA256.hash(data: canonical).map({ String(format: "%02x", $0) }).joined() == record.rosterSHA256 else {
            throw GLM5NextCalibrationDocument.invalid("Installed pairing roster digest differs")
        }
        // Validate the stored selection before touching the signing identity.
        let signer = try loadSigner()
        guard let raw = Data(base64Encoded: signer.publicKeyBase64), raw.count == 64,
              Data([4]) + raw == local else {
            throw GLM5NextCalibrationDocument.invalid("The installed signing identity differs from its pairing")
        }
        let result = Self(clusterID: clusterID, localIdentity: local, peerIdentity: peer,
            record: record, signer: signer, records: records, store: store)
        try result.requireUnchanged()
        return result
    }

    func requireUnchanged() throws {
        guard try store.load() == records else {
            throw GLM5NextCalibrationDocument.invalid("Installed pairing changed during calibration")
        }
    }

    /// Reads the existing edge credential only when opening the authenticated
    /// control exchange. No credential is returned by a diagnostic or logged.
    func linkSecret() throws -> Data {
        try requireUnchanged()
        let secret = try store.edgeSecret(for: record)
        try requireUnchanged()
        return secret
    }

    private static func existingSigner() throws -> any AttestationSigner {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["DARKBLOOM_DEBUG_SE_KEY_FILE"] {
            return try SecureEnclaveIdentity.debugLoadExisting(at: path)
        }
        #endif
        return try PersistentEnclaveKey.loadExisting()
    }
}
