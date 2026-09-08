import CryptoKit
import Foundation

protocol BootHardwareKey {
    var publicKey: Data { get }
    var opaqueHandle: Data { get }
    func sign(_ message: Data) throws -> Data
}

protocol BootKeyEngine: Sendable {
    var isAvailable: Bool { get }
    func create() throws -> any BootHardwareKey
    func recover(handle: Data) throws -> any BootHardwareKey
}

/// IO-independent lifecycle. Recovery never creates a replacement key.
final class BootKeySession {
    let context: BootContinuityContext
    private let key: any BootHardwareKey
    var publicKey: Data { key.publicKey }

    private init(context: BootContinuityContext, key: any BootHardwareKey) throws {
        self.context = context
        self.key = key
        // Recovery can return a public key before the enclave accepts an operation.
        // Challenge the private half before reporting a usable session.
        var random = SystemRandomNumberGenerator()
        let challenge = try BootContinuationChallenge(
            nonce: Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) }),
            processPublicKey: Data(repeating: 0, count: 32))
        _ = try provePossession(challenge)
    }

    static func create(context: BootContinuityContext, activation: BootContinuityActivation,
                       engine: any BootKeyEngine) throws -> BootKeySession {
        try preflight(context: context, activation: activation, engine: engine)
        return try BootKeySession(context: context, key: engine.create())
    }

    static func recover(record data: Data, context: BootContinuityContext,
                        activation: BootContinuityActivation, engine: any BootKeyEngine) throws -> BootKeySession {
        try preflight(context: context, activation: activation, engine: engine)
        let record = try BootKeyRecord.decode(data, expecting: context)
        let key = try engine.recover(handle: record.opaqueHandle)
        guard key.publicKey == record.publicKey else { throw BootContinuityError.publicKeyMismatch }
        return try BootKeySession(context: context, key: key)
    }

    private static func preflight(context: BootContinuityContext,
                                  activation: BootContinuityActivation, engine: any BootKeyEngine) throws {
        guard activation == .experimental else { throw BootContinuityError.disabled }
        try context.validate()
        guard engine.isAvailable else { throw BootContinuityError.secureEnclaveUnavailable }
    }

    func storageRecord() throws -> Data { try BootKeyRecord(context: context, key: key).encode() }

    func provePossession(_ challenge: BootContinuationChallenge) throws -> BootContinuationProof {
        let transcript = BootContinuationTranscript.encode(context: context, publicKey: publicKey, challenge: challenge)
        let signature = try key.sign(transcript)
        guard let publicKey = try? P256.Signing.PublicKey(rawRepresentation: publicKey),
              let parsed = try? P256.Signing.ECDSASignature(derRepresentation: signature),
              publicKey.isValidSignature(parsed, for: transcript) else {
            throw BootContinuityError.possessionCheckFailed
        }
        return BootContinuationProof(publicKey: self.publicKey, signatureDER: signature, transcript: transcript)
    }
}
