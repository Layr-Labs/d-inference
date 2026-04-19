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

    Options for 'attest':
      --encryption-key <base64>    Bind an X25519 encryption public key to the attestation
      --binary-hash <hex>          Include SHA-256 hash of provider binary for integrity verification

    Options for 'challenge-sign':
      --nonce <base64>                     Challenge nonce from coordinator
      --timestamp <rfc3339>                Challenge timestamp from coordinator
      --binary-path <path>                 Path to provider binary to hash
      --active-model-id <string>           Currently serving model ID
      --active-model-path <path>           Path to currently serving model snapshot
      --model-paths-json <json>            JSON object: model id -> model snapshot path
      --hypervisor-active <true|false>     Provider-reported hypervisor state (unsigned hint)
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

private func sha256File(at path: String) -> String? {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path),
          let handle = try? FileHandle(forReadingFrom: url) else {
        return nil
    }
    defer { try? handle.close() }

    var hasher = SHA256()
    while true {
        let chunk = try? handle.read(upToCount: 65536)
        guard let chunk else { return nil }
        if chunk.isEmpty {
            break
        }
        hasher.update(data: chunk)
    }
    return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
}

private func purgePycache(at path: String) {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
        at: URL(fileURLWithPath: path),
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        return
    }

    for case let url as URL in enumerator {
        let name = url.lastPathComponent
        if name == "__pycache__" {
            try? fm.removeItem(at: url)
            enumerator.skipDescendants()
            continue
        }
        if url.pathExtension == "pyc" {
            try? fm.removeItem(at: url)
        }
    }
}

private func combinedTreeHash(at root: String) -> String? {
    let fm = FileManager.default
    guard fm.fileExists(atPath: root),
          let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
          ) else {
        return nil
    }

    var files: [String] = []
    for case let url as URL in enumerator {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        if values?.isRegularFile == true {
            files.append(url.path)
        }
    }
    files.sort()
    if files.isEmpty { return nil }

    var finalHasher = SHA256()
    for path in files {
        guard let fileHash = sha256File(at: path) else { return nil }
        guard let digest = Data(hexString: fileHash) else { return nil }
        finalHasher.update(data: digest)
    }
    return Data(finalHasher.finalize()).map { String(format: "%02x", $0) }.joined()
}

private func weightHashForModel(path: String) -> String? {
    let fm = FileManager.default
    var files: [String] = []
    guard let enumerator = fm.enumerator(
        at: URL(fileURLWithPath: path),
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return nil
    }

    for case let url as URL in enumerator {
        let name = url.lastPathComponent
        let matches =
            name.hasSuffix(".safetensors") ||
            name.hasSuffix(".npz") ||
            name.hasSuffix(".bin") ||
            name.hasSuffix(".ckpt") ||
            name == "weights.npz"
        if !matches { continue }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        if values?.isRegularFile == true {
            files.append(url.path)
        }
    }
    files.sort()
    if files.isEmpty { return nil }

    var finalHasher = SHA256()
    for path in files {
        guard let fileHash = sha256File(at: path) else { return nil }
        guard let digest = Data(hexString: fileHash) else { return nil }
        finalHasher.update(data: digest)
    }
    return Data(finalHasher.finalize()).map { String(format: "%02x", $0) }.joined()
}

private func runtimeHashesFromDarkbloomHome() -> (pythonHash: String?, runtimeHash: String?, templateHashes: [String: String], grpcBinaryHash: String?, imageBridgeHash: String?) {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let darkbloom = home.appendingPathComponent(".darkbloom")

    let pythonPath = darkbloom.appendingPathComponent("python/bin/python3.12").path
    let sitePackages = darkbloom.appendingPathComponent("python/lib/python3.12/site-packages").path
    let templatesDir = darkbloom.appendingPathComponent("templates").path
    let grpcPath = darkbloom.appendingPathComponent("bin/gRPCServerCLI").path
    let imageBridgeDir = darkbloom.appendingPathComponent("image-bridge/eigeninference_image_bridge").path

    let pythonHash = sha256File(at: pythonPath)
    purgePycache(at: sitePackages)
    let runtimeHash = combinedTreeHash(at: sitePackages)
    let grpcBinaryHash = sha256File(at: grpcPath)
    let imageBridgeHash = combinedTreeHash(at: imageBridgeDir)

    var templateHashes: [String: String] = [:]
    if let entries = try? FileManager.default.contentsOfDirectory(atPath: templatesDir) {
        for name in entries where name.hasSuffix(".jinja") {
            let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
            let fullPath = URL(fileURLWithPath: templatesDir).appendingPathComponent(name).path
            if let hash = sha256File(at: fullPath) {
                templateHashes[stem] = hash
            }
        }
    }

    return (pythonHash, runtimeHash, templateHashes, grpcBinaryHash, imageBridgeHash)
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
    binaryPath: String?,
    activeModelID: String?,
    activeModelPath: String?,
    modelPathsJSON: String?,
    hypervisorActive: Bool?
) throws {
    guard SecureEnclave.isAvailable else {
        fputs("error: Secure Enclave is not available on this device\n", stderr)
        exit(1)
    }

    let identity = try loadOrCreateIdentity()
    let runtimeState = runtimeHashesFromDarkbloomHome()
    let binaryHash = binaryPath.flatMap { sha256File(at: $0) }
    let activeModelHash = activeModelPath.flatMap { weightHashForModel(path: $0) }
    let modelPaths = try decodeJSONMap(modelPathsJSON)
    var modelHashes: [String: String] = [:]
    for (modelID, modelPath) in modelPaths {
        if let hash = weightHashForModel(path: modelPath) {
            modelHashes[modelID] = hash
        }
    }

    let payload = ChallengeMeasurementPayload(
        activeModelHash: activeModelHash,
        activeModelID: activeModelID,
        authenticatedRootEnabled: checkAuthenticatedRootEnabled(),
        binaryHash: binaryHash,
        grpcBinaryHash: runtimeState.grpcBinaryHash,
        hypervisorActive: hypervisorActive,
        imageBridgeHash: runtimeState.imageBridgeHash,
        modelHashes: modelHashes,
        nonce: nonce,
        pythonHash: runtimeState.pythonHash,
        rdmaDisabled: checkRDMADisabled(),
        runtimeHash: runtimeState.runtimeHash,
        secureBootEnabled: checkSecureBootEnabled(),
        signatureVersion: 2,
        sipEnabled: checkSIPEnabled(),
        systemVolumeHash: getSystemVolumeHash(),
        templateHashes: runtimeState.templateHashes,
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
        var binaryPath: String? = nil
        var activeModelID: String? = nil
        var activeModelPath: String? = nil
        var modelPathsJSON: String? = nil
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
                binaryPath = args[i + 1]
                i += 2
            } else if args[i] == "--active-model-id" && i + 1 < args.count {
                activeModelID = args[i + 1]
                i += 2
            } else if args[i] == "--active-model-path" && i + 1 < args.count {
                activeModelPath = args[i + 1]
                i += 2
            } else if args[i] == "--model-paths-json" && i + 1 < args.count {
                modelPathsJSON = args[i + 1]
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
            binaryPath: binaryPath,
            activeModelID: activeModelID,
            activeModelPath: activeModelPath,
            modelPathsJSON: modelPathsJSON,
            hypervisorActive: hypervisorActive
        )

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
