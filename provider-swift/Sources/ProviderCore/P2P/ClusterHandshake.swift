import CryptoKit
import Foundation

// MARK: - ClusterHandshake
//
// Mutual SE authentication + ephemeral X25519 ECDH session key establishment.
//
// Protocol:
//   Rank 0 → Rank 1:  HandshakeHello { se_pub_0, x25519_pub_0, nonce_0, sig_0 }
//                     sig_0 = SE_sign(SHA256(x25519_pub_0 || nonce_0))
//
//   Rank 1 → Rank 0:  HandshakeAck   { se_pub_1, x25519_pub_1, nonce_1, sig_1 }
//                     sig_1 = SE_sign(SHA256(nonce_0 || nonce_1 || x25519_pub_1))
//
//   Session key = HKDF-SHA256(X25519(sk_local, pk_peer), salt: nonce_0 || nonce_1)
//
// SE key pinning (TOFU):
//   On first connection, accept the peer's SE public key and pin it to disk.
//   On subsequent connections, verify the received key matches the pinned one.

public struct ClusterHandshake: Sendable {

    // MARK: - TOFU pinning path

    static func pinnedKeyPath(peerIP: String) -> URL {
        URL(fileURLWithPath: "/etc/darkbloom/cluster-peer-\(peerIP).sekey")
    }

    // MARK: - Rank 0 initiates

    /// Run the full handshake as rank 0 (initiator).
    /// Returns the AES-256-GCM session key shared with rank 1.
    public static func performAsRank0(
        connection: ThunderboltConnection,
        signer: any AttestationSigner,
        peerIP: String
    ) async throws -> SymmetricKey {
        // 1. Generate ephemeral X25519 key pair + nonce.
        let localKP = X25519KeyAgreementKeyPair()
        let nonce0 = randomBytes(32)

        // 2. Sign commitment: SHA256(x25519_pub || nonce0)
        let commitment0 = Data(SHA256.hash(data: localKP.publicKey + nonce0))
        let sig0 = try signer.sign(commitment0)

        // 3. Send Hello.
        let hello = HandshakeHello(
            sePubKeyRaw: Data(base64Encoded: signer.publicKeyBase64)!,
            ephemeralX25519PubKey: localKP.publicKey,
            nonce: nonce0,
            seSignature: sig0
        )
        let helloFrame = try ClusterFrame.encodeJSON(type: .handshakeHello, value: hello)
        try await connection.send(helloFrame)

        // 4. Receive Ack.
        let ackFrame = try await connection.receive()
        guard try ClusterFrame.decodeType(from: ackFrame) == .handshakeAck else {
            throw ClusterError.handshakeFailed("expected handshakeAck")
        }
        let ack = try ClusterFrame.decodeJSON(HandshakeAck.self, from: ackFrame)

        // 5. Pin / verify peer SE key.
        try pinOrVerify(peerSEKey: ack.sePubKeyRaw, peerIP: peerIP)

        // 6. Verify ack signature: SHA256(nonce0 || ack.nonce || ack.x25519_pub)
        let commitment1 = Data(SHA256.hash(data: nonce0 + ack.nonce + ack.ephemeralX25519PubKey))
        guard SecureEnclaveIdentity.verify(
            signature: ack.seSignature,
            for: commitment1,
            publicKey: ack.sePubKeyRaw
        ) else {
            throw ClusterError.handshakeFailed("ack SE signature invalid")
        }

        // 7. Derive session key.
        return try deriveKey(
            localKP: localKP,
            peerX25519PubKey: ack.ephemeralX25519PubKey,
            nonce0: nonce0,
            nonce1: ack.nonce
        )
    }

    // MARK: - Rank 1 responds

    /// Run the full handshake as rank 1 (responder).
    /// Returns the AES-256-GCM session key shared with rank 0.
    public static func performAsRank1(
        connection: ThunderboltConnection,
        signer: any AttestationSigner,
        peerIP: String
    ) async throws -> SymmetricKey {
        // 1. Receive Hello.
        let helloFrame = try await connection.receive()
        guard try ClusterFrame.decodeType(from: helloFrame) == .handshakeHello else {
            throw ClusterError.handshakeFailed("expected handshakeHello")
        }
        let hello = try ClusterFrame.decodeJSON(HandshakeHello.self, from: helloFrame)

        // 2. Pin / verify peer SE key.
        try pinOrVerify(peerSEKey: hello.sePubKeyRaw, peerIP: peerIP)

        // 3. Verify hello signature: SHA256(x25519_pub || nonce0)
        let commitment0 = Data(SHA256.hash(data: hello.ephemeralX25519PubKey + hello.nonce))
        guard SecureEnclaveIdentity.verify(
            signature: hello.seSignature,
            for: commitment0,
            publicKey: hello.sePubKeyRaw
        ) else {
            throw ClusterError.handshakeFailed("hello SE signature invalid")
        }

        // 4. Generate ephemeral key pair + nonce1.
        let localKP = X25519KeyAgreementKeyPair()
        let nonce1 = randomBytes(32)

        // 5. Sign: SHA256(nonce0 || nonce1 || x25519_pub_1)
        let commitment1 = Data(SHA256.hash(data: hello.nonce + nonce1 + localKP.publicKey))
        let sig1 = try signer.sign(commitment1)

        // 6. Send Ack.
        let ack = HandshakeAck(
            sePubKeyRaw: Data(base64Encoded: signer.publicKeyBase64)!,
            ephemeralX25519PubKey: localKP.publicKey,
            nonce: nonce1,
            seSignature: sig1
        )
        let ackFrame = try ClusterFrame.encodeJSON(type: .handshakeAck, value: ack)
        try await connection.send(ackFrame)

        // 7. Derive session key.
        return try deriveKey(
            localKP: localKP,
            peerX25519PubKey: hello.ephemeralX25519PubKey,
            nonce0: hello.nonce,
            nonce1: nonce1
        )
    }

    // MARK: - Key derivation

    private static func deriveKey(
        localKP: X25519KeyAgreementKeyPair,
        peerX25519PubKey: Data,
        nonce0: Data,
        nonce1: Data
    ) throws -> SymmetricKey {
        return try localKP.symmetricKey(
            peerPublicKey: peerX25519PubKey,
            salt: nonce0 + nonce1,
            sharedInfo: Data("darkbloom-cluster-session-v1".utf8)
        )
    }

    // MARK: - TOFU pinning

    private static func pinOrVerify(peerSEKey: Data, peerIP: String) throws {
        let path = pinnedKeyPath(peerIP: peerIP)

        if FileManager.default.fileExists(atPath: path.path) {
            let pinned = try Data(contentsOf: path)
            guard pinned == peerSEKey else {
                throw ClusterError.peerSEKeyMismatch
            }
        } else {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try peerSEKey.write(to: path, options: .atomic)
        }
    }

    // MARK: - Helpers

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}
