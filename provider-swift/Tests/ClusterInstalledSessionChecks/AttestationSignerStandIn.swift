import Foundation

/// The provider's attestation signer protocol (`Security/AttestationSigner.swift`) for
/// the plain-swiftc check runners, which build the roster registration types
/// without the Secure Enclave sources that conform to it.
public protocol AttestationSigner: Sendable {
    func sign(_ data: Data) throws -> Data
    var publicKeyBase64: String { get }
}
