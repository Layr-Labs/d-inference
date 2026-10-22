import CryptoKit
import Foundation
import Testing
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
@testable import ProviderCore

/// UNRUN private draft. Real in-memory P-256 signatures and an owner-private
/// two-member store; synthetic model metadata is not a native qualification.
@Suite struct GLM5NextCalibrationNativeDocumentsTests {
    typealias D = GLM5NextCalibrationDocument
    typealias N = GLM5NextCalibrationNativeDocuments
    typealias Signer = GLM5NextCalibrationAuthorizerTests.Signer

    final class Fixture {
        let f: GLM5NextCalibrationInstalledPairTests.Fixture
        let pair: GLM5NextCalibrationInstalledPair
        let identity: ClusterWorkerIdentity
        let rank: Int
        let signers: [Signer]
        let bodies: [D.Body]
        let documents: [Data]
        init() throws {
            let f = try GLM5NextCalibrationInstalledPairTests.Fixture()
            let pair = try GLM5NextCalibrationInstalledPair.load(clusterID: f.clusterID, peerPin: f.peerPin, store: f.store, loadSigner: { f.local })
            let ordered = [f.local, f.peer].sorted {
                ClusterMemberPin.of(uncompressedKey: $0.key.publicKey.x963Representation)
                    < ClusterMemberPin.of(uncompressedKey: $1.key.publicKey.x963Representation)
            }
            let rank = ordered[0] === f.local ? 0 : 1
            let template = try GLM5NextCalibrationAuthorizerTests.Fixture()
            let identity = ClusterWorkerIdentity(membershipEpoch: template.identity.membershipEpoch, modelID: template.identity.modelID,
                artifactSHA256: template.identity.artifactSHA256, configurationSHA256: template.identity.configurationSHA256,
                peers: ordered.map { .init(id: ClusterSetupMemberFacts.memberID(pin:
                    ClusterMemberPin.of(uncompressedKey: $0.key.publicKey.x963Representation)),
                    buildSHA256: String(repeating: "a", count: 64)) })
            let bodies: [D.Body] = try (0...1).map { rank in
                var object = try Self.object(template.body)
                var p = object["selection"] as! [String: Any]; p["rank"] = rank
                var e = p["environment"] as! [String: Any]
                e["variableSHA256"] = [
                    GLM5NextCalibrationLaunch.appIdentityVariable: GLM5NextCalibrationLaunch.digest(String(repeating: "a", count: 64)),
                    GLM5NextCalibrationLaunch.peerIdentityVariable: GLM5NextCalibrationLaunch.digest(
                        GLM5NextCalibrationLaunch.peerFingerprint(ordered[1 - rank].key.publicKey.x963Representation)),
                    "MLX_ENABLE_TF32": GLM5NextCalibrationLaunch.digest("0")]
                p["environment"] = e; object["selection"] = p
                return try JSONDecoder().decode(D.Body.self, from: Self.json(object))
            }
            let documents: [Data] = try (0...1).map { rank in
                try GLM5NextCalibrationAuthorizer.authorize(bodies[rank], identity: identity, rank: rank,
                    now: 1000, expectedVocabularySize: 512,
                    memberIdentity: ordered[rank].key.publicKey.x963Representation,
                    peerIdentity: ordered[1 - rank].key.publicKey.x963Representation,
                    appSHA256: String(repeating: "a", count: 64), signer: ordered[rank], verifySelection: {}).document
            }
            self.f = f; self.pair = pair; self.identity = identity; self.rank = rank
            self.signers = ordered; self.bodies = bodies; self.documents = documents
        }
        deinit { try? FileManager.default.removeItem(at: f.root) }
        func common(_ docs: [Data]? = nil, identity override: ClusterWorkerIdentity? = nil,
                    rank overrideRank: Int? = nil, now: Int64 = 1000) throws -> ClusterNativeAuthorizationCommon {
            try N.common(documents: docs ?? documents, identity: override ?? identity, pair: pair,
                localRank: overrideRank ?? rank, expectedVocabularySize: 512, now: now)
        }
        func changed(rank: Int, path: [String], value: Any) throws -> Data {
            var object = try Self.object(bodies[rank]); Self.set(&object, path: path, value: value)
            let payload = try Self.json(object)
            return try GLM5NextCalibrationQuoteDocument.canonical(D.SignedDocument(payload: payload,
                signature: signers[rank].key.signature(for: D.domain + payload).rawRepresentation))
        }
        static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: GLM5NextCalibrationQuoteDocument.canonical(value)) as! [String: Any]
        }
        static func json(_ object: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        static func set(_ object: inout [String: Any], path: [String], value: Any) {
            if path.count == 1 { object[path[0]] = value; return }
            var child = object[path[0]] as! [String: Any]
            set(&child, path: Array(path.dropFirst()), value: value); object[path[0]] = child
        }
    }

    @Test func commonCommitsExactSignedDocumentsAndActualRosterAndBinding() throws {
        let f = try Fixture(), common = try f.common()
        guard case .finiteCalibrationV1(let finite) = common.permission else { Issue.record("wrong purpose"); return }
        #expect(finite.rank0AuthorizationSHA256 == Data(SHA256.hash(data: f.documents[0])))
        #expect(finite.rank1AuthorizationSHA256 == Data(SHA256.hash(data: f.documents[1])))
        #expect(finite.requestID == f.bodies[0].authorization.requestID)
        #expect(finite.expiresUnixSeconds == 1100)
        #expect(common.schedule == .serial)
        #expect(common.artifactSHA256.map { String(format: "%02x", $0) }.joined() == f.identity.artifactSHA256)
        #expect(common.planSHA256 == Data(repeating: 0xee, count: 32))
        // Reverse owner retains the exact same countersigned public roster.
        // Uses a separate private store and its own actual pair loader/signer.
        let reverseRoot = f.f.root.appendingPathComponent("reverse")
        try FileManager.default.createDirectory(at: reverseRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var record = try Fixture.object(f.pair.record)
        let localPin = ClusterMemberPin.of(uncompressedKey: f.f.local.key.publicKey.x963Representation)
        record["peerPin"] = localPin; record["peerIdentityKey"] = f.f.local.key.publicKey.x963Representation.base64EncodedString()
        let store = ClusterPairingStore(directory: reverseRoot)
        var records: [String: Any] = ["schema": ClusterPairingRecords.schemaName,
            "localPin": f.f.peerPin, "localIdentityKey": f.f.peer.key.publicKey.x963Representation.base64EncodedString(),
            "pairings": [record]]
        try Fixture.json(records).write(to: store.recordsFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.recordsFile.path)
        let reverse = try GLM5NextCalibrationInstalledPair.load(clusterID: f.f.clusterID, peerPin: localPin,
            store: store, loadSigner: { f.f.peer })
        let independentlyDerived = try N.common(documents: f.documents, identity: f.identity, pair: reverse,
            localRank: 1 - f.rank, expectedVocabularySize: 512, now: 1000)
        #expect(common.canonicalBytes == independentlyDerived.canonicalBytes)
        // The same signed roster and documents under a DIFFERENT ceremony/edge
        // must not alias the common, even with unchanged member keys/generation.
        var link = record["link"] as! [String: Any]; link["linkEpoch"] = UUID().uuidString
        record["link"] = link; records["pairings"] = [record]
        try Fixture.json(records).write(to: store.recordsFile)
        let changedPair = try GLM5NextCalibrationInstalledPair.load(clusterID: f.f.clusterID, peerPin: localPin,
            store: store, loadSigner: { f.f.peer })
        let differentCeremony = try N.common(documents: f.documents, identity: f.identity, pair: changedPair,
            localRank: 1 - f.rank, expectedVocabularySize: 512, now: 1000)
        #expect(common.canonicalBytes != differentCeremony.canonicalBytes)
        // Neither helper invocation produces an Admission/Committed or launch authority.
    }

    @Test func wrongSignedBytesSignatureDomainRankAndPairCannotAdmit() throws {
        let f = try Fixture()
        var changed = f.documents
        changed[0].append(0x20)
        #expect(throws: (any Error).self) { try f.common(changed) }
        var signed = try JSONDecoder().decode(D.SignedDocument.self, from: f.documents[0])
        var signature = signed.signature; signature[0] ^= 1
        signed = .init(payload: signed.payload, signature: signature)
        changed = f.documents; changed[0] = try GLM5NextCalibrationQuoteDocument.canonical(signed)
        #expect(throws: (any Error).self) { try f.common(changed) }
        let original = try JSONDecoder().decode(D.SignedDocument.self, from: f.documents[0])
        changed[0] = try GLM5NextCalibrationQuoteDocument.canonical(D.SignedDocument(
            payload: original.payload + Data([0x20]), signature: original.signature))
        #expect(throws: (any Error).self) { try f.common(changed) }
        var envelope = try Fixture.object(original); envelope["unexpected"] = true
        changed[0] = try Fixture.json(envelope)
        #expect(throws: (any Error).self) { try f.common(changed) }
        let payload = try GLM5NextCalibrationQuoteDocument.canonical(f.bodies[0])
        changed[0] = try GLM5NextCalibrationQuoteDocument.canonical(D.SignedDocument(payload: payload,
            signature: f.signers[1].key.signature(for: D.domain + payload).rawRepresentation))
        #expect(throws: (any Error).self) { try f.common(changed) }
        for domain in [Data("darkbloom/glm-calibration-quote/v1\0".utf8), Data()] {
            changed[0] = try GLM5NextCalibrationQuoteDocument.canonical(D.SignedDocument(payload: payload,
                signature: f.signers[0].key.signature(for: domain + payload).rawRepresentation))
            #expect(throws: (any Error).self) { try f.common(changed) }
        }
        #expect(throws: (any Error).self) { try f.common(Array(f.documents.reversed())) }
        #expect(throws: (any Error).self) { try f.common(rank: 1 - f.rank) }
        try f.f.write() // Actual retained store changed, even if the old docs still verify.
        #expect(throws: (any Error).self) { try f.common() }
    }

    @Test func signedScopeAndPrecisionMutationsRefuseRatherThanAlias() throws {
        let f = try Fixture()
        let mutations: [([String], Any)] = [
            (["selection", "rank"], 1), (["selection", "epoch"], UUID().uuidString),
            (["selection", "expiresUnixSeconds"], 1099), (["selection", "cut"], 21),
            (["selection", "artifactSHA256"], String(repeating: "b", count: 64)),
            (["selection", "files", "config.json", "sha256"], String(repeating: "b", count: 64)),
            (["selection", "environment", "binarySHA256"], String(repeating: "b", count: 64)),
            (["selection", "environment", "variableSHA256", "MLX_ENABLE_TF32"], GLM5NextCalibrationLaunch.digest("1")),
            (["selection", "environment", "variableSHA256", GLM5NextCalibrationLaunch.peerIdentityVariable], String(repeating: "b", count: 64)),
            (["binding", "executionPlanSHA256"], String(repeating: "b", count: 64)),
            (["binding", "profile", "vocabularySize"], 513),
            (["binding", "profile", "id"], "different-profile"),
            (["binding", "profile", "maximumContextTokens"], 9),
            (["authorization", "requestID"], UUID().uuidString), (["authorization", "promptTokenIDs"], [2, 1]),
            (["authorization", "outputCount"], 1), (["authorization", "chunkSize"], 1),
            (["authorization", "nativeHardCapBytes"], 0), (["authorization", "hostBudgetBytes"], 0),
            (["authorization", "osHeadroomBytes"], 10000), (["authorization", "workspaceNativeAllowanceBytes"], 2001),
            (["authorization", "workspaceHostAllowanceBytes"], 1001), (["unexpected"], true)
        ]
        for (path, value) in mutations {
            var changed = f.documents; changed[0] = try f.changed(rank: 0, path: path, value: value)
            #expect(throws: (any Error).self, "admitted mutation \(path)") { try f.common(changed) }
        }
        #expect(throws: (any Error).self) { try f.common(now: 1100) }
        #expect(throws: (any Error).self) { try f.common(now: -1) }
        let wrongPeer = ClusterWorkerIdentity(membershipEpoch: f.identity.membershipEpoch, modelID: f.identity.modelID,
            artifactSHA256: f.identity.artifactSHA256, configurationSHA256: f.identity.configurationSHA256,
            peers: Array(f.identity.peers.reversed()))
        #expect(throws: (any Error).self) { try f.common(identity: wrongPeer) }
    }

    @Test func validRankLocalBoundsAndRuntimeFactsAreBoundNotForcedEqual() throws {
        let f = try Fixture(), original = try f.common()
        let mutations: [([String], Any)] = [
            (["authorization", "nativeHardCapBytes"], 2100), (["authorization", "hostBudgetBytes"], 1100),
            (["authorization", "osHeadroomBytes"], 1100), (["authorization", "workspaceNativeAllowanceBytes"], 101),
            (["authorization", "workspaceHostAllowanceBytes"], 101),
            (["selection", "hostAllocationQuantum"], 32), (["selection", "loadCapacityBytes"], 1100),
            (["selection", "requestCapacityBytes"], 501),
            (["selection", "environment", "metallibSHA256"], String(repeating: "b", count: 64)),
            (["selection", "environment", "deviceRegistryID"], 2)
        ]
        for (path, value) in mutations {
            var changed = f.documents; changed[1] = try f.changed(rank: 1, path: path, value: value)
            #expect(try f.common(changed).canonicalBytes != original.canonicalBytes,
                "unbound rank-local mutation \(path)")
        }
    }
}
