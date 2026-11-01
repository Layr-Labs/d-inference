import CryptoKit
import Foundation
import DarkbloomClusterProtocol

enum GLM5NextCalibrationQuoteAuthorizer {
    typealias Q = GLM5NextCalibrationQuoteDocument
    typealias D = GLM5NextCalibrationDocument
    struct Authorized {
        let request: Q.Request
        let identity: ClusterWorkerIdentity
        let document: Data
        let credentialInput: Data
        let requestSHA256: String
        fileprivate init(request: Q.Request, identity: ClusterWorkerIdentity,
                         material: GLM5NextCalibrationMemberAuthorization.Material, payload: Data) {
            self.request = request; self.identity = identity
            document = material.document; credentialInput = material.credentialInput
            requestSHA256 = Self.digest(payload)
        }
        private static func digest(_ bytes: Data) -> String {
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
    }

    static func authorize(_ request: Q.Request, identity: ClusterWorkerIdentity, rank: Int, now: Int64,
                          memberIdentity: Data, peerIdentity: Data, appSHA256: String,
                          signer: any AttestationSigner, verifySelection: () throws -> Void) throws -> Authorized {
        try Q.validate(request, identity: identity, rank: rank, now: now,
            appSHA256: appSHA256, peerIdentitySHA256: GLM5NextCalibrationLaunch.peerFingerprint(peerIdentity))
        let payload = try Q.canonical(request)
        let material = try GLM5NextCalibrationMemberAuthorization.sign(payload: payload,
            purpose: .quotation, epoch: request.selection.epoch, rank: rank,
            memberIdentity: memberIdentity, peerIdentity: peerIdentity, signer: signer,
            verifySelection: verifySelection)
        return Authorized(request: request, identity: identity, material: material, payload: payload)
    }

    static func write(_ authorized: Authorized, directory: URL, now: Int64) throws -> URL {
        let request = authorized.request
        try Q.validate(request, identity: authorized.identity, rank: request.selection.rank, now: now,
            appSHA256: request.appSHA256, peerIdentitySHA256: request.peerIdentitySHA256)
        return try GLM5NextCalibrationMemberAuthorization.write(document: authorized.document,
            purpose: .quotation, directory: directory)
    }

    /// Validate only after the source-matched quotation child has actually exited
    /// zero. This validates the wire, not process retirement or payload custody.
    static func validateResponse(_ data: Data, authorized: Authorized, now: Int64, expectedVocabularySize: Int) throws -> Q.Response {
        let response = try validatePublicResponse(data, request: authorized.request, identity: authorized.identity,
            now: now, expectedVocabularySize: expectedVocabularySize)
        guard response.quoteRequestSHA256 == authorized.requestSHA256 else {
            throw D.invalid("Quotation response differs from the authorized request")
        }
        return response
    }

    /// Public wire checks only: not process completion, a credential or an
    /// Authorized constructor. Peer callers must verify the request signature
    /// and authenticated completed-owner claim before treating it as evidence.
    static func validatePublicResponse(_ data: Data, request: Q.Request, identity: ClusterWorkerIdentity,
                                      now: Int64, expectedVocabularySize: Int) throws -> Q.Response {
        let p = request.selection, a = request.authorization
        let requestSHA256 = SHA256.hash(data: try Q.canonical(request)).map { String(format: "%02x", $0) }.joined()
        try Q.validate(request, identity: identity, rank: p.rank, now: now,
            appSHA256: request.appSHA256, peerIdentitySHA256: request.peerIdentitySHA256)
        guard !data.isEmpty, data.count <= 65_536 else { throw D.invalid("Quotation response exceeds bound") }
        let response = try JSONDecoder().decode(Q.Response.self, from: data)
        guard let received = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expected = try JSONSerialization.jsonObject(with: Q.canonical(response)) as? [String: Any],
              Set(received.keys) == Set(expected.keys) else {
            throw D.invalid("Unknown quotation response fields")
        }
        let environmentSHA256 = SHA256.hash(data: try Q.canonical(p.environment))
            .map { String(format: "%02x", $0) }.joined()
        guard response.version == 1, response.purpose == "calibrationQuotation",
              response.quoteRequestID == request.quoteRequestID,
              response.quoteRequestSHA256 == requestSHA256,
              response.rank == p.rank, response.cut == p.cut,
              response.repository == p.repository, response.revision == p.revision,
              response.artifactSHA256 == p.artifactSHA256,
              response.rawConfigurationFileSHA256 == identity.configurationSHA256,
              D.hashSyntax(response.normalizedConfigurationSHA256),
              D.hashSyntax(response.descriptorSHA256), D.hashSyntax(response.inventorySHA256),
              D.hashSyntax(response.numericalPolicySHA256),
              response.executionEnvironmentSHA256 == environmentSHA256,
              !response.qualifiesMaximumEnvelope, !response.payloadVerified,
              response.nativeBytes > 0, response.nativeBytes <= a.nativeHardCapBytes,
              response.hostBytes > 0, response.hostBytes <= a.hostBudgetBytes,
              response.loadCapacityBytes > 0, response.requestCapacityBytes > 0,
              response.loadCapacityBytes == response.nativeBytes + response.hostBytes,
              response.requestCapacityBytes <= response.loadCapacityBytes,
              response.loadCapacityBytes <= a.nativeHardCapBytes + a.hostBudgetBytes else {
            throw D.invalid("Quotation response differs from the authorized request")
        }
        try response.binding.validate(profileID: p.profileID, vocabularySize: expectedVocabularySize,
            prompt: p.maximumPromptTokens, output: p.maximumOutputTokens,
            chunk: p.maximumChunkTokens, context: p.maximumContextTokens)
        guard a.promptTokenIDs.allSatisfy({ $0 < expectedVocabularySize }) else {
            throw D.invalid("Prompt token exceeds the pinned configuration vocabulary")
        }
        return response
    }

    /// Admission of BOTH rank-local metadata claims. The caller must still
    /// observe both actual quotation exits and recheck installed custody before
    /// signing/launching finite experiments. No READY/capability is produced.
    static func experimentBodies(responses: [Data], authorized: [Authorized], now: Int64,
                                 expectedVocabularySizes: [Int]) throws -> [D.Body] {
        guard responses.count == 2, authorized.count == 2, expectedVocabularySizes.count == 2,
              authorized.map({ $0.request.selection.rank }) == [0, 1],
              authorized[0].identity == authorized[1].identity else {
            throw D.invalid("Calibration requires the same committed two-rank identity in rank order")
        }
        let quotes = try (0...1).map {
            try validateResponse(responses[$0], authorized: authorized[$0], now: now,
                expectedVocabularySize: expectedVocabularySizes[$0])
        }
        try requireCommon(requests: authorized.map(\.request), quotes: quotes)
        return try (0...1).map {
            try experimentBody(response: responses[$0], authorized: authorized[$0], now: now,
                expectedVocabularySize: expectedVocabularySizes[$0])
        }
    }

    /// Shared comparison used after each public request/response was validated.
    /// Rank-local device/allocator/resources remain intentionally independent.
    static func requireCommon(requests: [Q.Request], quotes: [Q.Response]) throws {
        guard requests.count == 2, quotes.count == 2, requests.map({ $0.selection.rank }) == [0, 1] else {
            throw D.invalid("Quotation comparison requires both ranks in exact order")
        }
        let left = requests[0], right = requests[1]
        // Device/environment and allocator bounds are rank-local. The remaining
        // selected metadata/scope (including exact file identities) is common.
        func commonSelection(_ selection: Q.Selection) throws -> Data {
            guard var object = try JSONSerialization.jsonObject(with: Q.canonical(selection)) as? [String: Any] else {
                throw D.invalid("Invalid calibration selection")
            }
            for key in ["rank", "environment", "hostAllocationQuantum", "hostAllocationOverhead"] {
                object.removeValue(forKey: key)
            }
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        guard try commonSelection(left.selection) == commonSelection(right.selection),
              left.authorization.requestID == right.authorization.requestID,
              left.authorization.promptTokenIDs == right.authorization.promptTokenIDs,
              left.authorization.outputCount == right.authorization.outputCount,
              left.authorization.chunkSize == right.authorization.chunkSize,
              quotes[0].binding == quotes[1].binding,
              quotes[0].normalizedConfigurationSHA256 == quotes[1].normalizedConfigurationSHA256,
              quotes[0].descriptorSHA256 == quotes[1].descriptorSHA256,
              quotes[0].inventorySHA256 == quotes[1].inventorySHA256,
              quotes[0].numericalPolicySHA256 == quotes[1].numericalPolicySHA256 else {
            throw D.invalid("Rank quotations differ in metadata binding or finite request scope")
        }
    }

    /// Sign the returned body only after BOTH local quotations are admitted and
    /// installed selection/custody is rechecked by the experiment authorizer.
    static func experimentBody(response data: Data, authorized: Authorized, now: Int64, expectedVocabularySize: Int) throws -> D.Body {
        let response = try validateResponse(data, authorized: authorized, now: now, expectedVocabularySize: expectedVocabularySize)
        let p = authorized.request.selection
        let body = D.Body(selection: .init(version: p.version, epoch: p.epoch, rank: p.rank,
            expiresUnixSeconds: p.expiresUnixSeconds, repository: p.repository, revision: p.revision,
            files: p.files, artifactSHA256: p.artifactSHA256, cut: p.cut, profileID: p.profileID,
            maximumPromptTokens: p.maximumPromptTokens, maximumChunkTokens: p.maximumChunkTokens,
            maximumOutputTokens: p.maximumOutputTokens, maximumContextTokens: p.maximumContextTokens,
            policy: p.policy, storage: p.storage, loadCapacityBytes: response.loadCapacityBytes,
            requestCapacityBytes: response.requestCapacityBytes, hostAllocationQuantum: p.hostAllocationQuantum,
            hostAllocationOverhead: p.hostAllocationOverhead, environment: p.environment,
            workspaceEvidence: Data()), authorization: authorized.request.authorization, binding: response.binding)
        try D.validate(body, identity: authorized.identity, rank: p.rank, now: now, expectedVocabularySize: expectedVocabularySize)
        return body
    }
}
