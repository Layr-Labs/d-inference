import CryptoKit
import EigenInferenceEnclave
import Foundation

// MARK: - CLI Entry Point

/// Command-line tool that generates and outputs a signed attestation.
///
/// Usage:
///   eigeninference-enclave attest [--encryption-key <base64>] [--binary-hash <hex>]
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
    return home.appendingPathComponent(".darkbloom/enclave_key.data")
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
    Usage: eigeninference-enclave <command> [options]

    Commands:
      attest          Generate a signed attestation blob
      info            Show Secure Enclave availability and public key
      challenge-sign  Sign fresh challenge measurements
      wallet-address  Derive wallet address from the SE public key
      wallet-sign     Sign a message with the SE key for payout authentication

    Options for 'attest':
      --encryption-key <base64>    Bind an X25519 encryption public key to the attestation
      --binary-hash <hex>          Include SHA-256 hash of provider binary for integrity verification

    Options for 'challenge-sign':
      --nonce <base64>                     Challenge nonce from coordinator
      --timestamp <rfc3339>                Challenge timestamp from coordinator
      --binary-hash <hex>                  Fresh SHA-256 of provider binary
      --active-model-id <string>           Currently serving model ID
      --active-model-hash <hex>            Fresh SHA-256 of currently serving model weights
      --python-hash <hex>                  Fresh SHA-256 of Python interpreter
      --runtime-hash <hex>                 Fresh SHA-256 of runtime/site-packages tree
      --grpc-binary-hash <hex>             Fresh SHA-256 of gRPCServerCLI
      --image-bridge-hash <hex>            Fresh SHA-256 of image bridge source tree
      --template-hashes-json <json>        JSON object: template name -> hash
      --model-hashes-json <json>           JSON object: model id -> hash
      --hypervisor-active <true|false>     Provider-reported hypervisor state (unsigned hint)

    Options for 'wallet-sign':
      --message <string>           Message to sign (UTF-8)
    """
    fputs(usage + "\n", stderr)
}

private struct ChallengeMeasurementPayload: Codable {
    let activeModelHash: String?
    let activeModelID: String?
    let authenticatedRootEnabled: Bool
    let binaryHash: String?
    let grpcBinaryHash: String?
    let hypervisorActive: Bool?
    let imageBridgeHash: String?
    let modelHashes: [String: String]
    let nonce: String
    let pythonHash: String?
    let rdmaDisabled: Bool
    let runtimeHash: String?
    let secureBootEnabled: Bool
    let signatureVersion: Int
    let sipEnabled: Bool
    let systemVolumeHash: String?
    let templateHashes: [String: String]
    let timestamp: String
}

private struct SignedChallengeMeasurement: Codable {
    let payload: ChallengeMeasurementPayload
    let publicKey: String
    let signature: String
}

private func sortedJSONString<T: Encodable>(for value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    guard let json = String(data: data, encoding: .utf8) else {
        throw NSError(domain: "EigenInferenceEnclaveCLI", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "failed to encode JSON as UTF-8"
        ])
    }
    return json
}

private func decodeJSONMap(_ raw: String?) throws -> [String: String] {
    guard let raw, !raw.isEmpty else { return [:] }
    guard let data = raw.data(using: .utf8) else {
        throw NSError(domain: "EigenInferenceEnclaveCLI", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "invalid UTF-8 JSON input"
        ])
    }
    return try JSONDecoder().decode([String: String].self, from: data)
}

private func parseBoolFlag(_ raw: String?) throws -> Bool? {
    guard let raw else { return nil }
    switch raw.lowercased() {
    case "true":
        return true
    case "false":
        return false
    default:
        throw NSError(domain: "EigenInferenceEnclaveCLI", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "boolean flag must be 'true' or 'false'"
        ])
    }
}

func cmdWalletAddress() throws {
    guard SecureEnclave.isAvailable else {
        fputs("error: Secure Enclave is not available on this device\n", stderr)
        exit(1)
    }

    let identity = try loadOrCreateIdentity()

    // Derive a deterministic wallet address from the SE public key.
    // SHA-256 hash of the raw public key bytes, take last 20 bytes → 0x prefixed hex.
    // The private key never exists outside the Secure Enclave.
    let pubKeyData = identity.publicKeyRaw
    let hash = SHA256.hash(data: pubKeyData)
    let hashBytes = Array(hash)
    let addressBytes = hashBytes.suffix(20)
    let address = "0x" + addressBytes.map { String(format: "%02x", $0) }.joined()

    let output: [String: String] = [
        "address": address,
        "public_key": identity.publicKeyBase64,
        "storage": "secure_enclave",
    ]

    let jsonData = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    if let jsonStr = String(data: jsonData, encoding: .utf8) {
        print(jsonStr)
    }
}

func cmdWalletSign(message: String) throws {
    guard SecureEnclave.isAvailable else {
        fputs("error: Secure Enclave is not available on this device\n", stderr)
        exit(1)
    }

    let identity = try loadOrCreateIdentity()
    let messageData = Data(message.utf8)
    let signature = try identity.sign(messageData)

    let output: [String: String] = [
        "signature": signature.base64EncodedString(),
        "public_key": identity.publicKeyBase64,
    ]

    let jsonData = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    if let jsonStr = String(data: jsonData, encoding: .utf8) {
        print(jsonStr)
    }
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

func cmdChallengeSign(
    nonce: String,
    timestamp: String,
    binaryHash: String?,
    activeModelID: String?,
    activeModelHash: String?,
    pythonHash: String?,
    runtimeHash: String?,
    grpcBinaryHash: String?,
    imageBridgeHash: String?,
    templateHashesJSON: String?,
    modelHashesJSON: String?,
    hypervisorActive: Bool?
) throws {
    guard SecureEnclave.isAvailable else {
        fputs("error: Secure Enclave is not available on this device\n", stderr)
        exit(1)
    }

    let identity = try loadOrCreateIdentity()
    let payload = ChallengeMeasurementPayload(
        activeModelHash: activeModelHash,
        activeModelID: activeModelID,
        authenticatedRootEnabled: checkAuthenticatedRootEnabled(),
        binaryHash: binaryHash,
        grpcBinaryHash: grpcBinaryHash,
        hypervisorActive: hypervisorActive,
        imageBridgeHash: imageBridgeHash,
        modelHashes: try decodeJSONMap(modelHashesJSON),
        nonce: nonce,
        pythonHash: pythonHash,
        rdmaDisabled: checkRDMADisabled(),
        runtimeHash: runtimeHash,
        secureBootEnabled: checkSecureBootEnabled(),
        signatureVersion: 2,
        sipEnabled: checkSIPEnabled(),
        systemVolumeHash: getSystemVolumeHash(),
        templateHashes: try decodeJSONMap(templateHashesJSON),
        timestamp: timestamp
    )

    let payloadJSON = try sortedJSONString(for: payload)
    let signature = try identity.sign(Data(payloadJSON.utf8))
    let signed = SignedChallengeMeasurement(
        payload: payload,
        publicKey: identity.publicKeyBase64,
        signature: signature.base64EncodedString()
    )
    let outputJSON = try sortedJSONString(for: signed)
    print(outputJSON)
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

    case "challenge-sign":
        var nonce: String? = nil
        var timestamp: String? = nil
        var binaryHash: String? = nil
        var activeModelID: String? = nil
        var activeModelHash: String? = nil
        var pythonHash: String? = nil
        var runtimeHash: String? = nil
        var grpcBinaryHash: String? = nil
        var imageBridgeHash: String? = nil
        var templateHashesJSON: String? = nil
        var modelHashesJSON: String? = nil
        var hypervisorActiveRaw: String? = nil
        var i = 2
        while i < args.count {
            if args[i] == "--nonce" && i + 1 < args.count {
                nonce = args[i + 1]
                i += 2
            } else if args[i] == "--timestamp" && i + 1 < args.count {
                timestamp = args[i + 1]
                i += 2
            } else if args[i] == "--binary-hash" && i + 1 < args.count {
                binaryHash = args[i + 1]
                i += 2
            } else if args[i] == "--active-model-id" && i + 1 < args.count {
                activeModelID = args[i + 1]
                i += 2
            } else if args[i] == "--active-model-hash" && i + 1 < args.count {
                activeModelHash = args[i + 1]
                i += 2
            } else if args[i] == "--python-hash" && i + 1 < args.count {
                pythonHash = args[i + 1]
                i += 2
            } else if args[i] == "--runtime-hash" && i + 1 < args.count {
                runtimeHash = args[i + 1]
                i += 2
            } else if args[i] == "--grpc-binary-hash" && i + 1 < args.count {
                grpcBinaryHash = args[i + 1]
                i += 2
            } else if args[i] == "--image-bridge-hash" && i + 1 < args.count {
                imageBridgeHash = args[i + 1]
                i += 2
            } else if args[i] == "--template-hashes-json" && i + 1 < args.count {
                templateHashesJSON = args[i + 1]
                i += 2
            } else if args[i] == "--model-hashes-json" && i + 1 < args.count {
                modelHashesJSON = args[i + 1]
                i += 2
            } else if args[i] == "--hypervisor-active" && i + 1 < args.count {
                hypervisorActiveRaw = args[i + 1]
                i += 2
            } else {
                fputs("error: unknown option \(args[i])\n", stderr)
                printUsage()
                exit(1)
            }
        }
        guard let nonce else {
            fputs("error: --nonce required\n", stderr)
            exit(1)
        }
        guard let timestamp else {
            fputs("error: --timestamp required\n", stderr)
            exit(1)
        }
        let hypervisorActive = try parseBoolFlag(hypervisorActiveRaw)
        try cmdChallengeSign(
            nonce: nonce,
            timestamp: timestamp,
            binaryHash: binaryHash,
            activeModelID: activeModelID,
            activeModelHash: activeModelHash,
            pythonHash: pythonHash,
            runtimeHash: runtimeHash,
            grpcBinaryHash: grpcBinaryHash,
            imageBridgeHash: imageBridgeHash,
            templateHashesJSON: templateHashesJSON,
            modelHashesJSON: modelHashesJSON,
            hypervisorActive: hypervisorActive
        )

    case "info":
        try cmdInfo()

    case "sign":
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

    case "wallet-address":
        try cmdWalletAddress()

    case "wallet-sign":
        var message: String? = nil
        var i = 2
        while i < args.count {
            if args[i] == "--message" && i + 1 < args.count {
                message = args[i + 1]
                i += 2
            } else {
                fputs("error: unknown option \(args[i])\n", stderr)
                printUsage()
                exit(1)
            }
        }
        guard let message = message else {
            fputs("error: --message <string> required\n", stderr)
            exit(1)
        }
        try cmdWalletSign(message: message)

    default:
        fputs("error: unknown command '\(command)'\n", stderr)
        printUsage()
        exit(1)
    }
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
