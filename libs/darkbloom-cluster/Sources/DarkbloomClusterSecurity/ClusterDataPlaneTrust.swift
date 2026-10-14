import CryptoKit
import Foundation

/// Closed, payload-free failures of the data-plane key exchange (S16). Never
/// carries key bytes, signatures or a received hello.
public enum ClusterDataPlaneTrustError: Error, Equatable, Sendable {
    case invalidCredential, invalidHello, wrongPeer, peerNotPinned
    case certificateRejected, helloSignatureRejected, keyConfirmationFailed, inactive
}

/// One member's long-term identity as its peer pins it: a P-256 signing public
/// key in X9.63 form (65 bytes). Production: the provider's Secure Enclave key,
/// pinned by the pairing ceremony (S17). Qualification and the SSH-installed
/// pair: an identity the launcher made for the session and handed to each
/// member over its authenticated control route.
public struct ClusterDataPlanePin: Sendable, Equatable {
    public let identityPublicKey: Data

    public init(identityPublicKey: Data) throws {
        guard identityPublicKey.count == 65,
              (try? P256.Signing.PublicKey(x963Representation: identityPublicKey)) != nil else {
            throw ClusterDataPlaneTrustError.invalidCredential
        }
        self.identityPublicKey = identityPublicKey
    }

    public init(_ key: P256.Signing.PublicKey) { identityPublicKey = key.x963Representation }

    var key: P256.Signing.PublicKey {
        get throws {
            do { return try P256.Signing.PublicKey(x963Representation: identityPublicKey) }
            catch { throw ClusterDataPlaneTrustError.invalidCredential }
        }
    }
    public var sha256: Data { Data(SHA256.hash(data: identityPublicKey)) }
}

/// The member's statement that one worker signing key speaks for it, at one
/// rank, in one membership epoch. Signed by the member's identity key: in
/// production its Secure Enclave key, which never leaves the provider (the
/// worker only ever holds the per-epoch worker key this certifies).
public enum ClusterDataPlaneCertificate {
    static let domain = Data("darkbloom/data-plane/worker-certificate/v1\0".utf8)

    public static func message(epoch: UUID, rank: Int, workerSigningPublicKey: Data) throws -> Data {
        guard (0...1).contains(rank), workerSigningPublicKey.count == 65,
              !clusterRecordUUIDBytes(epoch).allSatisfy({ $0 == 0 }) else {
            throw ClusterDataPlaneTrustError.invalidCredential
        }
        var result = domain
        result.append(clusterRecordUUIDBytes(epoch)); result.append(UInt8(rank)); result.append(workerSigningPublicKey)
        return result
    }

    /// A software identity key (qualification, SSH-installed pair). A Secure
    /// Enclave key signs `message(...)` itself and yields the same 64-byte form.
    public static func sign(identity: P256.Signing.PrivateKey, epoch: UUID, rank: Int,
                            workerSigningPublicKey: Data) throws -> Data {
        let bytes = try message(epoch: epoch, rank: rank, workerSigningPublicKey: workerSigningPublicKey)
        do { return try identity.signature(for: bytes).rawRepresentation }
        catch { throw ClusterDataPlaneTrustError.invalidCredential }
    }

    static func isValid(_ signature: Data, identity: ClusterDataPlanePin, epoch: UUID, rank: Int,
                        workerSigningPublicKey: Data) -> Bool {
        guard signature.count == 64,
              let value = try? P256.Signing.ECDSASignature(rawRepresentation: signature),
              let bytes = try? message(epoch: epoch, rank: rank, workerSigningPublicKey: workerSigningPublicKey),
              let key = try? identity.key else { return false }
        return key.isValidSignature(value, for: bytes)
    }
}

/// What one worker is given for one membership epoch, on its control pipe and
/// never on a command line: a fresh worker signing key, its member's
/// certificate over it, its member's identity, and the identity it pins for
/// its peer. The worker refuses a credential whose certificate does not verify.
public struct ClusterDataPlaneCredential: Sendable {
    public let epoch: UUID
    public let rank: Int
    let workerSigningKey: P256.Signing.PrivateKey
    public let workerCertificate: Data
    public let memberIdentity: ClusterDataPlanePin
    public let peerPin: ClusterDataPlanePin

    public init(epoch: UUID, rank: Int, workerSigningKey: Data, workerCertificate: Data,
                memberIdentity: Data, peerPin: Data) throws {
        guard (0...1).contains(rank), !clusterRecordUUIDBytes(epoch).allSatisfy({ $0 == 0 }),
              workerSigningKey.count == 32, workerCertificate.count == 64,
              let key = try? P256.Signing.PrivateKey(rawRepresentation: workerSigningKey) else {
            throw ClusterDataPlaneTrustError.invalidCredential
        }
        let member = try ClusterDataPlanePin(identityPublicKey: memberIdentity)
        let peer = try ClusterDataPlanePin(identityPublicKey: peerPin)
        guard member != peer, member.identityPublicKey != key.publicKey.x963Representation,
              peer.identityPublicKey != key.publicKey.x963Representation else {
            throw ClusterDataPlaneTrustError.invalidCredential
        }
        guard ClusterDataPlaneCertificate.isValid(workerCertificate, identity: member, epoch: epoch, rank: rank,
            workerSigningPublicKey: key.publicKey.x963Representation) else {
            throw ClusterDataPlaneTrustError.certificateRejected
        }
        self.epoch = epoch; self.rank = rank; self.workerSigningKey = key
        self.workerCertificate = workerCertificate; self.memberIdentity = member; self.peerPin = peer
    }

    /// The launcher's side: a fresh worker key for this epoch and rank,
    /// certified by the member's identity key.
    public static func issue(identity: P256.Signing.PrivateKey, epoch: UUID, rank: Int,
                             peerPin: ClusterDataPlanePin) throws -> ClusterDataPlaneCredential {
        let worker = P256.Signing.PrivateKey()
        let certificate = try ClusterDataPlaneCertificate.sign(identity: identity, epoch: epoch, rank: rank,
            workerSigningPublicKey: worker.publicKey.x963Representation)
        return try .init(epoch: epoch, rank: rank, workerSigningKey: worker.rawRepresentation,
            workerCertificate: certificate, memberIdentity: identity.publicKey.x963Representation,
            peerPin: peerPin.identityPublicKey)
    }

    /// The four fields for the launcher's control-pipe codec. The first is the
    /// worker's secret: it goes to that worker's control pipe only.
    public var wireFields: (workerSigningKey: Data, workerCertificate: Data, memberIdentity: Data, peerPin: Data) {
        (workerSigningKey.rawRepresentation, workerCertificate, memberIdentity.identityPublicKey, peerPin.identityPublicKey)
    }
}

/// What both ranks know once the exchange is confirmed. Not secret: the
/// transcript digest is equal on both ranks of one keyed session, so a launcher
/// can compare the two ranks' receipts.
public struct ClusterDataPlaneReceipt: Sendable, Equatable {
    public let epoch: UUID
    public let rank: Int
    public let transcriptSHA256: Data
    /// The edge (one cable, two members): from both pinned identities, sorted.
    public let edgeID: Data
    public let peerIdentitySHA256: Data
    /// The peer's hello verified against its pinned identity before any key.
    public let peerVerified: Bool

    public var transcriptHex: String { transcriptSHA256.map { String(format: "%02x", $0) }.joined() }
    public var edgeHex: String { edgeID.map { String(format: "%02x", $0) }.joined() }
}

/// The data plane's key exchange between the two ranks of one edge (S16, D1).
/// Each rank sends one fixed-size signed hello; each verifies its peer's hello
/// against the identity it pins (certificate, then hello signature) BEFORE it
/// derives anything; both derive the native record master and confirmation
/// key from X25519 over the transcript (`ClusterNativeKeyDerivation.swift`);
/// both exchange key-confirmation tags; only then is a record transport made,
/// once, with directional keys and the rekey policy. Hellos are public and may
/// travel in the clear; nothing secret leaves this object.
public final class ClusterDataPlaneKeyExchange: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let helloBytes = 384
    public static let confirmationBytes = 32
    static let helloMagic: [UInt8] = [0x44, 0x42, 0x44, 0x48] // DBDH
    static let helloSignatureDomain = Data("darkbloom/data-plane/hello/v1\0".utf8)
    static let transcriptDomain = Data("darkbloom/data-plane/transcript/v1\0".utf8)
    static let edgeDomain = Data("darkbloom/data-plane/edge/v1\0".utf8)
    private static let signedBytes = 314

    private enum Phase { case fresh, accepted, confirmed, consumed, failed }
    private let lock = NSLock()
    private let credential: ClusterDataPlaneCredential
    private let scopeSHA256: Data
    private var phase: Phase = .fresh
    private var privateKey: Curve25519.KeyAgreement.PrivateKey?
    private var keys: NativeDerivedTrafficKeys?
    private var transcript: Data?
    private var peerIdentity: ClusterDataPlanePin?
    /// This rank's hello, to send as is.
    public let hello: Data
    public var description: String { "ClusterDataPlaneKeyExchange(redacted)" }
    public var debugDescription: String { description }

    /// `scopeSHA256` binds the exchange to what both ranks are about to agree
    /// (the load agreement): a peer told something else fails here.
    public init(credential: ClusterDataPlaneCredential, scopeSHA256: Data) throws {
        guard scopeSHA256.count == 32 else { throw ClusterDataPlaneTrustError.invalidCredential }
        self.credential = credential; self.scopeSHA256 = scopeSHA256
        let key = Curve25519.KeyAgreement.PrivateKey()
        privateKey = key
        var bytes = Data(Self.helloMagic)
        bytes.append(contentsOf: [1, UInt8(credential.rank), 0, 0])
        bytes.append(clusterRecordUUIDBytes(credential.epoch)); bytes.append(scopeSHA256)
        bytes.append(credential.memberIdentity.identityPublicKey)
        bytes.append(credential.workerSigningKey.publicKey.x963Representation)
        bytes.append(credential.workerCertificate)
        bytes.append(key.publicKey.rawRepresentation)
        let nonce = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        guard nonce.count == 32, bytes.count + 32 == Self.signedBytes else {
            throw ClusterDataPlaneTrustError.invalidCredential
        }
        bytes.append(nonce)
        do {
            bytes.append(try credential.workerSigningKey.signature(for: Self.helloSignatureDomain + bytes).rawRepresentation)
        } catch { throw ClusterDataPlaneTrustError.invalidCredential }
        bytes.append(Data(count: Self.helloBytes - bytes.count))
        hello = bytes
    }

    /// Verifies the peer's hello against the pinned identity, then derives the
    /// keys. Returns this rank's key-confirmation tag for the peer.
    public func accept(peerHello: Data) throws -> Data {
        do {
            let key: Curve25519.KeyAgreement.PrivateKey = try lock.withLock {
                guard phase == .fresh, let key = privateKey else { throw ClusterDataPlaneTrustError.inactive }
                return key
            }
            let peer = try verify(peerHello)
            let ordered = credential.rank == 0 ? [hello, peerHello] : [peerHello, hello]
            var material = Self.transcriptDomain
            for value in ordered { material.append(value) }
            let digest = Data(SHA256.hash(data: material))
            let derived: NativeDerivedTrafficKeys
            do {
                derived = try NativeTrafficKeyDerivation.derive(privateKey: key, peerPublicKey: peer.agreementKey,
                    transcriptSHA256: digest)
            } catch { throw ClusterDataPlaneTrustError.invalidHello }
            let tag = try NativeTrafficKeyDerivation.confirmation(rank: credential.rank, transcriptSHA256: digest,
                key: derived.confirmation)
            try lock.withLock {
                guard phase == .fresh else { throw ClusterDataPlaneTrustError.inactive }
                keys = derived; transcript = digest; peerIdentity = peer.identity; privateKey = nil; phase = .accepted
            }
            return tag
        } catch { invalidate(); throw (error as? ClusterDataPlaneTrustError) ?? .invalidHello }
    }

    /// The peer's tag over the same transcript under the same confirmation key:
    /// proof that the peer derived the same keys.
    public func confirm(peerTag: Data) throws {
        do {
            try lock.withLock {
                guard phase == .accepted, let keys, let transcript else { throw ClusterDataPlaneTrustError.inactive }
                do {
                    try NativeTrafficKeyDerivation.verify(peerTag, rank: 1 - credential.rank,
                        transcriptSHA256: transcript, key: keys.confirmation)
                } catch { throw ClusterDataPlaneTrustError.keyConfirmationFailed }
                phase = .confirmed
            }
        } catch { invalidate(); throw (error as? ClusterDataPlaneTrustError) ?? .keyConfirmationFailed }
    }

    /// Domain of the tensor-parallel sealed all-sum's direction keys.
    static let tensorParallelSealDomain = Data("darkbloom/data-plane/tensor-parallel-seal/v1\0".utf8)
    private var tensorParallelSealDerived = false

    /// At most once, after confirmation and before `makeTransport`: the two
    /// direction keys of the tensor-parallel sealed all-sum (the partials of
    /// every row-parallel projection cross the cable as AES-256-GCM frames).
    /// HKDF-SHA256 of this session's confirmed record master, salted by the
    /// transcript, with the sender's rank and `scope` (the load agreement) in
    /// the info: keys of one session, direction and agreement only, never the
    /// record transport's own keys. Nothing else leaves this object.
    public func tensorParallelSealKeys(scope: Data) throws -> (send: SymmetricKey, receive: SymmetricKey) {
        try lock.withLock {
            guard phase == .confirmed, !tensorParallelSealDerived, let keys, let transcript,
                  (1...64).contains(scope.count) else {
                throw ClusterDataPlaneTrustError.inactive
            }
            tensorParallelSealDerived = true
            func key(sender: Int) -> SymmetricKey {
                var info = Self.tensorParallelSealDomain
                info.append(UInt8(sender)); info.append(UInt8(1 - sender)); info.append(scope)
                return HKDF<SHA256>.deriveKey(inputKeyMaterial: keys.recordMaster, salt: transcript, info: info,
                    outputByteCount: 32)
            }
            return (key(sender: credential.rank), key(sender: 1 - credential.rank))
        }
    }

    /// Once, after confirmation: the record transport over `io`, bound to the
    /// epoch, the scope and the transcript. The record master is dropped here.
    public func makeTransport(io: any ClusterRecordByteIO, limits: ClusterRecordLimits,
                              rekey: ClusterRecordRekeyPolicy?) throws -> (ClusterAuthenticatedRecordTransport, ClusterDataPlaneReceipt) {
        do {
            let (master, digest, peer): (SymmetricKey, Data, ClusterDataPlanePin) = try lock.withLock {
                guard phase == .confirmed, let keys, let transcript, let peerIdentity else {
                    throw ClusterDataPlaneTrustError.inactive
                }
                phase = .consumed; self.keys = nil
                return (keys.recordMaster, transcript, peerIdentity)
            }
            guard io.localRank == credential.rank, io.worldSize == 2 else { throw ClusterDataPlaneTrustError.wrongPeer }
            let binding = try ClusterRecordBinding(epoch: credential.epoch, planSHA256: scopeSHA256,
                membershipTranscriptSHA256: digest)
            let transport = try ClusterAuthenticatedRecordTransport(sessionKey: master, binding: binding,
                limits: limits, io: io, rekey: rekey)
            let identities = [credential.memberIdentity.identityPublicKey, peer.identityPublicKey]
                .sorted { $0.lexicographicallyPrecedes($1) }
            var edge = Self.edgeDomain
            for value in identities { edge.append(value) }
            let receipt = ClusterDataPlaneReceipt(epoch: credential.epoch, rank: credential.rank,
                transcriptSHA256: digest, edgeID: Data(SHA256.hash(data: edge).prefix(16)),
                peerIdentitySHA256: peer.sha256, peerVerified: true)
            return (transport, receipt)
        } catch { invalidate(); throw (error as? ClusterDataPlaneTrustError) ?? .inactive }
    }

    public func invalidate() {
        lock.withLock { phase = .failed; privateKey = nil; keys = nil }
    }

    private struct PeerHello { let identity: ClusterDataPlanePin; let agreementKey: Data }

    /// Every field against this rank's own expectation; the identity against
    /// the pin, then the certificate under the pin, then the hello signature
    /// under the certified worker key. Nothing is derived before all pass.
    private func verify(_ data: Data) throws -> PeerHello {
        guard data.count == Self.helloBytes else { throw ClusterDataPlaneTrustError.invalidHello }
        let bytes = [UInt8](data)
        let peerRank = 1 - credential.rank
        guard Array(bytes[0..<4]) == Self.helloMagic, bytes[4] == 1, bytes[6] == 0, bytes[7] == 0,
              bytes[378...].allSatisfy({ $0 == 0 }) else { throw ClusterDataPlaneTrustError.invalidHello }
        guard Int(bytes[5]) == peerRank, Data(bytes[8..<24]) == clusterRecordUUIDBytes(credential.epoch),
              Data(bytes[24..<56]) == scopeSHA256 else { throw ClusterDataPlaneTrustError.wrongPeer }
        let identity = Data(bytes[56..<121]), workerKey = Data(bytes[121..<186])
        let certificate = Data(bytes[186..<250]), agreement = Data(bytes[250..<282])
        let signature = Data(bytes[314..<378])
        // Constant-time comparison is not needed for public keys; equality is.
        guard identity == credential.peerPin.identityPublicKey else { throw ClusterDataPlaneTrustError.peerNotPinned }
        guard ClusterDataPlaneCertificate.isValid(certificate, identity: credential.peerPin, epoch: credential.epoch,
            rank: peerRank, workerSigningPublicKey: workerKey) else { throw ClusterDataPlaneTrustError.certificateRejected }
        guard let signer = try? P256.Signing.PublicKey(x963Representation: workerKey),
              let value = try? P256.Signing.ECDSASignature(rawRepresentation: signature),
              signer.isValidSignature(value, for: Self.helloSignatureDomain + Data(bytes[0..<Self.signedBytes])) else {
            throw ClusterDataPlaneTrustError.helloSignatureRejected
        }
        guard nativeCanonicalX25519PublicKey(agreement), data != hello,
              Data(hello[250..<282]) != agreement else { throw ClusterDataPlaneTrustError.invalidHello }
        return .init(identity: credential.peerPin, agreementKey: agreement)
    }
}
