import CryptoKit
import Foundation

/// The parts of an `inference_request` that make it a blind request: its
/// `blind` member and the coordinator's `signed_request`.
public struct BlindFrame: Sendable, Equatable {
    public let member: BlindFrameMember
    public let signedRequest: String?

    public init(member: BlindFrameMember, signedRequest: String?) {
        self.member = member
        self.signedRequest = signedRequest
    }
}

/// A blind request refused, and what its signed refusal names.
public struct BlindRefusal: Error, Sendable, Equatable {
    public let reason: BlindRefusalReason
    /// SHA-256 of the `signed_request` once it verified; nil before that.
    public let signedRequestSHA256: Data?

    public init(_ reason: BlindRefusalReason, signedRequestSHA256: Data? = nil) {
        self.reason = reason
        self.signedRequestSHA256 = signedRequestSHA256
    }
}

/// A blind frame whose coordinator signature and terms checked out.
public struct VerifiedBlindFrame: Sendable, Equatable {
    public let signature: CoordinatorRequestJWS.Verified
    public let terms: BlindSignedTerms

    var signedRequestSHA256: Data { signature.jwsSHA256 }

    func refusal(_ reason: BlindRefusalReason) -> BlindRefusal {
        BlindRefusal(reason, signedRequestSHA256: signedRequestSHA256)
    }
}

/// The checks of a blind frame before its body is opened: the coordinator's
/// signature, the terms' version, this Mac's place in the seal set, the meta
/// the coordinator acted on, and the client key the body is sealed with.
enum BlindFrameCheck {
    static func verify(
        _ frame: BlindFrame, requestID: String, serviceReservationID: String?,
        ownPublicKey: Data, senderPublicKey: Data, ciphertext: Data,
        pins: [CoordinatorRequestSigningPin], now: Date
    ) -> Result<VerifiedBlindFrame, BlindRefusal> {
        let signature: CoordinatorRequestJWS.Verified
        switch CoordinatorRequestJWS.verify(
            frame.signedRequest, pins: pins, requestID: requestID, serviceReservationID: serviceReservationID,
            recipientPublicKey: ownPublicKey, senderPublicKey: senderPublicKey, ciphertext: ciphertext, now: now) {
        case .success(let verified): signature = verified
        case .failure: return .failure(BlindRefusal(.signatureInvalid))
        }
        let digest = signature.jwsSHA256
        guard let terms = signature.payload.blind else {
            // A signature over an ordinary request does not cover a blind one.
            let reason: BlindRefusalReason = signature.payload.hasBlindMember ? .unsupportedVersion : .signatureInvalid
            return .failure(BlindRefusal(reason, signedRequestSHA256: digest))
        }
        let verified = VerifiedBlindFrame(signature: signature, terms: terms)
        guard terms.version == BlindSignedTerms.currentVersion, frame.member.version == BlindSignedTerms.currentVersion,
              let meta = frame.member.meta, terms.maxTokens > 0, terms.promptTokenBound > 0
        else { return .failure(verified.refusal(.unsupportedVersion)) }
        guard terms.sealSet.contains(where: { Data(base64Encoded: $0) == ownPublicKey }) else {
            return .failure(verified.refusal(.notInSet))
        }
        guard Data(base64Encoded: terms.metaSHA256) == Data(SHA256.hash(data: meta)) else {
            return .failure(verified.refusal(.metaMismatch))
        }
        guard Data(base64Encoded: terms.clientPublicKey) == senderPublicKey else {
            return .failure(verified.refusal(.bindingMismatch))
        }
        return .success(verified)
    }
}

/// What the sealed body of a blind request carries that its checks read.
struct BlindBodyFacts: Equatable {
    var binding: SealedBlindBinding.Lookup
    var model: String
    var maxTokens: Int?
    var maxCompletionTokens: Int?
    var declaresTools: Bool
    var hasMedia: Bool
}

/// The limits a checked blind body is served under.
struct BlindServingTerms: Equatable {
    /// Generation never exceeds this: the body's own limit, at most the signed bound.
    let maxTokens: Int
    let promptTokenBound: Int
    /// The client's cache salt, if it sent one.
    let cacheSalt: Data?
}

/// The checks of an opened blind body against its signed terms.
enum BlindBodyCheck {
    /// How far the client's clock may be from this Mac's, either way.
    static let clientClockWindowMs: Int64 = 600_000

    /// `admitClientNonce` records the request's client nonce and answers
    /// false for one already served.
    static func check(_ body: BlindBodyFacts, frame: VerifiedBlindFrame, now: Date, admitClientNonce: () -> Bool)
        -> Result<BlindServingTerms, BlindRefusalReason> {
        let terms = frame.terms
        let binding: SealedBlindBinding
        switch body.binding {
        case .absent, .malformed: return .failure(.bindingMissing)
        case .binding(let sealed): binding = sealed
        }
        let salt: Data?
        do { salt = try binding.saltBytes() } catch { return .failure(.bindingMismatch) }
        guard let sealedMeta = Data(base64Encoded: binding.metaSHA256),
              sealedMeta == Data(base64Encoded: terms.metaSHA256),
              binding.nonce == terms.clientNonce, binding.cred == terms.accountBinding, binding.ts == terms.clientTs
        else { return .failure(.bindingMismatch) }
        let nowMs = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        guard abs(nowMs - terms.clientTs) <= clientClockWindowMs else { return .failure(.stale) }
        guard admitClientNonce() else { return .failure(.replayed) }
        guard body.model == terms.model, frame.signature.payload.model == terms.model else {
            return .failure(.modelMismatch)
        }
        if let requested = body.maxTokens, requested > terms.maxTokens { return .failure(.boundExceeded) }
        if let requested = body.maxCompletionTokens, requested > terms.maxTokens { return .failure(.boundExceeded) }
        if body.declaresTools && !terms.traits.tools { return .failure(.traitsMismatch) }
        if body.hasMedia && !terms.traits.vision { return .failure(.traitsMismatch) }
        return .success(BlindServingTerms(
            maxTokens: min(body.maxTokens ?? body.maxCompletionTokens ?? terms.maxTokens, terms.maxTokens),
            promptTokenBound: terms.promptTokenBound, cacheSalt: salt))
    }

    /// The prefix-cache scope of a blind request: the coordinator's
    /// account-scoped `cache_scope`, narrowed by the client's salt. No scope,
    /// no cache.
    static func cacheScope(signed: String?, salt: Data?) -> String? {
        guard let signed, !signed.isEmpty else { return nil }
        guard let salt else { return signed }
        var input = Data("darkbloom-blind-cache-salt-v1".utf8)
        input.append(0)
        input.append(salt)
        let suffix = CoordinatorRequestJWS.base64URL(Data(SHA256.hash(data: input))).prefix(22)
        return signed + "|s:" + suffix
    }
}

extension CoordinatorServedRequests {
    /// Records a verified blind request's signed bytes until its signature's
    /// window ends; false for the same signed request again, which gets no
    /// answer: the first copy is the one served.
    mutating func admitBlindSignature(_ signature: CoordinatorRequestJWS.Verified, now: Date) -> Bool {
        let issuedAt = Date(timeIntervalSince1970: TimeInterval(signature.payload.issuedAtMs) / 1000)
        return admit(signature.signingInputSHA256,
            until: issuedAt.addingTimeInterval(TimeInterval(CoordinatorRequestJWS.freshnessMs) / 1000), now: now)
    }

    /// Records a blind request's client nonce until the client clock window
    /// ends; false for a nonce already served.
    mutating func admitBlindClientNonce(_ terms: BlindSignedTerms, now: Date) -> Bool {
        let sealedAt = Date(timeIntervalSince1970: TimeInterval(terms.clientTs) / 1000)
        return admit(Data(SHA256.hash(data: Data(terms.clientNonce.utf8))),
            until: sealedAt.addingTimeInterval(TimeInterval(BlindBodyCheck.clientClockWindowMs) / 1000), now: now)
    }
}
