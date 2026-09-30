// darkbloom-enclave — CLI helper around the Secure Enclave identity.
//
// Links `ProviderCore` directly (no FFI bridge), so behaviour matches
// what the Swift provider does at startup.
//
// Subcommands:
//   attest --pub-key <b64>  Build a signed attestation blob and print JSON.
//   sign   --message <s>    Sign a message with the SE key (base64 DER sig).
//   info                    Print public key info (base64 + hex).
//
// All operations create a fresh, ephemeral Secure Enclave key pair. The
// tool is stateless: there is no on-disk key material.
//
// Used by `scripts/install.sh` to render an attestation blob during
// initial device provisioning before the main provider is running. Installed
// as `darkbloom-enclave`.

import ArgumentParser
import Foundation
import ProviderCore

@main
struct DarkbloomEnclave: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "darkbloom-enclave",
        abstract: "Secure Enclave attestation/signing helper.",
        subcommands: [Attest.self, Sign.self, Info.self],
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
