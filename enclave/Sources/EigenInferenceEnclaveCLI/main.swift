import CryptoKit
import EigenInferenceEnclave
import Foundation

// MARK: - CLI Entry Point

/// Command-line tool for Secure Enclave attestation and diagnostics.
///
/// Usage:
///   eigeninference-enclave attest [--encryption-key <base64>] [--binary-hash <hex>]
///   eigeninference-enclave provider-identity-info
///   eigeninference-enclave info
///
/// All keys are ephemeral — a fresh P-256 key is created in the Secure Enclave
/// for each invocation. No key material is persisted to disk.

func printUsage() {
    let usage = """
    Usage: eigeninference-enclave <command> [options]

    Commands:
      attest          Generate a signed attestation blob (ephemeral key)
      provider-identity-info
                      Load/create the provider-bound keychain identity
      info            Show Secure Enclave availability

    Options for 'attest':
      --encryption-key <base64>    Bind an X25519 encryption public key to the attestation
      --binary-hash <hex>          Include SHA-256 hash of provider binary for integrity verification
    """
    fputs(usage + "\n", stderr)
}

func cmdAttest(encryptionKey: String?, binaryHash: String?) throws {
    guard SecureEnclave.isAvailable else {
        fputs("error: Secure Enclave is not available on this device\n", stderr)
        exit(1)
    }

    let identity = try SecureEnclaveIdentity()
    let service = AttestationService(identity: identity)
    let signed = try service.createAttestation(encryptionPublicKey: encryptionKey, binaryHash: binaryHash)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let jsonData = try encoder.encode(signed)

    guard let jsonStr = String(data: jsonData, encoding: .utf8) else {
        fputs("error: failed to encode attestation as UTF-8\n", stderr)
        exit(1)
    }

    print(jsonStr)
}

func cmdInfo() throws {
    let available = SecureEnclave.isAvailable
    var info: [String: Any] = [
        "secure_enclave_available": available,
        "key_persistence": "ephemeral",
    ]

    if available {
        let identity = try SecureEnclaveIdentity()
        info["public_key"] = identity.publicKeyBase64
    }

    let jsonData = try JSONSerialization.data(
        withJSONObject: info,
        options: [.sortedKeys, .prettyPrinted]
    )
    if let jsonStr = String(data: jsonData, encoding: .utf8) {
        print(jsonStr)
    }
}

func cmdProviderIdentityInfo() throws {
    guard SecureEnclave.isAvailable else {
        fputs("error: Secure Enclave is not available on this device\n", stderr)
        exit(1)
    }

    let identity = try ProviderBoundIdentity()
    let info: [String: Any] = [
        "provider_identity_public_key": try identity.publicKeyBase64,
        "key_persistence": "keychain-access-group",
    ]
    let jsonData = try JSONSerialization.data(
        withJSONObject: info,
        options: [.sortedKeys, .prettyPrinted]
    )
    if let jsonStr = String(data: jsonData, encoding: .utf8) {
        print(jsonStr)
    }
}

// MARK: - Argument Parsing

let args = CommandLine.arguments
guard args.count >= 2 else {
    printUsage()
    exit(1)
}

let command = args[1]

do {
    switch command {
    case "attest":
        var encryptionKey: String? = nil
        var binaryHash: String? = nil
        var i = 2
        while i < args.count {
            if args[i] == "--encryption-key" && i + 1 < args.count {
                encryptionKey = args[i + 1]
                i += 2
            } else if args[i] == "--binary-hash" && i + 1 < args.count {
                binaryHash = args[i + 1]
                i += 2
            } else {
                fputs("error: unknown option \(args[i])\n", stderr)
                printUsage()
                exit(1)
            }
        }
        try cmdAttest(encryptionKey: encryptionKey, binaryHash: binaryHash)

    case "info":
        try cmdInfo()

    case "provider-identity-info":
        try cmdProviderIdentityInfo()

    default:
        fputs("error: unknown command '\(command)'\n", stderr)
        printUsage()
        exit(1)
    }
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
