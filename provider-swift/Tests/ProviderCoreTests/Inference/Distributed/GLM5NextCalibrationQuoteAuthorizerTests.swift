import CryptoKit
import Darwin
import Foundation
import Testing
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
@testable import ProviderCore

@Suite struct GLM5NextCalibrationQuoteAuthorizerTests {
    typealias Q = GLM5NextCalibrationQuoteDocument
    typealias A = GLM5NextCalibrationQuoteAuthorizer
    typealias D = GLM5NextCalibrationDocument

    struct Fixture {
        let base: GLM5NextCalibrationAuthorizerTests.Fixture
        let request: Q.Request
        init() throws {
            base = try .init()
            let p = base.body.selection
            var files = p.files
            files["model-00001-of-00001.safetensors"] = .init(bytes: 128, sha256: String(repeating: "a", count: 64))
            request = .init(quoteRequestID: UUID(),
                peerIdentitySHA256: GLM5NextCalibrationLaunch.peerFingerprint(base.peer.publicKey.x963Representation),
                appSHA256: String(repeating: "a", count: 64),
                selection: .init(version: p.version, epoch: p.epoch, rank: p.rank,
                    expiresUnixSeconds: p.expiresUnixSeconds, repository: p.repository,
                    revision: p.revision, files: files, artifactSHA256: p.artifactSHA256, cut: p.cut,
                    profileID: p.profileID, maximumPromptTokens: p.maximumPromptTokens,
                    maximumChunkTokens: p.maximumChunkTokens, maximumOutputTokens: p.maximumOutputTokens,
                    maximumContextTokens: p.maximumContextTokens, policy: p.policy, storage: p.storage,
                    mode: "coldTextBatch1", hostAllocationQuantum: p.hostAllocationQuantum,
                    hostAllocationOverhead: p.hostAllocationOverhead, environment: p.environment),
                authorization: base.body.authorization)
        }
        func authorize(_ value: Q.Request? = nil, verify: () throws -> Void = {}) throws -> A.Authorized {
            try A.authorize(value ?? request, identity: base.identity, rank: 0, now: 1000,
                memberIdentity: base.signer.key.publicKey.x963Representation,
                peerIdentity: base.peer.publicKey.x963Representation, appSHA256: request.appSHA256,
                signer: base.signer, verifySelection: verify)
        }
        func response(_ authorized: A.Authorized) throws -> Q.Response {
            let request = authorized.request
            let p = request.selection
            return .init(version: 1, purpose: "calibrationQuotation", quoteRequestID: request.quoteRequestID,
                quoteRequestSHA256: authorized.requestSHA256, rank: p.rank, cut: p.cut,
                repository: p.repository, revision: p.revision, artifactSHA256: p.artifactSHA256,
                rawConfigurationFileSHA256: base.identity.configurationSHA256,
                normalizedConfigurationSHA256: String(repeating: "b", count: 64),
                descriptorSHA256: String(repeating: "c", count: 64), inventorySHA256: String(repeating: "d", count: 64),
                numericalPolicySHA256: String(repeating: "e", count: 64),
                executionEnvironmentSHA256: SHA256.hash(data: try Q.canonical(p.environment)).map { String(format: "%02x", $0) }.joined(),
                nativeBytes: 1400, hostBytes: 500, loadCapacityBytes: 1900, requestCapacityBytes: 1000,
                qualifiesMaximumEnvelope: false, payloadVerified: false, binding: base.body.binding)
        }
    }

    @Test func quoteUsesExistingMemberAndSeparateDomain() throws {
        let f = try Fixture(), result = try f.authorize()
        let signed = try JSONDecoder().decode(D.SignedDocument.self, from: result.document)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signed.signature)
        let key = f.base.signer.key.publicKey
        #expect(key.isValidSignature(signature, for: Q.domain + signed.payload))
        #expect(!key.isValidSignature(signature, for: D.domain + signed.payload))
        #expect(!key.isValidSignature(signature, for: Data("darkbloom/glm-worker-qualification/v1\0".utf8) + signed.payload))
        #expect(signed.payload == (try Q.canonical(f.request)))
        #expect(result.requestSHA256 == SHA256.hash(data: signed.payload).map { String(format: "%02x", $0) }.joined())
        let wire = try ClusterWorkerCodec.decodeDataPlaneTrust(result.credentialInput)
        #expect(wire.memberIdentity == key.x963Representation)
        #expect(wire.peerPin == f.base.peer.publicKey.x963Representation)
        _ = try ClusterDataPlaneCredential(epoch: wire.membershipEpoch, rank: wire.rank,
            workerSigningKey: wire.workerSigningKey, workerCertificate: wire.workerCertificate,
            memberIdentity: wire.memberIdentity, peerPin: wire.peerPin)
        #expect(f.base.signer.calls == 2)
        if let path = ProcessInfo.processInfo.environment["DARKBLOOM_CALIBRATION_QUOTE_FIXTURE"] {
            let export: [String: Any] = ["document": result.document.base64EncodedString(),
                "memberPublicKey": key.x963Representation.base64EncodedString(),
                "peerPublicKey": f.base.peer.publicKey.x963Representation.base64EncodedString(),
                "epoch": f.request.selection.epoch.uuidString.lowercased(), "rank": 0, "now": 1000]
            try JSONSerialization.data(withJSONObject: export, options: [.sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
    }

    @Test func invalidQuoteScopeNeverReachesSigner() throws {
        let f = try Fixture()
        let changes: [(String, String, Any)] = [
            ("selection", "rank", 1), ("selection", "epoch", UUID().uuidString),
            ("selection", "mode", "serving"), ("selection", "cut", 45),
            ("selection", "expiresUnixSeconds", 1000), ("selection", "expiresUnixSeconds", 4601),
            ("selection", "maximumPromptTokens", 2049), ("selection", "maximumContextTokens", 2),
            ("selection", "hostAllocationQuantum", 0), ("selection", "hostAllocationOverhead", -1),
            ("selection", "repository", "unselected/model"),
            ("authorization", "nativeHardCapBytes", Int.max),
            ("authorization", "workspaceHostAllowanceBytes", 1000)
        ]
        for (section, key, value) in changes {
            var json = try #require(JSONSerialization.jsonObject(with: Q.canonical(f.request)) as? [String: Any])
            var object = try #require(json[section] as? [String: Any]); object[key] = value; json[section] = object
            let changed = try JSONDecoder().decode(Q.Request.self, from: JSONSerialization.data(withJSONObject: json))
            #expect(throws: (any Error).self) { try f.authorize(changed) }
        }
        #expect(f.base.signer.calls == 0)
    }

    @Test func crossedMemberPeerAppAndCustodyRefuseBeforeSigning() throws {
        let f = try Fixture(), other = P256.Signing.PrivateKey().publicKey.x963Representation
        for (member, peer, app) in [
            (other, f.base.peer.publicKey.x963Representation, f.request.appSHA256),
            (f.base.signer.key.publicKey.x963Representation, other, f.request.appSHA256),
            (f.base.signer.key.publicKey.x963Representation, f.base.peer.publicKey.x963Representation, String(repeating: "f", count: 64))
        ] {
            #expect(throws: (any Error).self) {
                try A.authorize(f.request, identity: f.base.identity, rank: 0, now: 1000,
                    memberIdentity: member, peerIdentity: peer, appSHA256: app,
                    signer: f.base.signer, verifySelection: {})
            }
        }
        #expect(throws: (any Error).self) { try f.authorize(verify: { throw D.invalid("Custody changed") }) }
        #expect(f.base.signer.calls == 0)
    }

    @Test func returnedQuoteSuppliesCapacitiesWithoutChangingScope() throws {
        let f = try Fixture(), authorized = try f.authorize(), response = try f.response(authorized)
        let data = try Q.canonical(response)
        let body = try A.experimentBody(response: data, authorized: authorized, now: 1000, expectedVocabularySize: 512)
        #expect(body.binding == response.binding)
        #expect(body.selection.loadCapacityBytes == 1900)
        #expect(body.selection.requestCapacityBytes == 1000)
        #expect(body.selection.workspaceEvidence.isEmpty)
        #expect(body.authorization == f.request.authorization)
        #expect(body.selection.environment == f.request.selection.environment)
        #expect(body.selection.cut == f.request.selection.cut)
        #expect(response.normalizedConfigurationSHA256 != f.base.identity.configurationSHA256)
        let final = try f.base.authorize(body)
        let signed = try JSONDecoder().decode(D.SignedDocument.self, from: final.document)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signed.signature)
        #expect(f.base.signer.key.publicKey.isValidSignature(signature, for: D.domain + signed.payload))
        #expect(!f.base.signer.key.publicKey.isValidSignature(signature, for: Q.domain + signed.payload))
        #expect(SHA256.hash(data: signed.payload).map { String(format: "%02x", $0) }.joined() != authorized.requestSHA256)
    }

    @Test func changedResponseIdentityCapacityOrClaimsRefused() throws {
        let f = try Fixture(), authorized = try f.authorize()
        let original = try Q.canonical(f.response(authorized))
        let changes: [(String, Any)] = [
            ("version", 2), ("purpose", "serving"), ("quoteRequestID", UUID().uuidString),
            ("quoteRequestSHA256", String(repeating: "0", count: 64)), ("rank", 1), ("cut", 21),
            ("revision", "changed"), ("rawConfigurationFileSHA256", String(repeating: "1", count: 64)),
            ("normalizedConfigurationSHA256", "invalid"), ("executionEnvironmentSHA256", String(repeating: "2", count: 64)),
            ("nativeBytes", 2001), ("hostBytes", 1001), ("requestCapacityBytes", 1901),
            ("loadCapacityBytes", 1800), ("loadCapacityBytes", 2000),
            ("loadCapacityBytes", 3001), ("qualifiesMaximumEnvelope", true), ("payloadVerified", true),
            ("unexpectedAuthority", true)
        ]
        for (key, value) in changes {
            var json = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any]); json[key] = value
            let data = try JSONSerialization.data(withJSONObject: json)
            #expect(throws: (any Error).self) { try A.validateResponse(data, authorized: authorized, now: 1000, expectedVocabularySize: 512) }
        }
        #expect(throws: (any Error).self) { try A.validateResponse(original, authorized: authorized, now: 1100, expectedVocabularySize: 512) }
        #expect(throws: (any Error).self) { try A.validateResponse(Data(repeating: 32, count: 65_537), authorized: authorized, now: 1000, expectedVocabularySize: 512) }
    }
    @Test func bindingIsRequiredClosedAndMatchesAllSixProfileFields() throws {
        let f = try Fixture(), authorized = try f.authorize()
        let original = try #require(JSONSerialization.jsonObject(with: Q.canonical(f.response(authorized))) as? [String: Any])
        func refuse(_ value: [String: Any], vocabulary: Int = 512) throws {
            let bytes = try JSONSerialization.data(withJSONObject: value)
            #expect(throws: (any Error).self) {
                try A.validateResponse(bytes, authorized: authorized, now: 1000, expectedVocabularySize: vocabulary)
            }
        }
        var missing = original; missing.removeValue(forKey: "binding"); try refuse(missing)
        let binding = try #require(original["binding"] as? [String: Any])
        for key in binding.keys {
            var changed = binding; changed.removeValue(forKey: key)
            var root = original; root["binding"] = changed; try refuse(root)
        }
        var unknown = binding; unknown["qualified"] = true
        var root = original; root["binding"] = unknown; try refuse(root)
        var invalidPlan = binding; invalidPlan["executionPlanSHA256"] = "not-a-plan"
        root["binding"] = invalidPlan; try refuse(root)
        let profile = try #require(binding["profile"] as? [String: Any])
        for key in profile.keys {
            var changed = profile; changed.removeValue(forKey: key)
            var nested = binding; nested["profile"] = changed
            root = original; root["binding"] = nested; try refuse(root)
        }
        let changes: [(String, Any)] = [("id", "different"), ("vocabularySize", 513),
            ("maximumPromptTokens", 5), ("maximumOutputTokens", 3),
            ("maximumChunkTokens", 1), ("maximumContextTokens", 9), ("extra", true)]
        for (key, value) in changes {
            var changed = profile; changed[key] = value
            var nested = binding; nested["profile"] = changed
            root = original; root["binding"] = nested; try refuse(root)
        }
        try refuse(original, vocabulary: 511) // Expected vocabulary is independent of the response.
        let body = try A.experimentBody(response: Q.canonical(f.response(authorized)), authorized: authorized,
            now: 1000, expectedVocabularySize: 512)
        #expect(body.binding == f.base.body.binding)
    }

    @Test func bothRanksMustAgreeBeforeFiniteExperimentBodiesAreReturned() throws {
        let f = try Fixture(), first = try f.authorize()
        var object = try #require(JSONSerialization.jsonObject(with: Q.canonical(f.request)) as? [String: Any])
        object["quoteRequestID"] = UUID().uuidString
        object["peerIdentitySHA256"] = GLM5NextCalibrationLaunch.peerFingerprint(f.base.signer.key.publicKey.x963Representation)
        var selection = try #require(object["selection"] as? [String: Any]); selection["rank"] = 1
        var environment = try #require(selection["environment"] as? [String: Any])
        var variables = try #require(environment["variableSHA256"] as? [String: String])
        variables[GLM5NextCalibrationLaunch.peerIdentityVariable] = GLM5NextCalibrationLaunch.digest(
            GLM5NextCalibrationLaunch.peerFingerprint(f.base.signer.key.publicKey.x963Representation))
        environment["variableSHA256"] = variables; selection["environment"] = environment
        object["selection"] = selection
        let request = try JSONDecoder().decode(Q.Request.self, from: JSONSerialization.data(withJSONObject: object))
        let signer = GLM5NextCalibrationAuthorizerTests.Signer(key: f.base.peer)
        let second = try A.authorize(request, identity: f.base.identity, rank: 1, now: 1000,
            memberIdentity: f.base.peer.publicKey.x963Representation,
            peerIdentity: f.base.signer.key.publicKey.x963Representation,
            appSHA256: request.appSHA256, signer: signer, verifySelection: {})
        let responses = try [first, second].map { try Q.canonical(f.response($0)) }
        let bodies = try A.experimentBodies(responses: responses, authorized: [first, second], now: 1000,
            expectedVocabularySizes: [512, 512])
        #expect(bodies.map { $0.selection.rank } == [0, 1])
        #expect(bodies[0].binding == bodies[1].binding)
        #expect(throws: (any Error).self) {
            try A.experimentBodies(responses: responses, authorized: [first, first], now: 1000,
                expectedVocabularySizes: [512, 512])
        }
        #expect(throws: (any Error).self) {
            try A.experimentBodies(responses: [responses[0]], authorized: [first], now: 1000,
                expectedVocabularySizes: [512])
        }
        // Expiry is a shared cohort scope: each quote may be valid by itself,
        // but a separately signed 1099 expiry cannot join the 1100 cohort.
        var differentExpiryObject = object
        var differentExpirySelection = try #require(differentExpiryObject["selection"] as? [String: Any])
        differentExpirySelection["expiresUnixSeconds"] = 1099
        differentExpiryObject["selection"] = differentExpirySelection
        let differentExpiryRequest = try JSONDecoder().decode(Q.Request.self,
            from: JSONSerialization.data(withJSONObject: differentExpiryObject))
        let differentExpiry = try A.authorize(differentExpiryRequest, identity: f.base.identity, rank: 1, now: 1000,
            memberIdentity: f.base.peer.publicKey.x963Representation,
            peerIdentity: f.base.signer.key.publicKey.x963Representation,
            appSHA256: request.appSHA256, signer: signer, verifySelection: {})
        let differentExpiryResponse = try Q.canonical(f.response(differentExpiry))
        _ = try A.validateResponse(differentExpiryResponse, authorized: differentExpiry, now: 1000,
            expectedVocabularySize: 512)
        #expect(first.request.selection.expiresUnixSeconds == 1100)
        #expect(differentExpiry.request.selection.expiresUnixSeconds == 1099)
        #expect(throws: (any Error).self) {
            try A.experimentBodies(responses: [responses[0], differentExpiryResponse],
                authorized: [first, differentExpiry], now: 1000, expectedVocabularySizes: [512, 512])
        }

        // Allocator bounds and native/host/OS budgets remain rank-local. Both
        // actual wire quotes must fit their own independently signed allowances.
        var heterogeneousObject = object
        var heterogeneousSelection = try #require(heterogeneousObject["selection"] as? [String: Any])
        heterogeneousSelection["hostAllocationQuantum"] = 32
        heterogeneousSelection["hostAllocationOverhead"] = 8
        heterogeneousObject["selection"] = heterogeneousSelection
        var heterogeneousAuthorization = try #require(heterogeneousObject["authorization"] as? [String: Any])
        heterogeneousAuthorization["nativeHardCapBytes"] = 2400
        heterogeneousAuthorization["hostBudgetBytes"] = 1200
        heterogeneousAuthorization["osHeadroomBytes"] = 800
        heterogeneousObject["authorization"] = heterogeneousAuthorization
        let heterogeneousRequest = try JSONDecoder().decode(Q.Request.self,
            from: JSONSerialization.data(withJSONObject: heterogeneousObject))
        let heterogeneous = try A.authorize(heterogeneousRequest, identity: f.base.identity, rank: 1, now: 1000,
            memberIdentity: f.base.peer.publicKey.x963Representation,
            peerIdentity: f.base.signer.key.publicKey.x963Representation,
            appSHA256: request.appSHA256, signer: signer, verifySelection: {})
        let heterogeneousResponse = try Q.canonical(f.response(heterogeneous))
        _ = try A.validateResponse(heterogeneousResponse, authorized: heterogeneous, now: 1000,
            expectedVocabularySize: 512)
        let heterogeneousBodies = try A.experimentBodies(responses: [responses[0], heterogeneousResponse],
            authorized: [first, heterogeneous], now: 1000, expectedVocabularySizes: [512, 512])
        #expect(heterogeneousBodies.count == 2)
        #expect(heterogeneousBodies[0].authorization == first.request.authorization)
        #expect(heterogeneousBodies[1].authorization == heterogeneousRequest.authorization)
        #expect(heterogeneousBodies[0].authorization.nativeHardCapBytes == 2000)
        #expect(heterogeneousBodies[0].authorization.hostBudgetBytes == 1000)
        #expect(heterogeneousBodies[0].authorization.osHeadroomBytes == 1000)
        #expect(heterogeneousBodies[1].authorization.nativeHardCapBytes == 2400)
        #expect(heterogeneousBodies[1].authorization.hostBudgetBytes == 1200)
        #expect(heterogeneousBodies[1].authorization.osHeadroomBytes == 800)
        #expect(heterogeneousBodies[0].selection.hostAllocationQuantum == 16)
        #expect(heterogeneousBodies[0].selection.hostAllocationOverhead == 0)
        #expect(heterogeneousBodies[1].selection.hostAllocationQuantum == 32)
        #expect(heterogeneousBodies[1].selection.hostAllocationOverhead == 8)
        #expect(heterogeneousBodies[0].binding == heterogeneousBodies[1].binding)

        let changedIdentity = ClusterWorkerIdentity(membershipEpoch: f.base.identity.membershipEpoch,
            modelID: f.base.identity.modelID, artifactSHA256: f.base.identity.artifactSHA256,
            configurationSHA256: f.base.identity.configurationSHA256,
            peers: [.init(id: "one", buildSHA256: String(repeating: "f", count: 64)), f.base.identity.peers[1]])
        let crossed = try A.authorize(request, identity: changedIdentity, rank: 1, now: 1000,
            memberIdentity: f.base.peer.publicKey.x963Representation,
            peerIdentity: f.base.signer.key.publicKey.x963Representation,
            appSHA256: request.appSHA256, signer: signer, verifySelection: {})
        #expect(throws: (any Error).self) {
            try A.experimentBodies(responses: [responses[0], Q.canonical(f.response(crossed))],
                authorized: [first, crossed], now: 1000, expectedVocabularySizes: [512, 512])
        }
        var foreignRequest = object
        var foreignAuthorization = try #require(foreignRequest["authorization"] as? [String: Any])
        foreignAuthorization["requestID"] = UUID().uuidString
        foreignRequest["authorization"] = foreignAuthorization
        let differentFiniteRequest = try JSONDecoder().decode(Q.Request.self,
            from: JSONSerialization.data(withJSONObject: foreignRequest))
        let foreign = try A.authorize(differentFiniteRequest, identity: f.base.identity, rank: 1, now: 1000,
            memberIdentity: f.base.peer.publicKey.x963Representation,
            peerIdentity: f.base.signer.key.publicKey.x963Representation,
            appSHA256: request.appSHA256, signer: signer, verifySelection: {})
        #expect(throws: (any Error).self) {
            try A.experimentBodies(responses: [responses[0], Q.canonical(f.response(foreign))],
                authorized: [first, foreign], now: 1000, expectedVocabularySizes: [512, 512])
        }
        for key in ["descriptorSHA256", "inventorySHA256", "normalizedConfigurationSHA256", "numericalPolicySHA256", "executionPlanSHA256"] {
            var changed = try #require(JSONSerialization.jsonObject(with: responses[1]) as? [String: Any])
            if key == "executionPlanSHA256" {
                var binding = try #require(changed["binding"] as? [String: Any])
                binding[key] = String(repeating: "f", count: 64); changed["binding"] = binding
            } else { changed[key] = String(repeating: "f", count: 64) }
            let bytes = try JSONSerialization.data(withJSONObject: changed)
            // This rank-local claim is well-formed; disagreement is a pair failure.
            _ = try A.validateResponse(bytes, authorized: second, now: 1000, expectedVocabularySize: 512)
            #expect(throws: (any Error).self) {
                try A.experimentBodies(responses: [responses[0], bytes], authorized: [first, second], now: 1000,
                    expectedVocabularySizes: [512, 512])
            }
        }
    }


    @Test func finite2048QuoteToExperimentPreservesAuthorityAndRejectsStaleScope() throws {
        let f = try Fixture()
        let original = try #require(JSONSerialization.jsonObject(with: Q.canonical(f.request)) as? [String: Any])
        func expanded(prompt: Int = 2048, chunk: Int = 2048, output: Int = 16, context: Int = 2064) throws -> Q.Request {
            var object = original, selection = try #require(original["selection"] as? [String: Any])
            selection["maximumPromptTokens"] = prompt; selection["maximumChunkTokens"] = chunk
            selection["maximumOutputTokens"] = output; selection["maximumContextTokens"] = context
            object["selection"] = selection
            var authorization = try #require(original["authorization"] as? [String: Any])
            authorization["promptTokenIDs"] = Array(repeating: 1, count: prompt)
            authorization["chunkSize"] = chunk; authorization["outputCount"] = output
            object["authorization"] = authorization
            return try JSONDecoder().decode(Q.Request.self, from: JSONSerialization.data(withJSONObject: object))
        }
        for (prompt, chunk, output, context) in [(2049, 2048, 16, 2064), (2048, 2049, 16, 2064),
            (2048, 2048, 17, 2064), (2048, 2048, 16, 2063), (2048, 2048, 16, 2065)] {
            #expect(throws: (any Error).self) {
                try f.authorize(expanded(prompt: prompt, chunk: chunk, output: output, context: context))
            }
        }
        #expect(f.base.signer.calls == 0)
        let request = try expanded(), authorized = try f.authorize(request)
        let old = try f.authorize()
        #expect(authorized.requestSHA256 != old.requestSHA256)
        let signed = try JSONDecoder().decode(D.SignedDocument.self, from: authorized.document)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signed.signature)
        #expect(f.base.signer.key.publicKey.isValidSignature(signature, for: Q.domain + signed.payload))
        #expect(!f.base.signer.key.publicKey.isValidSignature(signature, for: D.domain + signed.payload))
        // The existing fixture deliberately returns the old profile; it cannot
        // certify the expanded selection even with the new request digest.
        let stale = try Q.canonical(f.response(authorized))
        #expect(throws: (any Error).self) {
            try A.experimentBody(response: stale, authorized: authorized, now: 1000, expectedVocabularySize: 512)
        }
        var response = try #require(JSONSerialization.jsonObject(with: stale) as? [String: Any])
        var binding = try #require(response["binding"] as? [String: Any])
        var profile = try #require(binding["profile"] as? [String: Any])
        profile["maximumPromptTokens"] = 2048; profile["maximumChunkTokens"] = 2048
        profile["maximumOutputTokens"] = 16; profile["maximumContextTokens"] = 2064
        binding["profile"] = profile; response["binding"] = binding
        let bytes = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        let body = try A.experimentBody(response: bytes, authorized: authorized, now: 1000, expectedVocabularySize: 512)
        #expect(body.authorization == request.authorization)
        #expect(body.authorization.requestID == f.request.authorization.requestID)
        #expect(body.selection.environment == f.request.selection.environment)
        #expect(body.selection.expiresUnixSeconds == f.request.selection.expiresUnixSeconds)
        #expect(body.selection.repository == f.request.selection.repository)
        #expect(body.selection.revision == f.request.selection.revision)
        #expect(body.selection.workspaceEvidence.isEmpty)
        #expect(body.binding.profile.maximumPromptTokens == 2048)
        #expect(body.binding.profile.maximumChunkTokens == 2048)
        #expect(body.binding.profile.maximumContextTokens == 2064)
        #expect(body.binding.executionPlanSHA256 == f.base.body.binding.executionPlanSHA256)
        let final = try f.base.authorize(body)
        let document = try JSONDecoder().decode(D.SignedDocument.self, from: final.document)
        let decoded = try JSONDecoder().decode(D.Body.self, from: document.payload)
        #expect(decoded.binding == body.binding && decoded.authorization == body.authorization)
        #expect(throws: (any Error).self) {
            try A.experimentBody(response: bytes, authorized: old, now: 1000, expectedVocabularySize: 512)
        }
        #expect(throws: (any Error).self) {
            try A.experimentBody(response: bytes, authorized: authorized, now: 1100, expectedVocabularySize: 512)
        }
        #expect(throws: (any Error).self) {
            try A.experimentBody(response: bytes, authorized: authorized, now: 1000, expectedVocabularySize: 511)
        }
    }

}
