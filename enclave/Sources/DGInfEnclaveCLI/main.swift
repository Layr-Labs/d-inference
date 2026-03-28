import CryptoKit
import DGInfEnclave
import Foundation

// MARK: - CLI Entry Point

/// Command-line tool that generates and outputs a signed attestation.
///
/// Usage:
///   dginf-enclave attest [--encryption-key <base64>] [--binary-hash <hex>]
///
/// The --encryption-key flag binds an X25519 encryption public key to the
/// attestation, proving the same hardware identity controls both the
/// Secure Enclave signing key and the E2E encryption key.
///
/// The --binary-hash flag includes the SHA-256 hash of the provider binary
/// in the attestation, allowing the coordinator to verify the provider is
/// running the expected (blessed) version.

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
      --binary-hash <hex>          Include SHA-256 hash of provider binary for integrity verification
    """
    fputs(usage + "\n", stderr)
}

func cmdAttest(encryptionKey: String?, binaryHash: String?) throws {
    guard SecureEnclave.isAvailable else {
        fputs("error: Secure Enclave is not available on this device\n", stderr)
        exit(1)
    }

    let identity = try loadOrCreateIdentity()
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

    case "sign":
        // Sign arbitrary data with the SE key
        var dataB64: String? = nil
        var i = 2
        while i < args.count {
            if args[i] == "--data" && i + 1 < args.count {
                dataB64 = args[i + 1]
                i += 2
            } else {
                i += 1
            }
        }
        guard let dataB64 = dataB64 else {
            fputs("error: --data <base64> required\n", stderr)
            exit(1)
        }
        guard let data = Data(base64Encoded: dataB64) else {
            fputs("error: invalid base64 data\n", stderr)
            exit(1)
        }
        let signIdentity = try loadOrCreateIdentity()
        let signature = try signIdentity.sign(data)
        print(signature.base64EncodedString())

    case "tls-bridge":
        // WebSocket bridge with TLS client cert from managed profile
        var coordinatorURL = "wss://inference-test.openinnovation.dev/ws/provider"
        var socketPath = "/tmp/dginf-ws-bridge.sock"
        var i = 2
        while i < args.count {
            if args[i] == "--url" && i + 1 < args.count {
                coordinatorURL = args[i + 1]
                i += 2
            } else if args[i] == "--socket" && i + 1 < args.count {
                socketPath = args[i + 1]
                i += 2
            } else {
                i += 1
            }
        }
        runWebSocketBridge(coordinatorURL: coordinatorURL, socketPath: socketPath)

    default:
        fputs("error: unknown command '\(command)'\n", stderr)
        printUsage()
        exit(1)
    }
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
