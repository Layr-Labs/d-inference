import CryptoKit
import Foundation

public enum X25519ChaChaPolyError: Error, Equatable, Sendable {
    case invalidPrivateKeyLength(Int)
    case invalidPublicKeyLength(Int)
    case invalidNonceLength(Int)
}

public struct X25519KeyAgreementKeyPair: Sendable {
    private let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init() {
        self.privateKey = Curve25519.KeyAgreement.PrivateKey()
    }

    public init(rawPrivateKey: Data) throws {
        guard rawPrivateKey.count == 32 else {
            throw X25519ChaChaPolyError.invalidPrivateKeyLength(rawPrivateKey.count)
        }
        self.privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawPrivateKey)
    }

    public var publicKey: Data {
        Data(privateKey.publicKey.rawRepresentation)
    }

    public var rawPrivateKey: Data {
        Data(privateKey.rawRepresentation)
    }

    public func symmetricKey(
        peerPublicKey: Data,
        salt: Data = Data(),
        sharedInfo: Data = Data("darkbloom-provider-x25519-chachapoly-v1".utf8)
    ) throws -> SymmetricKey {
        guard peerPublicKey.count == 32 else {
            throw X25519ChaChaPolyError.invalidPublicKeyLength(peerPublicKey.count)
        }

        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: sharedInfo,
            outputByteCount: 32
        )
    }
}

public struct X25519ChaChaPolySealedMessage: Equatable, Sendable {
    public static let nonceSize = 12

    public let senderPublicKey: Data
    public let nonce: Data
    public let ciphertext: Data
    public let tag: Data

    public init(senderPublicKey: Data, nonce: Data, ciphertext: Data, tag: Data) throws {
        guard senderPublicKey.count == 32 else {
            throw X25519ChaChaPolyError.invalidPublicKeyLength(senderPublicKey.count)
        }
        guard nonce.count == Self.nonceSize else {
            throw X25519ChaChaPolyError.invalidNonceLength(nonce.count)
        }
        self.senderPublicKey = senderPublicKey
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }

    public var combinedCiphertext: Data {
        var data = Data(capacity: nonce.count + ciphertext.count + tag.count)
        data.append(nonce)
        data.append(ciphertext)
        data.append(tag)
        return data
    }
}

public struct X25519ChaChaPoly: Sendable {
    public let salt: Data
    public let sharedInfo: Data

    public init(
        salt: Data = Data(),
        sharedInfo: Data = Data("darkbloom-provider-x25519-chachapoly-v1".utf8)
    ) {
        self.salt = salt
        self.sharedInfo = sharedInfo
    }

    public func seal(
        plaintext: Data,
        recipientPublicKey: Data,
        senderKeyPair: X25519KeyAgreementKeyPair = X25519KeyAgreementKeyPair(),
        nonce: Data? = nil,
        authenticatedData: Data = Data()
    ) throws -> X25519ChaChaPolySealedMessage {
        let key = try senderKeyPair.symmetricKey(
            peerPublicKey: recipientPublicKey,
            salt: salt,
            sharedInfo: sharedInfo
        )
        let cryptoNonce = try makeNonce(nonce)
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: key,
            nonce: cryptoNonce,
            authenticating: authenticatedData
        )
        return try X25519ChaChaPolySealedMessage(
            senderPublicKey: senderKeyPair.publicKey,
            nonce: Data(sealed.nonce),
            ciphertext: sealed.ciphertext,
            tag: sealed.tag
        )
    }

    public func open(
        _ sealed: X25519ChaChaPolySealedMessage,
        recipientKeyPair: X25519KeyAgreementKeyPair,
        authenticatedData: Data = Data()
    ) throws -> Data {
        let key = try recipientKeyPair.symmetricKey(
            peerPublicKey: sealed.senderPublicKey,
            salt: salt,
            sharedInfo: sharedInfo
        )
        let box = try ChaChaPoly.SealedBox(
            nonce: ChaChaPoly.Nonce(data: sealed.nonce),
            ciphertext: sealed.ciphertext,
            tag: sealed.tag
        )
        return try ChaChaPoly.open(box, using: key, authenticating: authenticatedData)
    }

    private func makeNonce(_ data: Data?) throws -> ChaChaPoly.Nonce {
        guard let data else {
            return ChaChaPoly.Nonce()
        }
        guard data.count == X25519ChaChaPolySealedMessage.nonceSize else {
            throw X25519ChaChaPolyError.invalidNonceLength(data.count)
        }
        return try ChaChaPoly.Nonce(data: data)
    }
}
