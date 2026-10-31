import CryptoKit
import Darwin
import Foundation
import Testing
import DarkbloomClusterProcess
import DarkbloomClusterProtocol
import DarkbloomClusterRemote
@testable import ProviderCore

/// Uses actual authorization, safe-file verification and launch preparation.
/// Tiny executable fixtures are hashed but never executed or loaded by MLX.
@Suite struct GLM5NextCalibrationLaunchTests {
    typealias D = GLM5NextCalibrationDocument
    final class Fixture {
        let authorizationFixture: GLM5NextCalibrationAuthorizerTests.Fixture
        let root: URL
        let app: URL, worker: URL, metallib: URL, model: URL
        let appSHA256: String
        let body: D.Body
        let identity: ClusterWorkerIdentity
        let environment: [String: String]
        let now = DispatchTime.now().uptimeNanoseconds
        let attachment: ClusterOwnerBootstrapAttachment
        let binding: ClusterOwnerBinding
        var deadline: UInt64 { now + 10_000_000_000 }

        init() throws {
            let f = try GLM5NextCalibrationAuthorizerTests.Fixture()
            authorizationFixture = f
            var canonical = [CChar](repeating: 0, count: Int(PATH_MAX))
            try #require(realpath(NSTemporaryDirectory(), &canonical) != nil)
            root = URL(fileURLWithPath: String(cString: canonical))
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            app = root.appendingPathComponent("darkbloom")
            worker = root.appendingPathComponent("darkbloom-cluster-worker")
            metallib = root.appendingPathComponent("mlx.metallib")
            model = root.appendingPathComponent("model", isDirectory: true)
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            func write(_ url: URL, mode: Int) throws -> String {
                let bytes = Data(("synthetic " + url.lastPathComponent).utf8)
                try bytes.write(to: url, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
                return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            }
            appSHA256 = try write(app, mode: 0o700)
            let workerHash = try write(worker, mode: 0o700)
            let metalHash = try write(metallib, mode: 0o600)
            environment = [GLM5NextCalibrationLaunch.appIdentityVariable: appSHA256,
                GLM5NextCalibrationLaunch.peerIdentityVariable:
                    GLM5NextCalibrationLaunch.peerFingerprint(f.peer.publicKey.x963Representation),
                "JACCL_RANK": "0", "JACCL_IBV_DEVICES": root.appendingPathComponent("matrix.json").path,
                "JACCL_COORDINATOR": "127.0.0.1:5000"]
            var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(f.body)) as? [String: Any])
            var selection = try #require(json["selection"] as? [String: Any])
            var expected = try #require(selection["environment"] as? [String: Any])
            expected["binarySHA256"] = workerHash
            expected["metallibSHA256"] = metalHash
            expected["variableSHA256"] = environment.filter {
                $0.key.hasPrefix("MLX_") || $0.key.hasPrefix("DARKBLOOM_")
            }.mapValues(GLM5NextCalibrationLaunch.digest)
            selection["environment"] = expected; json["selection"] = selection
            body = try JSONDecoder().decode(D.Body.self, from: JSONSerialization.data(withJSONObject: json))
            identity = .init(membershipEpoch: f.identity.membershipEpoch, modelID: f.identity.modelID,
                artifactSHA256: f.identity.artifactSHA256, configurationSHA256: f.identity.configurationSHA256,
                peers: [.init(id: "one", buildSHA256: workerHash), .init(id: "two", buildSHA256: workerHash)])
            let p = body.selection
            binding = try .init(clusterID: "calibration-launch-fixture", ownerIncarnation: UUID(), leaseID: UUID(),
                identity: identity, profile: .init(id: p.profileID, vocabularySize: 512,
                    maximumPromptTokens: p.maximumPromptTokens, maximumOutputTokens: p.maximumOutputTokens,
                    maximumChunkTokens: p.maximumChunkTokens, maximumContextTokens: p.maximumContextTokens),
                rank: 0, executionPlanSHA256: String(repeating: "e", count: 64))
            attachment = try .calibration(profile: .mesh2, deadline: now + 10_000_000_000)
        }
        deinit {
            attachment.cancelCalibration()
            try? FileManager.default.removeItem(at: root)
        }
        func authorize() throws -> GLM5NextCalibrationAuthorizer.Authorized {
            let f = authorizationFixture
            return try GLM5NextCalibrationAuthorizer.authorize(body, identity: identity, rank: 0, now: 1000, expectedVocabularySize: 512,
                memberIdentity: f.signer.key.publicKey.x963Representation, peerIdentity: f.peer.publicKey.x963Representation,
                appSHA256: appSHA256, signer: f.signer, verifySelection: {})
        }
        func prepare(_ authorized: GLM5NextCalibrationAuthorizer.Authorized, document: URL,
                     bindingOverride: ClusterOwnerBinding? = nil,
                     verify: () throws -> Void) throws -> ClusterWorkerLaunch {
            try GLM5NextCalibrationLaunch.prepare(authorized: authorized, binding: bindingOverride ?? binding, document: document,
                installedApp: app, appSHA256: appSHA256, worker: worker, metallib: metallib,
                modelDirectory: model, environment: environment, attachment: attachment,
                leaseDeadline: deadline, experimentDeadline: deadline, nowUptime: now, nowUnix: 1000,
                requireCurrentSelection: verify)
        }
    }

    @Test func preparedLaunchUsesExactDocumentEnvironmentAndCredential() throws {
        let f = try Fixture(), authorized = try f.authorize()
        let document = try GLM5NextCalibrationAuthorizer.write(authorized, directory: f.root, now: 1000)
        var selectionChecks = 0
        let launch = try f.prepare(authorized, document: document) { selectionChecks += 1 }
        #expect(selectionChecks == 1)
        #expect(launch.executable == f.worker)
        #expect(launch.arguments.first == "--glm-calibrate")
        #expect(launch.environment == f.environment)
        #expect(launch.initialInput == authorized.credentialInput)
        let trust = try ClusterWorkerCodec.decodeDataPlaneTrust(#require(launch.initialInput))
        #expect(trust.membershipEpoch == f.identity.membershipEpoch && trust.rank == f.binding.rank)
        #expect(!launch.arguments.contains(trust.workerSigningKey.base64EncodedString()))
        #expect(!launch.environment.values.contains(trust.workerSigningKey.base64EncodedString()))
        // Export only public contract fields. The synthetic private worker key
        // stays in memory, exactly as it does in the actual launch specification.
        if let path = ProcessInfo.processInfo.environment["DARKBLOOM_CALIBRATION_CONTRACT_FIXTURE"] {
            let fixture: [String: Any] = ["document": authorized.document.base64EncodedString(),
                "memberPublicKey": trust.memberIdentity.base64EncodedString(),
                "entryArguments": launch.arguments, "arguments": Array(launch.arguments.dropFirst()),
                "environment": launch.environment, "nowUptime": f.now]
            try JSONSerialization.data(withJSONObject: fixture, options: .sortedKeys)
                .write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        }
    }

    @Test func preparationRefusesChangedSelectionAndInstalledBytes() throws {
        let f = try Fixture(), authorized = try f.authorize()
        let document = try GLM5NextCalibrationAuthorizer.write(authorized, directory: f.root, now: 1000)
        #expect(throws: (any Error).self) {
            try f.prepare(authorized, document: document) { throw D.invalid("Selection changed") }
        }
        for file in [f.app, f.worker, f.metallib, document] {
            let original = try Data(contentsOf: file)
            try Data("changed".utf8).write(to: file)
            #expect(throws: (any Error).self) { try f.prepare(authorized, document: document, verify: {}) }
            try original.write(to: file)
        }
        _ = try f.prepare(authorized, document: document, verify: {})
        let link = f.root.appendingPathComponent("document-link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: document)
        #expect(throws: (any Error).self) { try f.prepare(authorized, document: link, verify: {}) }
        let traversal = URL(fileURLWithPath: f.root.path + "/model/../" + document.lastPathComponent)
        #expect(throws: (any Error).self) { try f.prepare(authorized, document: traversal, verify: {}) }
    }
    @Test func ownerBindingMustMatchTheSignedMetadataBindingBeforeLaunch() throws {
        let f = try Fixture(), authorized = try f.authorize()
        let document = try GLM5NextCalibrationAuthorizer.write(authorized, directory: f.root, now: 1000)
        let original = f.binding
        for changeProfile in [false, true] {
            let profile = original.profile
            let changed = try ClusterOwnerBinding(clusterID: original.route.clusterID,
                ownerIncarnation: original.route.ownerIncarnation, leaseID: original.route.leaseID,
                identity: original.identity,
                profile: .init(id: profile.id, vocabularySize: profile.vocabularySize + (changeProfile ? 1 : 0),
                    maximumPromptTokens: profile.maximumPromptTokens, maximumOutputTokens: profile.maximumOutputTokens,
                    maximumChunkTokens: profile.maximumChunkTokens, maximumContextTokens: profile.maximumContextTokens),
                rank: original.rank, executionPlanSHA256: changeProfile ? original.executionPlanSHA256 : String(repeating: "f", count: 64))
            var reachedCustody = false
            #expect(throws: (any Error).self) {
                try f.prepare(authorized, document: document, bindingOverride: changed) { reachedCustody = true }
            }
            #expect(!reachedCustody)
        }
    }

}
