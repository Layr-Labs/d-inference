import CryptoKit
import Darwin
import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity

/// Called by the authenticated member, using its existing signer and peer pin.
/// Signing is permission for a bounded experiment, not proof of artifact custody.
enum GLM5NextCalibrationAuthorizer {
    struct Authorized {
        let body: GLM5NextCalibrationDocument.Body
        let identity: ClusterWorkerIdentity
        let expectedVocabularySize: Int
        let document: Data
        let credentialInput: Data
        fileprivate init(body: GLM5NextCalibrationDocument.Body, identity: ClusterWorkerIdentity,
                         document: Data, credentialInput: Data, expectedVocabularySize: Int) {
            self.body = body; self.identity = identity; self.document = document
            self.credentialInput = credentialInput
            self.expectedVocabularySize = expectedVocabularySize
        }
    }

    static func authorize(_ body: GLM5NextCalibrationDocument.Body,
                          identity: ClusterWorkerIdentity, rank: Int, now: Int64, expectedVocabularySize: Int,
                          memberIdentity: Data, peerIdentity: Data, appSHA256: String,
                          signer: any AttestationSigner,
                          verifySelection: () throws -> Void) throws -> Authorized {
        try GLM5NextCalibrationDocument.validate(body, identity: identity, rank: rank, now: now, expectedVocabularySize: expectedVocabularySize)
        guard let raw = Data(base64Encoded: signer.publicKeyBase64), raw.count == 64,
              Data([4]) + raw == memberIdentity, memberIdentity != peerIdentity else {
            throw GLM5NextCalibrationDocument.invalid("Signer differs from authenticated member")
        }
        guard GLM5NextCalibrationDocument.hashSyntax(appSHA256),
              body.selection.environment.variableSHA256[GLM5NextCalibrationLaunch.appIdentityVariable]
                == GLM5NextCalibrationLaunch.digest(appSHA256) else {
            throw GLM5NextCalibrationDocument.invalid("Installed app differs from signed environment")
        }
        guard body.selection.environment.variableSHA256[GLM5NextCalibrationLaunch.peerIdentityVariable]
                == GLM5NextCalibrationLaunch.digest(GLM5NextCalibrationLaunch.peerFingerprint(peerIdentity)) else {
            throw GLM5NextCalibrationDocument.invalid("Peer differs from signed environment")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let material = try GLM5NextCalibrationMemberAuthorization.sign(payload: encoder.encode(body),
            purpose: .experiment, epoch: body.selection.epoch, rank: rank,
            memberIdentity: memberIdentity, peerIdentity: peerIdentity, signer: signer,
            verifySelection: verifySelection)
        return Authorized(body: body, identity: identity, document: material.document,
            credentialInput: material.credentialInput, expectedVocabularySize: expectedVocabularySize)
    }

    /// Writes only into an existing owner-private task directory. No replacement,
    /// directory creation, default config selection, or key persistence.
    static func write(_ authorized: Authorized, directory: URL, now: Int64) throws -> URL {
        try GLM5NextCalibrationDocument.validate(authorized.body, identity: authorized.identity,
            rank: authorized.body.selection.rank, now: now, expectedVocabularySize: authorized.expectedVocabularySize)
        return try GLM5NextCalibrationMemberAuthorization.write(document: authorized.document,
            purpose: .experiment, directory: directory)
    }
}
