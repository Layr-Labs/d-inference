import CryptoKit
import Foundation

enum NativeMemberIdentityError: Error { case invalid }

/// A description to bind inside coordinator authorization, never an authority
/// decoded from a peer. App Attest machine continuity is not an MDA serial.
struct NativeMemberIdentity: Sendable, Equatable {
    enum Evidence: Sendable, Equatable {
        case legacyMDA(serial: String)
        case qualifiedAppAttest(accountID: String, machineID: String, credentialID: String, proofSessionID: String)
    }
    let providerID, controlPublicKey, processPublicKey: String
    let binarySHA256, metallibSHA256: Data
    let releasePolicyGeneration: UInt64
    let evidence: Evidence

    init(providerID: String, controlPublicKey: String, processPublicKey: String,
         binarySHA256: Data, metallibSHA256: Data, releasePolicyGeneration: UInt64, evidence: Evidence) throws {
        self.providerID = providerID; self.controlPublicKey = controlPublicKey; self.processPublicKey = processPublicKey
        self.binarySHA256 = binarySHA256; self.metallibSHA256 = metallibSHA256
        self.releasePolicyGeneration = releasePolicyGeneration; self.evidence = evidence
        try validate()
    }
    static func validText(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 128 && s.unicodeScalars.allSatisfy { $0.value >= 33 && $0.value != 127 }
    }
    func signingKeyIdentity() throws -> Data {
        guard var raw = Data(base64Encoded: controlPublicKey), raw.base64EncodedString() == controlPublicKey,
              raw.count == 64 || raw.count == 65 else { throw NativeMemberIdentityError.invalid }
        if raw.count == 64 { raw.insert(4, at: 0) }
        let key: P256.Signing.PublicKey
        do { key = try P256.Signing.PublicKey(x963Representation: raw) }
        catch { throw NativeMemberIdentityError.invalid }
        return Data(SHA256.hash(data: key.x963Representation))
    }
    func validate() throws {
        guard Self.validText(providerID), releasePolicyGeneration != 0,
              binarySHA256.count == 32, binarySHA256.contains(where: { $0 != 0 }),
              metallibSHA256.count == 32, metallibSHA256.contains(where: { $0 != 0 }),
              let endpoint = Data(base64Encoded: processPublicKey), endpoint.count == 32,
              endpoint.contains(where: { $0 != 0 }), endpoint.base64EncodedString() == processPublicKey
        else { throw NativeMemberIdentityError.invalid }
        _ = try signingKeyIdentity()
        switch evidence {
        case let .legacyMDA(serial):
            guard Self.validText(serial) else { throw NativeMemberIdentityError.invalid }
        case let .qualifiedAppAttest(account, machine, credential, proof):
            guard [account, machine, credential, proof].allSatisfy(Self.validText) else { throw NativeMemberIdentityError.invalid }
        }
    }
}
