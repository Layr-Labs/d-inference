// darkbloom-enclave — CLI helper around the Secure Enclave identity.
//
// Links `ProviderCore` directly (no FFI bridge), so behaviour matches
// what the Swift provider does at startup.
//
// Subcommands:
//   attest --pub-key <b64>  Build a signed attestation blob and print JSON.
//   sign   --message <s>    Sign a message with the SE key (base64 DER sig).
//   info                    Print public key info (base64 + hex).
//   wallet-address          Print the deterministic identifier derived from the SE key.
//
// All operations create a fresh, ephemeral Secure Enclave key pair. The
// tool is stateless: there is no on-disk key material.
//
// Used by `scripts/install.sh` to render an attestation blob during
// initial device provisioning before the main provider is running. The
// legacy binary name `eigeninference-enclave` is kept as a symlink in
// install.sh; the canonical name is `darkbloom-enclave`.

import ArgumentParser
import CryptoKit
import Foundation
import ProviderCore

@main
struct DarkbloomEnclave: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "darkbloom-enclave",
        abstract: "Secure Enclave attestation/signing helper.",
        subcommands: [Attest.self, Sign.self, Info.self, WalletAddress.self],
        defaultSubcommand: Info.self
    )
}

private enum EnclaveCLIError: Error, CustomStringConvertible {
    case secureEnclaveUnavailable

    var description: String {
        switch self {
        case .secureEnclaveUnavailable:
            return "Secure Enclave is unavailable on this device (Intel Mac or non-Apple hardware?)"
        }
    }
}

private func loadIdentity() throws -> SecureEnclaveIdentity {
    guard let identity = try SecureEnclaveIdentity.createEphemeral() else {
        throw EnclaveCLIError.secureEnclaveUnavailable
    }
    return identity
}

// MARK: - attest

struct Attest: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build a signed attestation blob and print it as JSON."
    )

    @Option(help: "Base64-encoded X25519 public key to bind into the attestation.")
    var pubKey: String?

    @Option(help: "Hex SHA-256 of the provider binary (for runtime verification).")
    var binaryHash: String?

    func run() throws {
        let identity = try loadIdentity()
        let builder = AttestationBuilder(identity: identity)
        let data = try builder.buildAttestationJSON(
            encryptionPublicKey: pubKey,
            binaryHash: binaryHash
        )
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

// MARK: - sign

struct Sign: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sign a message with the Secure Enclave key. Prints base64 DER signature."
    )

    @Option(help: "UTF-8 message to sign.")
    var message: String

    func run() throws {
        let identity = try loadIdentity()
        let sig = try identity.sign(Data(message.utf8))
        print(sig.base64EncodedString())
    }
}

// MARK: - info

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print Secure Enclave public key (base64 + hex)."
    )

    func run() throws {
        let identity = try loadIdentity()
        let payload: [String: String] = [
            "publicKeyBase64": identity.publicKeyBase64,
            "publicKeyHex": identity.publicKeyHex,
            "secureEnclaveAvailable": String(SecureEnclaveIdentity.isAvailable),
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

// MARK: - wallet-address

struct WalletAddress: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print a stable identifier (0x-prefixed 20-byte hex) derived from the SE public key."
    )

    func run() throws {
        // The SE produces P-256 keys, not secp256k1; we expose a stable
        // identifier derived from the SE pubkey rather than an Ethereum
        // address. Coordinators that previously used Ethereum-style hex
        // wallets accept any 20-byte hex prefixed with "0x".
        let identity = try loadIdentity()
        let pubKeyHash = SHA256.hash(data: identity.publicKey.rawRepresentation)
        let last20 = Array(pubKeyHash).suffix(20)
        let hex = last20.map { String(format: "%02x", $0) }.joined()
        print("0x\(hex)")
    }
}
