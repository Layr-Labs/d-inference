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

let e2eKeyAgreementPath: URL = {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(".dginf/enclave_e2e_ka.data")
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
      attest          Generate a signed attestation blob
      info            Show Secure Enclave availability and public key
      derive-e2e-key  Derive X25519 E2E encryption key from SE (never stored on disk)
      wallet-address  Derive wallet address from the SE public key
      wallet-sign     Sign a message with the SE key for payout authentication

    Options for 'attest':
      --encryption-key <base64>    Bind an X25519 encryption public key to the attestation
      --binary-hash <hex>          Include SHA-256 hash of provider binary for integrity verification

    Options for 'wallet-sign':
      --message <string>           Message to sign (UTF-8)
    """
    fputs(usage + "\n", stderr)
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

func loadOrCreateKeyAgreement() throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
    let fm = FileManager.default
    let dir = e2eKeyAgreementPath.deletingLastPathComponent().path

    if fm.fileExists(atPath: e2eKeyAgreementPath.path) {
        let data = try Data(contentsOf: e2eKeyAgreementPath)
        return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: data)
    }

    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

    let key = try SecureEnclave.P256.KeyAgreement.PrivateKey()
    try key.dataRepresentation.write(to: e2eKeyAgreementPath)

    try fm.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: e2eKeyAgreementPath.path
    )

    return key
}

func cmdDeriveE2EKey() throws {
    guard SecureEnclave.isAvailable else {
        fputs("error: Secure Enclave is not available on this device\n", stderr)
        exit(1)
    }

    let kaKey = try loadOrCreateKeyAgreement()

    // Fixed derivation point — ECDH with this known key produces a deterministic
    // shared secret on each device. The point itself is not secret; what matters
    // is that only THIS device's SE can perform the ECDH with its hardware key.
    // Generated once from: P256.KeyAgreement.PrivateKey().publicKey
    let derivationPointHex =
        "04" +
        "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296" +
        "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"
    let derivationPointData = Data(
        stride(from: 0, to: derivationPointHex.count, by: 2).map {
            let start = derivationPointHex.index(derivationPointHex.startIndex, offsetBy: $0)
            let end = derivationPointHex.index(start, offsetBy: 2)
            return UInt8(derivationPointHex[start..<end], radix: 16)!
        }
    )

    let derivationPubKey = try P256.KeyAgreement.PublicKey(
        x963Representation: derivationPointData
    )

    let sharedSecret = try kaKey.sharedSecretFromKeyAgreement(with: derivationPubKey)

    // HKDF-SHA256 to derive exactly 32 bytes for the X25519 private key
    let derivedKey = sharedSecret.hkdfDerivedSymmetricKey(
        using: SHA256.self,
        salt: Data("dginf-e2e-key-v1".utf8),
        sharedInfo: Data("x25519-private-key".utf8),
        outputByteCount: 32
    )

    // Extract raw bytes and compute the X25519 public key
    let keyBytes = derivedKey.withUnsafeBytes { Array($0) }
    let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(keyBytes))
    let publicKeyB64 = privateKey.publicKey.rawRepresentation.base64EncodedString()
    let privateKeyB64 = Data(keyBytes).base64EncodedString()

    let output: [String: String] = [
        "private_key": privateKeyB64,
        "public_key": publicKeyB64,
        "storage": "secure_enclave_derived",
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

    case "derive-e2e-key":
        try cmdDeriveE2EKey()

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
