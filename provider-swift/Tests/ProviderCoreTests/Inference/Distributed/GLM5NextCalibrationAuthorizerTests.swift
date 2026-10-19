import CryptoKit
import Darwin
import Foundation
import Testing
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
@testable import ProviderCore

@Suite struct GLM5NextCalibrationAuthorizerTests {
    typealias D = GLM5NextCalibrationDocument
    final class Signer: AttestationSigner, @unchecked Sendable {
        let key: P256.Signing.PrivateKey
        init(key: P256.Signing.PrivateKey = .init()) { self.key = key }
        var calls = 0
        var publicKeyBase64: String { Data(key.publicKey.x963Representation.dropFirst()).base64EncodedString() }
        func sign(_ bytes: Data) throws -> Data { calls += 1; return try key.signature(for: bytes).derRepresentation }
    }
    struct Fixture {
        let signer = Signer()
        let peer = P256.Signing.PrivateKey()
        let body: D.Body
        let identity: ClusterWorkerIdentity
        init() throws {
            let epoch = UUID(), hash = String(repeating: "a", count: 64)
            let config = "949a3db19177feacc434abe791f0d73f24f34ad577334d8773ac5a0afbfd2e8b"
            let artifact = "3aae613ff188bb0f72e880774a84e4d8e9943ab20c929d8a302af9c57b97d5ac"
            identity = .init(membershipEpoch: epoch, modelID: D.modelID, artifactSHA256: artifact,
                configurationSHA256: config, peers: [.init(id: "one", buildSHA256: hash), .init(id: "two", buildSHA256: hash)])
            body = .init(selection: .init(version: 1, epoch: epoch, rank: 0, expiresUnixSeconds: 1100,
                repository: "EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp",
                revision: "8841c52a1e8400bd7d3e7e631c916a6c4e6757b0",
                files: ["config.json": .init(bytes: 10_023_646, sha256: config),
                    "model.safetensors.index.json": .init(bytes: 12_351_468,
                        sha256: "b6cdec53a012ec4a8b383d37224f5955d463ec244d80b43d24fac72aa4c07b47")],
                artifactSHA256: artifact, cut: 20, profileID: "cpu-contract-fixture",
                maximumPromptTokens: 4, maximumChunkTokens: 2, maximumOutputTokens: 2, maximumContextTokens: 8,
                policy: "serving_v1", storage: "nvfp4Hybrid", loadCapacityBytes: 1000,
                requestCapacityBytes: 500, hostAllocationQuantum: 16, hostAllocationOverhead: 0,
                environment: .init(binarySHA256: hash, metallibSHA256: hash, backend: "jaccl",
                    allocator: "disableFreedBufferCache", os: "fixture", deviceRegistryID: 1,
                    deviceName: "fixture", architecture: "fixture", maximumBufferBytes: 4096,
                    recommendedWorkingSetBytes: 4096, memoryBytes: 10000, variableSHA256: [GLM5NextCalibrationLaunch.appIdentityVariable: GLM5NextCalibrationLaunch.digest(hash), GLM5NextCalibrationLaunch.peerIdentityVariable: GLM5NextCalibrationLaunch.digest(GLM5NextCalibrationLaunch.peerFingerprint(peer.publicKey.x963Representation))]), workspaceEvidence: Data()),
                authorization: try .init(requestID: UUID(), nativeHardCapBytes: 2000, hostBudgetBytes: 1000,
                    osHeadroomBytes: 1000, workspaceNativeAllowanceBytes: 100, workspaceHostAllowanceBytes: 100,
                    promptTokenIDs: [1, 2], outputCount: 2, chunkSize: 2),
                // Synthetic wire claim for signing tests, never a native contract.
                binding: .init(profile: .init(id: "cpu-contract-fixture", vocabularySize: 512,
                    maximumPromptTokens: 4, maximumOutputTokens: 2, maximumChunkTokens: 2, maximumContextTokens: 8),
                    executionPlanSHA256: String(repeating: "e", count: 64)))
        }
        func authorize(_ override: D.Body? = nil, verify: () throws -> Void = {}) throws -> GLM5NextCalibrationAuthorizer.Authorized {
            try GLM5NextCalibrationAuthorizer.authorize(override ?? body, identity: identity, rank: 0, now: 1000, expectedVocabularySize: 512,
                memberIdentity: signer.key.publicKey.x963Representation, peerIdentity: peer.publicKey.x963Representation, appSHA256: String(repeating: "a", count: 64),
                signer: signer, verifySelection: verify)
        }
    }

    @Test func exactDomainAndCredentialUseSameMember() throws {
        let f = try Fixture(), result = try f.authorize()
        let signed = try JSONDecoder().decode(D.SignedDocument.self, from: result.document)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signed.signature)
        #expect(f.signer.key.publicKey.isValidSignature(signature, for: D.domain + signed.payload))
        #expect(!f.signer.key.publicKey.isValidSignature(signature,
            for: Data("darkbloom/glm-worker-qualification/v1\0".utf8) + signed.payload))
        #expect(!f.peer.publicKey.isValidSignature(signature, for: D.domain + signed.payload))
        var changed = signed.payload; changed.append(32)
        #expect(!f.signer.key.publicKey.isValidSignature(signature, for: D.domain + changed))
        let wire = try ClusterWorkerCodec.decodeDataPlaneTrust(result.credentialInput)
        #expect(wire.memberIdentity == f.signer.key.publicKey.x963Representation)
        #expect(wire.peerPin == f.peer.publicKey.x963Representation)
        _ = try ClusterDataPlaneCredential(epoch: wire.membershipEpoch, rank: wire.rank,
            workerSigningKey: wire.workerSigningKey, workerCertificate: wire.workerCertificate,
            memberIdentity: wire.memberIdentity, peerPin: wire.peerPin)
        #expect(f.signer.calls == 2)
    }

    @Test func scopeRefusedBeforeSigner() throws {
        let f = try Fixture()
        let changes: [(String, String, Any)] = [
            ("selection", "rank", 1), ("selection", "epoch", UUID().uuidString),
            ("selection", "expiresUnixSeconds", 1000), ("selection", "expiresUnixSeconds", 4601),
            ("selection", "maximumPromptTokens", 2049), ("selection", "maximumOutputTokens", 17),
            ("selection", "repository", "EigenLabs/GLM-5.3-Flash-MLX-4bit-mtp"),
            ("selection", "loadCapacityBytes", 4000), ("selection", "workspaceEvidence", "YQ=="),
            ("authorization", "nativeHardCapBytes", Int.max), ("authorization", "hostBudgetBytes", 0)
        ]
        for (section, key, value) in changes {
            var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(f.body)) as? [String: Any])
            var object = try #require(json[section] as? [String: Any]); object[key] = value; json[section] = object
            let changed = try JSONDecoder().decode(D.Body.self, from: JSONSerialization.data(withJSONObject: json))
            #expect(throws: (any Error).self) { try f.authorize(changed) }
        }
        #expect(f.signer.calls == 0)
    }

    @Test func selectionFailureAndCrossedMemberNeverSign() throws {
        let f = try Fixture()
        #expect(throws: (any Error).self) {
            try f.authorize(verify: { throw D.invalid("Custody refused") })
        }
        #expect(throws: (any Error).self) {
            try GLM5NextCalibrationAuthorizer.authorize(f.body, identity: f.identity, rank: 0, now: 1000, expectedVocabularySize: 512,
                memberIdentity: f.peer.publicKey.x963Representation, peerIdentity: f.signer.key.publicKey.x963Representation, appSHA256: String(repeating: "a", count: 64),
                signer: f.signer, verifySelection: {})
        }
        #expect(f.signer.calls == 0)
    }

    @Test func crossedPeerMustNotBeAuthorized() throws {
        let f = try Fixture(), other = P256.Signing.PrivateKey()
        #expect(throws: (any Error).self) {
            try GLM5NextCalibrationAuthorizer.authorize(f.body, identity: f.identity, rank: 0, now: 1000, expectedVocabularySize: 512,
                memberIdentity: f.signer.key.publicKey.x963Representation, peerIdentity: other.publicKey.x963Representation,
                appSHA256: String(repeating: "a", count: 64), signer: f.signer, verifySelection: {})
        }
        #expect(f.signer.calls == 0)
    }

    @Test func privateDocumentExpiryAndDirectoryRefusal() throws {
        let f = try Fixture(), result = try f.authorize()
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        try #require(realpath(NSTemporaryDirectory(), &buffer) != nil)
        let directory = URL(fileURLWithPath: String(cString: buffer)).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let canonical = directory
        #expect(throws: (any Error).self) { try GLM5NextCalibrationAuthorizer.write(result, directory: canonical, now: 1100) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: canonical.path).isEmpty)
        let url = try GLM5NextCalibrationAuthorizer.write(result, directory: canonical, now: 1000)
        #expect(try Data(contentsOf: url) == result.document)
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        let verified = try GLM5NextCalibrationLaunch.verifyDocument(url, authorized: result, deadline: deadline)
        try verified.requireUnchanged()
        try Data("changed".utf8).write(to: url)
        #expect(throws: (any Error).self) { try verified.requireUnchanged() }
        #expect(throws: (any Error).self) {
            try GLM5NextCalibrationLaunch.verifyDocument(url, authorized: result, deadline: deadline)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: canonical.path)
        #expect(throws: (any Error).self) { try GLM5NextCalibrationAuthorizer.write(result, directory: canonical, now: 1000) }
    }
    @Test func appAndEnvironmentChangesRefused() throws {
        let f = try Fixture()
        #expect(throws: (any Error).self) {
            try GLM5NextCalibrationAuthorizer.authorize(f.body, identity: f.identity, rank: 0, now: 1000, expectedVocabularySize: 512,
                memberIdentity: f.signer.key.publicKey.x963Representation, peerIdentity: f.peer.publicKey.x963Representation,
                appSHA256: String(repeating: "b", count: 64), signer: f.signer, verifySelection: {})
        }
        #expect(f.signer.calls == 0)
        let app = String(repeating: "a", count: 64)
        let environment = [GLM5NextCalibrationLaunch.appIdentityVariable: app,
            GLM5NextCalibrationLaunch.peerIdentityVariable: GLM5NextCalibrationLaunch.peerFingerprint(f.peer.publicKey.x963Representation),
            "JACCL_RANK": "0", "JACCL_IBV_DEVICES": "/fixture/matrix.json", "JACCL_COORDINATOR": "127.0.0.1:5000"]
        try GLM5NextCalibrationLaunch.requireEnvironment(environment, expected: f.body.selection.environment,
            appSHA256: app, rank: 0)
        for (key, value) in [("MLX_ENABLE_TF32", "1"), ("DYLD_INSERT_LIBRARIES", "/unexpected"),
                             ("JACCL_RANK", "1"), (GLM5NextCalibrationLaunch.appIdentityVariable, "changed")] {
            var changed = environment; changed[key] = value
            #expect(throws: (any Error).self) {
                try GLM5NextCalibrationLaunch.requireEnvironment(changed, expected: f.body.selection.environment,
                    appSHA256: app, rank: 0)
            }
        }
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(f.body)) as? [String: Any])
        var selection = try #require(json["selection"] as? [String: Any])
        var expected = try #require(selection["environment"] as? [String: Any])
        expected["binarySHA256"] = String(repeating: "b", count: 64)
        selection["environment"] = expected; json["selection"] = selection
        let changed = try JSONDecoder().decode(D.Body.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(throws: (any Error).self) { try f.authorize(changed) }
    }


    @Test func finite2048SigningPreservesBindingIdentityAndRejectsBoundsBeforeSigning() throws {
        let f = try Fixture()
        let original = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(f.body)) as? [String: Any])
        func expanded(prompt: Int = 2048, chunk: Int = 2048, output: Int = 16, context: Int = 2064) throws -> D.Body {
            var object = original, selection = try #require(original["selection"] as? [String: Any])
            var binding = try #require(original["binding"] as? [String: Any])
            var profile = try #require(binding["profile"] as? [String: Any])
            for (field, value) in [("maximumPromptTokens", prompt), ("maximumChunkTokens", chunk),
                ("maximumOutputTokens", output), ("maximumContextTokens", context)] {
                selection[field] = value; profile[field] = value
            }
            binding["profile"] = profile; object["binding"] = binding; object["selection"] = selection
            var authorization = try #require(original["authorization"] as? [String: Any])
            authorization["promptTokenIDs"] = Array(repeating: 1, count: prompt)
            authorization["chunkSize"] = chunk; authorization["outputCount"] = output
            object["authorization"] = authorization
            return try JSONDecoder().decode(D.Body.self, from: JSONSerialization.data(withJSONObject: object))
        }
        for (prompt, chunk, output, context) in [(2049, 2048, 16, 2064), (2048, 2049, 16, 2064),
            (2048, 2048, 17, 2064), (2048, 2048, 16, 2063), (2048, 2048, 16, 2065)] {
            #expect(throws: (any Error).self) {
                try f.authorize(expanded(prompt: prompt, chunk: chunk, output: output, context: context))
            }
        }
        let full = try expanded()
        let stale = D.Body(selection: full.selection, authorization: full.authorization, binding: f.body.binding)
        #expect(throws: (any Error).self) { try f.authorize(stale) }
        #expect(f.signer.calls == 0)
        let result = try f.authorize(full)
        let signed = try JSONDecoder().decode(D.SignedDocument.self, from: result.document)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signed.signature)
        #expect(f.signer.key.publicKey.isValidSignature(signature, for: D.domain + signed.payload))
        #expect(!f.signer.key.publicKey.isValidSignature(signature, for: GLM5NextCalibrationQuoteDocument.domain + signed.payload))
        let decoded = try JSONDecoder().decode(D.Body.self, from: signed.payload)
        #expect(decoded.authorization == full.authorization)
        #expect(decoded.authorization.requestID == f.body.authorization.requestID)
        #expect(decoded.authorization.nativeHardCapBytes == f.body.authorization.nativeHardCapBytes)
        #expect(decoded.selection.environment == f.body.selection.environment)
        #expect(decoded.selection.expiresUnixSeconds == f.body.selection.expiresUnixSeconds)
        #expect(decoded.binding == full.binding && decoded.binding != f.body.binding)
        #expect(decoded.binding.executionPlanSHA256 == f.body.binding.executionPlanSHA256)
        #expect(decoded.selection.workspaceEvidence.isEmpty)
        #expect(decoded.selection.maximumContextTokens == 2064)
        #expect(decoded.authorization.promptTokenIDs.count == 2048)
        // Increasing the allowed shape does not reauthorize a different binary.
        var changed = try #require(JSONSerialization.jsonObject(with: signed.payload) as? [String: Any])
        var selection = try #require(changed["selection"] as? [String: Any])
        var environment = try #require(selection["environment"] as? [String: Any])
        environment["binarySHA256"] = String(repeating: "f", count: 64)
        selection["environment"] = environment; changed["selection"] = selection
        let crossed = try JSONDecoder().decode(D.Body.self, from: JSONSerialization.data(withJSONObject: changed))
        #expect(throws: (any Error).self) { try f.authorize(crossed) }
        #expect(f.signer.calls == 2)
    }

}
