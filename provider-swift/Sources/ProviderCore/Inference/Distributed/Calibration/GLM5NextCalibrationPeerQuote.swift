import CryptoKit
import Foundation
import DarkbloomClusterProtocol

/// Authenticated remote-owner metadata claims, never remotely observed process
/// completion, payload proof or a serving capability. The required receive
/// adapter MUST use the existing exact-pair authenticated control channel.
enum GLM5NextCalibrationPeerQuote {
    private typealias W = GLM5NextCalibrationPeerQuoteDocument
    private typealias Q = GLM5NextCalibrationQuoteDocument
    private typealias D = GLM5NextCalibrationDocument
    private typealias A = GLM5NextCalibrationQuoteAuthorizer
    private typealias C = GLM5NextCalibrationInstalledQuote.Completed

    static func outbound(completed: GLM5NextCalibrationInstalledQuote.Completed,
                         now: Int64, deadline: UInt64) throws -> Data {
        try completed.requireUnchanged(deadline: deadline)
        let request = completed.authorized.request, p = request.selection
        let pair = try W.pair(completed.pair, identity: completed.authorized.identity, rank: p.rank)
        try verifyOwn(completed, now: now)
        // Completed's sole mint site follows observed/drained actual zero exit,
        // resolved metadata journal/lease and full strict response validation.
        // These constants convey that invariant as this owner's signed claim.
        let body = W.Body(version: 1, purpose: "completedCalibrationQuotation", pair: pair,
            identity: .init(completed.authorized.identity), rank: p.rank, epoch: p.epoch,
            requestID: request.authorization.requestID, expiresUnixSeconds: p.expiresUnixSeconds,
            signedRequest: completed.authorized.document,
            signedRequestSHA256: W.hash(completed.authorized.document),
            requestSHA256: completed.authorized.requestSHA256, response: completed.responseData,
            responseSHA256: W.hash(completed.responseData), observedActualExit: true,
            childExitCode: 0, journalResolved: true)
        return try sign(body, completed: completed, deadline: deadline)
    }

    static func admit(completed: GLM5NextCalibrationInstalledQuote.Completed,
                      receiveFromAuthenticatedPair: (GLM5NextCalibrationInstalledPair, UInt64) throws -> Data,
                      now: Int64, deadline: UInt64) throws -> PeerAdmitted {
        try completed.requireUnchanged(deadline: deadline)
        // No bare-Data admission overload. The trusted parent adapter validates
        // exact edge/pair/current connection/incarnation, receives and bounds
        // bytes on authenticated control, and throws on disconnect or mismatch.
        let data = try receiveFromAuthenticatedPair(completed.pair, deadline)
        try completed.requireUnchanged(deadline: deadline)
        let body = try validate(data, completed: completed, now: now)
        try completed.requireUnchanged(deadline: deadline)
        return PeerAdmitted(local: completed, document: data, body: body)
    }

    struct PeerAdmitted {
        let peerRank: Int
        let peerSummarySHA256: String
        let peerRequestSHA256: String
        let peerResponseSHA256: String
        private let local: GLM5NextCalibrationInstalledQuote.Completed
        private let document: Data

        fileprivate init(local: GLM5NextCalibrationInstalledQuote.Completed, document: Data, body: GLM5NextCalibrationPeerQuoteDocument.Body) {
            self.local = local; self.document = document; peerRank = body.rank
            peerSummarySHA256 = W.hash(document); peerRequestSHA256 = body.requestSHA256
            peerResponseSHA256 = body.responseSHA256
        }

        func authorizeOwn(completed: GLM5NextCalibrationInstalledQuote.Completed,
                          now: Int64, deadline: UInt64,
                          requireHeldExclusionAndCustody: () throws -> Void) throws -> GLM5NextCalibrationAuthorizer.Authorized {
            func current() throws {
                try requireHeldExclusionAndCustody()
                try local.requireUnchanged(deadline: deadline)
                try completed.requireUnchanged(deadline: deadline)
                guard matches(completed) else { throw D.invalid("Peer admission belongs to another local Completed") }
                _ = try GLM5NextCalibrationPeerQuote.validate(document, completed: completed, now: now)
                try requireHeldExclusionAndCustody()
                try completed.requireUnchanged(deadline: deadline)
            }
            try current()
            // Only own Completed supplies the body and actual paired signer.
            // No peer Authorized, dummy credentialInput or remote Completed.
            let body = try A.experimentBody(response: completed.responseData, authorized: completed.authorized,
                now: now, expectedVocabularySize: completed.pinnedVocabularySize)
            let authorized = try GLM5NextCalibrationAuthorizer.authorize(body, identity: completed.authorized.identity,
                rank: body.selection.rank, now: now, expectedVocabularySize: completed.pinnedVocabularySize,
                memberIdentity: completed.pair.localIdentity, peerIdentity: completed.pair.peerIdentity,
                appSHA256: completed.authorized.request.appSHA256, signer: completed.pair.signer,
                verifySelection: current)
            try current()
            return authorized
        }

        private func matches(_ completed: GLM5NextCalibrationInstalledQuote.Completed) -> Bool {
            local.authorized.identity == completed.authorized.identity
                && local.authorized.document == completed.authorized.document
                && local.responseData == completed.responseData
                && local.pinnedVocabularySize == completed.pinnedVocabularySize
                && local.installedExecutable == completed.installedExecutable
                && local.worker == completed.worker && local.metallib == completed.metallib
                && local.modelDirectory == completed.modelDirectory && local.environment == completed.environment
                && local.pair.clusterID == completed.pair.clusterID
                && local.pair.localIdentity == completed.pair.localIdentity
                && local.pair.peerIdentity == completed.pair.peerIdentity
                && local.pair.record == completed.pair.record
        }
    }

    private static func sign(_ body: W.Body, completed: GLM5NextCalibrationInstalledQuote.Completed,
                             deadline: UInt64) throws -> Data {
        let payload = try Q.canonical(body)
        guard !payload.isEmpty, payload.count <= W.maximumPayloadBytes,
              let raw = Data(base64Encoded: completed.pair.signer.publicKeyBase64), raw.count == 64,
              Data([4]) + raw == completed.pair.localIdentity else {
            throw D.invalid("Invalid completed peer quotation signer or payload")
        }
        try completed.requireUnchanged(deadline: deadline)
        // One signature by the already paired identity. No MemberAuthorization
        // call, replacement identity or ephemeral worker credential is needed.
        let signature = try P256.Signing.ECDSASignature(
            derRepresentation: completed.pair.signer.sign(W.domain + payload))
        let key = try P256.Signing.PublicKey(x963Representation: completed.pair.localIdentity)
        guard key.isValidSignature(signature, for: W.domain + payload) else {
            throw D.invalid("Completed peer quotation signature failed verification")
        }
        try completed.requireUnchanged(deadline: deadline)
        let data = try Q.canonical(D.SignedDocument(payload: payload, signature: signature.rawRepresentation))
        guard data.count <= W.maximumDocumentBytes else { throw D.invalid("Completed peer quotation exceeds bound") }
        return data
    }

    private static func verifyOwn(_ completed: C, now: Int64) throws {
        let request = try W.request(completed.authorized.document, key: completed.pair.localIdentity)
        let payload = try Q.canonical(request), expected = try Q.canonical(completed.authorized.request)
        guard payload == expected, W.hash(payload) == completed.authorized.requestSHA256 else {
            throw D.invalid("Own completed quotation request differs from its signed public document")
        }
        let response = try A.validateResponse(completed.responseData, authorized: completed.authorized,
            now: now, expectedVocabularySize: completed.pinnedVocabularySize)
        guard try Q.canonical(response) == completed.responseData else {
            throw D.invalid("Own completed quotation response is not exact canonical bytes")
        }
        try requireFP32(request)
    }

    private static func validate(_ data: Data, completed: C, now: Int64) throws -> W.Body {
        try verifyOwn(completed, now: now)
        let local = completed.authorized.request, identity = completed.authorized.identity
        let pair = try W.pair(completed.pair, identity: identity, rank: local.selection.rank)
        let body = try W.verify(data, key: completed.pair.peerIdentity)
        guard body.version == 1, body.purpose == "completedCalibrationQuotation", body.pair == pair,
              body.identity == W.Identity(identity), body.rank == 1 - local.selection.rank,
              body.epoch == local.selection.epoch, body.requestID == local.authorization.requestID,
              body.expiresUnixSeconds == local.selection.expiresUnixSeconds,
              body.observedActualExit, body.childExitCode == 0, body.journalResolved,
              body.signedRequestSHA256 == W.hash(body.signedRequest), body.responseSHA256 == W.hash(body.response) else {
            throw D.invalid("Peer completed quotation differs from the exact pair, rank, scope or completion claim")
        }
        let request = try W.request(body.signedRequest, key: completed.pair.peerIdentity)
        let requestSHA256 = try W.hash(Q.canonical(request))
        guard request.selection.rank == body.rank, request.selection.epoch == body.epoch,
              request.authorization.requestID == body.requestID, request.selection.expiresUnixSeconds == body.expiresUnixSeconds,
              requestSHA256 == body.requestSHA256,
              request.peerIdentitySHA256 == GLM5NextCalibrationLaunch.peerFingerprint(completed.pair.localIdentity),
              request.selection.environment.metallibSHA256 == local.selection.environment.metallibSHA256 else {
            throw D.invalid("Peer completed quotation public request differs from expected identity/runtime/scope")
        }
        try requireFP32(request)
        let response = try A.validatePublicResponse(body.response, request: request, identity: identity,
            now: now, expectedVocabularySize: completed.pinnedVocabularySize)
        // Actual worker uses sortedKeys/withoutEscapingSlashes. Bind the
        // original bytes; never rewrite/normalize a remote completion claim.
        guard try Q.canonical(response) == body.response else {
            throw D.invalid("Peer completed quotation response is not exact canonical bytes")
        }
        let requests = local.selection.rank == 0 ? [local, request] : [request, local]
        let quotes = local.selection.rank == 0 ? [completed.response, response] : [response, completed.response]
        try A.requireCommon(requests: requests, quotes: quotes)
        return body
    }

    private static func requireFP32(_ request: Q.Request) throws {
        guard request.selection.environment.variableSHA256["MLX_ENABLE_TF32"] == GLM5NextCalibrationLaunch.digest("0") else {
            throw D.invalid("Completed peer quotation requires the explicit finite FP32 contract")
        }
    }
}
