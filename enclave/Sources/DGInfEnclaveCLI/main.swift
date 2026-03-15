import CryptoKit
import DGInfEnclave
import Foundation

// MARK: - CLI Entry Point

/// Command-line tool that generates and outputs a signed attestation.
///
/// Usage:
///   dginf-enclave attest [--encryption-key <base64>]
///
/// The --encryption-key flag binds an X25519 encryption public key to the
/// attestation, proving the same hardware identity controls both the
/// Secure Enclave signing key and the E2E encryption key.

let identityPath: URL = {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(".dginf/enclave_key.data")
}()

func loadOrCreateIdentity() throws -> SecureEnclaveIdentity {
    let fm = FileManager.default
    let dir = identityPath.deletingLastPathComponent().path

    if fm.fileExists(atPath: identityPath.path) {
        let data = try Data(contentsOf: identityPath)
        return try SecureEnclaveIdentity(dataRepresentation: data)
    }

    // Create directory if needed
    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

    let identity = try SecureEnclaveIdentity()
    let data = identity.dataRepresentation
    try data.write(to: identityPath)

    // Set restrictive permissions (0600)
    try fm.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: identityPath.path
    )

    return identity
}

func printUsage() {
    let usage = """
    Usage: dginf-enclave <command> [options]

    Commands:
      attest    Generate a signed attestation blob
      info      Show Secure Enclave availability and public key

    Options for 'attest':
      --encryption-key <base64>    Bind an X25519 encryption public key to the attestation
    """
    fputs(usage + "\n", stderr)
}

func cmdAttest(encryptionKey: String?) throws {
    guard SecureEnclave.isAvailable else {
        fputs("error: Secure Enclave is not available on this device\n", stderr)
        exit(1)
    }

    let identity = try loadOrCreateIdentity()
    let service = AttestationService(identity: identity)
    let signed = try service.createAttestation(encryptionPublicKey: encryptionKey)

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
    ]

    if available {
        let identity = try loadOrCreateIdentity()
        info["public_key"] = identity.publicKeyBase64
        info["identity_path"] = identityPath.path
    }

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
        var i = 2
        while i < args.count {
            if args[i] == "--encryption-key" && i + 1 < args.count {
                encryptionKey = args[i + 1]
                i += 2
            } else {
                fputs("error: unknown option \(args[i])\n", stderr)
                printUsage()
                exit(1)
            }
        }
        try cmdAttest(encryptionKey: encryptionKey)

    case "info":
        try cmdInfo()

    default:
        fputs("error: unknown command '\(command)'\n", stderr)
        printUsage()
        exit(1)
    }
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
