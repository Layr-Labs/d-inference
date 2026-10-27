import CryptoKit
import Foundation
import Testing
@testable import ProviderCore

/// UNRUN. Required opt-in fails if the pinned metadata selector is missing;
/// ordinary runs skip this actual-child fixture suite explicitly. No GPU/model.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_GLM_METADATA_INPUT"] != nil
    || ProcessInfo.processInfo.environment["DARKBLOOM_GLM_METADATA_BINDING_REQUIRED"] == "1"))
struct GLM5NextCalibrationPeerQuoteTests {
    typealias F = GLM5NextCalibrationPeerQuoteFixture
    typealias P = GLM5NextCalibrationPeerQuote
    typealias W = GLM5NextCalibrationPeerQuoteDocument
    typealias Q = GLM5NextCalibrationQuoteDocument
    typealias D = GLM5NextCalibrationDocument
    enum Refusal: Error { case unauthenticatedChannel, noCustody }

    @Test func twoActualCompletedOwnersExchangeSummariesAndSignOnlyOwnFiniteBody() throws {
        let f = try F()
        let before = f.peerSigner.calls
        let summary = try f.summary()
        #expect(f.peerSigner.calls == before + 1) // No ephemeral quotation worker key/certificate.
        let admitted = try f.admit(summary)
        #expect(admitted.peerRank == f.peer.authorized.request.selection.rank)
        #expect(admitted.peerSummarySHA256 == W.hash(summary))
        #expect(admitted.peerRequestSHA256 == f.peer.authorized.requestSHA256)
        #expect(admitted.peerResponseSHA256 == W.hash(f.peer.responseData))
        let body = try W.verify(summary, key: f.local.pair.peerIdentity)
        #expect(body.signedRequest == f.peer.authorized.document)
        #expect(body.response == f.peer.responseData)
        #expect(body.observedActualExit && body.childExitCode == 0 && body.journalResolved)
        #expect(!f.peer.response.payloadVerified && !f.peer.response.qualifiesMaximumEnvelope)
        #expect(f.local.authorized.request.authorization.nativeHardCapBytes
            != f.peer.authorized.request.authorization.nativeHardCapBytes)
        #expect(f.local.authorized.request.selection.hostAllocationQuantum
            != f.peer.authorized.request.selection.hostAllocationQuantum)
        var custodyChecks = 0
        let ownBefore = f.localSigner.calls
        let authorized = try admitted.authorizeOwn(completed: f.local, now: f.now, deadline: f.deadline,
            requireHeldExclusionAndCustody: { custodyChecks += 1 })
        #expect(custodyChecks >= 2)
        #expect(f.localSigner.calls == ownBefore + 2) // Existing finite document + worker certificate only.
        let expected = try GLM5NextCalibrationQuoteAuthorizer.experimentBody(response: f.local.responseData,
            authorized: f.local.authorized, now: f.now, expectedVocabularySize: f.local.pinnedVocabularySize)
        #expect(try Q.canonical(authorized.body) == Q.canonical(expected))
        let localSummary = try P.outbound(completed: f.local, now: f.now, deadline: f.deadline)
        let reverse = try P.admit(completed: f.peer, receiveFromAuthenticatedPair: { pair, _ in
            #expect(pair.record == f.peer.pair.record); return localSummary
        }, now: f.now, deadline: f.deadline)
        #expect(reverse.peerRank == f.local.authorized.request.selection.rank)
        _ = try reverse.authorizeOwn(completed: f.peer, now: f.now, deadline: f.deadline,
            requireHeldExclusionAndCustody: {}) // Fixture-only dependency, no actual custody claim.
        try f.requireBothFreshLeases()
    }

    @Test func signaturesCanonicalEncodingDomainsAndBothPublicSignaturesAreRequired() throws {
        let f = try F(), summary = try f.summary(), body = try f.body(summary)
        #expect(throws: (any Error).self) { try f.admit(summary + Data([0x20])) }
        let envelope = try JSONDecoder().decode(D.SignedDocument.self, from: summary)
        var badSignature = envelope.signature; badSignature[0] ^= 1
        let corrupt = try Q.canonical(D.SignedDocument(payload: envelope.payload, signature: badSignature))
        #expect(throws: (any Error).self) { try f.admit(corrupt) }
        let changedPayload = try Q.canonical(D.SignedDocument(payload: envelope.payload + Data([0x20]), signature: envelope.signature))
        #expect(throws: (any Error).self) { try f.admit(changedPayload) }
        var extraEnvelope = try F.object(envelope); extraEnvelope["unexpected"] = true
        #expect(throws: (any Error).self) { try f.admit(F.json(extraEnvelope)) }
        for domain in [Q.domain, D.domain, Data()] {
            #expect(throws: (any Error).self) { try f.admit(f.signed(body, domain: domain)) }
        }
        #expect(throws: (any Error).self) { try f.admit(f.signed(body, signer: f.localSigner)) }
        var unknown = body; unknown["unexpected"] = true
        #expect(throws: (any Error).self) { try f.admit(f.signed(unknown)) }
        #expect(throws: (any Error).self) {
            try f.admit(f.changingRequest(summary, change: { _ in }, requestDomain: D.domain))
        }
        #expect(throws: (any Error).self) {
            try f.admit(f.changingRequest(summary, change: { _ in }, requestSigner: f.localSigner))
        }
        #expect(throws: (any Error).self) {
            try f.admit(f.changingRequest(summary, change: { $0["unexpected"] = true }))
        }
        // Noncanonical whitespace is rejected even with a genuine outer signature.
        let noncanonical = try Q.canonical(D.SignedDocument(payload: envelope.payload + Data([0x20]),
            signature: f.peerSigner.key.signature(for: W.domain + envelope.payload + Data([0x20])).rawRepresentation))
        #expect(throws: (any Error).self) { try f.admit(noncanonical) }
        var noncanonicalResponse = body
        let rawResponse = try #require(Data(base64Encoded: body["response"] as! String)) + Data([0x20])
        noncanonicalResponse["response"] = rawResponse.base64EncodedString()
        noncanonicalResponse["responseSHA256"] = W.hash(rawResponse)
        #expect(throws: (any Error).self) { try f.admit(f.signed(noncanonicalResponse)) }
    }

    @Test func authenticatedInvalidPairRankScopeAndExitClaimsRefuse() throws {
        let f = try F(), summary = try f.summary()
        let mutations: [([String], Any)] = [
            (["version"], 2), (["purpose"], "serving"),
            (["pair", "clusterID"], "another-cluster"), (["pair", "generation"], 2),
            (["pair", "rosterSHA256"], String(repeating: "b", count: 64)),
            (["pair", "ceremonyTranscriptSHA256"], String(repeating: "b", count: 64)),
            (["pair", "linkEpoch"], UUID().uuidString), (["pair", "edgeID"], UUID().uuidString),
            (["rank"], f.local.authorized.request.selection.rank), (["epoch"], UUID().uuidString),
            (["identity", "modelID"], "another-model"), (["identity", "configurationSHA256"], String(repeating: "b", count: 64)),
            (["requestID"], UUID().uuidString), (["expiresUnixSeconds"], f.peer.authorized.request.selection.expiresUnixSeconds - 1),
            (["signedRequestSHA256"], String(repeating: "b", count: 64)),
            (["requestSHA256"], String(repeating: "b", count: 64)), (["responseSHA256"], String(repeating: "b", count: 64)),
            (["observedActualExit"], false), (["childExitCode"], 9), (["journalResolved"], false)
        ]
        for (path, value) in mutations {
            var body = try f.body(summary); F.set(&body, path: path, to: value)
            #expect(throws: (any Error).self, "admitted summary mutation \(path)") { try f.admit(f.signed(body)) }
        }
        #expect(throws: (any Error).self) { try f.admit(summary, now: f.peer.authorized.request.selection.expiresUnixSeconds) }
    }

    @Test func resignedPublicRequestCommonRuntimePrecisionAndResourceMutationsRefuse() throws {
        let f = try F(), summary = try f.summary()
        let mutations: [([String], Any)] = [
            (["selection", "rank"], f.local.authorized.request.selection.rank),
            (["selection", "epoch"], UUID().uuidString), (["authorization", "requestID"], UUID().uuidString),
            (["peerIdentitySHA256"], String(repeating: "b", count: 64)),
            (["appSHA256"], String(repeating: "b", count: 64)),
            (["selection", "expiresUnixSeconds"], f.peer.authorized.request.selection.expiresUnixSeconds - 1),
            (["selection", "cut"], f.peer.authorized.request.selection.cut + 1),
            (["selection", "files", "config.json", "sha256"], String(repeating: "b", count: 64)),
            (["selection", "environment", "binarySHA256"], String(repeating: "b", count: 64)),
            (["selection", "environment", "metallibSHA256"], String(repeating: "b", count: 64)),
            (["selection", "environment", "variableSHA256", "MLX_ENABLE_TF32"], GLM5NextCalibrationLaunch.digest("1")),
            (["authorization", "promptTokenIDs"], [2, 1]), (["authorization", "outputCount"], 1),
            (["authorization", "chunkSize"], 1), (["authorization", "nativeHardCapBytes"], 1399),
            (["authorization", "hostBudgetBytes"], 499), (["authorization", "osHeadroomBytes"], 10000),
            (["authorization", "workspaceNativeAllowanceBytes"], 2100),
            (["authorization", "workspaceHostAllowanceBytes"], 1100),
            (["authorization", "nativeHardCapBytes"], Int.max),
            (["selection", "hostAllocationQuantum"], 0), (["selection", "hostAllocationOverhead"], -1)
        ]
        for (path, value) in mutations {
            let changed = try f.changingRequest(summary, change: { request in F.set(&request, path: path, to: value) })
            #expect(throws: (any Error).self, "admitted public request mutation \(path)") { try f.admit(changed) }
        }
    }

    @Test func responseMetadataPlanProfileAndBoundsCannotBeSubstitutedEvenWhenResigned() throws {
        let f = try F(), summary = try f.summary()
        let mutations: [([String], Any)] = [
            (["rawConfigurationFileSHA256"], String(repeating: "b", count: 64)),
            (["normalizedConfigurationSHA256"], String(repeating: "a", count: 64)),
            (["descriptorSHA256"], String(repeating: "a", count: 64)),
            (["inventorySHA256"], String(repeating: "a", count: 64)),
            (["numericalPolicySHA256"], String(repeating: "a", count: 64)),
            (["binding", "executionPlanSHA256"], String(repeating: "a", count: 64)),
            (["binding", "profile", "vocabularySize"], f.local.pinnedVocabularySize + 1),
            (["binding", "profile", "id"], "another-profile"), (["binding", "unexpected"], true),
            (["nativeBytes"], 2101), (["hostBytes"], 1101), (["requestCapacityBytes"], 1901),
            (["loadCapacityBytes"], 1899), (["payloadVerified"], true), (["qualifiesMaximumEnvelope"], true),
            (["unexpected"], true)
        ]
        for (path, value) in mutations {
            let changed = try f.changingResponse(summary, change: { response in F.set(&response, path: path, to: value) })
            #expect(throws: (any Error).self, "admitted response mutation \(path)") { try f.admit(changed) }
        }
    }

    @Test func channelAndHeldCustodyAreMandatoryAndCannotBeReplacedBySignature() throws {
        let f = try F(), summary = try f.summary()
        #expect(throws: Refusal.unauthenticatedChannel) {
            try P.admit(completed: f.local, receiveFromAuthenticatedPair: { _, _ in
                throw Refusal.unauthenticatedChannel
            }, now: f.now, deadline: f.deadline)
        }
        let admitted = try f.admit(summary), before = f.localSigner.calls
        #expect(throws: Refusal.noCustody) {
            try admitted.authorizeOwn(completed: f.local, now: f.now, deadline: f.deadline,
                requireHeldExclusionAndCustody: { throw Refusal.noCustody })
        }
        #expect(f.localSigner.calls == before)
        #expect(throws: (any Error).self) {
            try admitted.authorizeOwn(completed: f.peer, now: f.now, deadline: f.deadline,
                requireHeldExclusionAndCustody: {})
        }
        #expect(f.localSigner.calls == before)
    }

    @Test func changedOwnFilesPairAndDeadlineInvalidateOutboundAdmissionAndFiniteSigning() throws {
        let f = try F(), summary = try f.summary(), admitted = try f.admit(summary)
        let past = DispatchTime.now().uptimeNanoseconds - 1
        #expect(throws: (any Error).self) { try P.outbound(completed: f.peer, now: f.now, deadline: past) }
        #expect(throws: (any Error).self) {
            try admitted.authorizeOwn(completed: f.local, now: f.now, deadline: past, requireHeldExclusionAndCustody: {})
        }
        try Data("changed fixture AOT".utf8).write(to: f.base.metallib)
        #expect(throws: (any Error).self) { try f.summary() }
        #expect(throws: (any Error).self) { try f.admit(summary) }
        #expect(throws: (any Error).self) {
            try admitted.authorizeOwn(completed: f.local, now: f.now, deadline: f.deadline,
                requireHeldExclusionAndCustody: {})
        }
        let another = try F(), anotherSummary = try another.summary(), anotherAdmitted = try another.admit(anotherSummary)
        try another.base.pairing.write()
        #expect(throws: (any Error).self) { try another.admit(anotherSummary) }
        #expect(throws: (any Error).self) {
            try anotherAdmitted.authorizeOwn(completed: another.local, now: another.now, deadline: another.deadline,
                requireHeldExclusionAndCustody: {})
        }
    }

    @Test func receiveChangingCurrentFilesCannotAdmitAndFailedChildCannotMintSummary() throws {
        let f = try F(), summary = try f.summary()
        #expect(throws: (any Error).self) {
            try P.admit(completed: f.local, receiveFromAuthenticatedPair: { _, _ in
                try Data("changed during receive".utf8).write(to: f.base.app)
                return summary
            }, now: f.now, deadline: f.deadline)
        }
        let failed = try GLM5NextCalibrationInstalledQuoteCompletedTests.Fixture(mode: "nonzero")
        #expect(throws: (any Error).self) { try failed.complete() }
        try failed.requireFreshDeviceLease()
        // No Completed was returned, so outbound has no legitimate input.
    }
}

/// UNRUN compatibility checks without the actual-child metadata opt-in.
@Suite struct GLM5NextCalibrationPublicQuoteValidationTests {
    typealias A = GLM5NextCalibrationQuoteAuthorizer
    typealias Q = GLM5NextCalibrationQuoteDocument
    @Test func sharedPublicValidatorPreservesOrdinaryValidWireAcceptance() throws {
        let f = try GLM5NextCalibrationQuoteAuthorizerTests.Fixture(), authorized = try f.authorize()
        let canonical = try Q.canonical(f.response(authorized))
        let object = try JSONSerialization.jsonObject(with: canonical)
        let spaced = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        for bytes in [canonical, spaced] {
            let owned = try A.validateResponse(bytes, authorized: authorized, now: 1000, expectedVocabularySize: 512)
            let wire = try A.validatePublicResponse(bytes, request: authorized.request, identity: authorized.identity,
                now: 1000, expectedVocabularySize: 512)
            #expect(try Q.canonical(owned) == Q.canonical(wire))
            #expect(wire.quoteRequestSHA256 == authorized.requestSHA256)
        }
    }
    @Test func bothResponseEntriesRejectStaleHashUnknownAuthorityAndExceededResources() throws {
        let f = try GLM5NextCalibrationQuoteAuthorizerTests.Fixture(), authorized = try f.authorize()
        let response = try GLM5NextCalibrationPeerQuoteFixture.object(f.response(authorized))
        let changes: [(String, Any)] = [
            ("quoteRequestSHA256", String(repeating: "b", count: 64)), ("unexpectedAuthority", true),
            ("nativeBytes", 2001), ("hostBytes", 1001), ("payloadVerified", true), ("qualifiesMaximumEnvelope", true)
        ]
        for (key, value) in changes {
            var changed = response; changed[key] = value
            let bytes = try GLM5NextCalibrationPeerQuoteFixture.json(changed)
            #expect(throws: (any Error).self) { try A.validateResponse(bytes, authorized: authorized, now: 1000, expectedVocabularySize: 512) }
            #expect(throws: (any Error).self) {
                try A.validatePublicResponse(bytes, request: authorized.request, identity: authorized.identity,
                    now: 1000, expectedVocabularySize: 512)
            }
        }
    }
}
