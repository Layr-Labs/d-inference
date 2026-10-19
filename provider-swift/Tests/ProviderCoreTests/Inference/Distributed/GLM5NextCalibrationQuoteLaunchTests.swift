import CryptoKit
import Darwin
import Foundation
import Testing
import DarkbloomClusterProtocol
@testable import ProviderCore

@Suite struct GLM5NextCalibrationQuoteLaunchTests {
    @Test func preparedQuoteRetainsFileAndSelectionChecks() throws {
        typealias Q = GLM5NextCalibrationQuoteDocument
        typealias A = GLM5NextCalibrationQuoteAuthorizer
        let f = try GLM5NextCalibrationQuoteAuthorizerTests.Fixture()
        var path = [CChar](repeating: 0, count: Int(PATH_MAX))
        try #require(realpath(NSTemporaryDirectory(), &path) != nil)
        let root = URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("darkbloom")
        let worker = root.appendingPathComponent("darkbloom-cluster-worker")
        let metallib = root.appendingPathComponent("mlx.metallib")
        let model = root.appendingPathComponent("model")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        func file(_ url: URL, text: String, mode: Int) throws -> String {
            let bytes = Data(text.utf8); try bytes.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
        let appHash = try file(app, text: "app fixture", mode: 0o700)
        let workerHash = try file(worker, text: "worker fixture", mode: 0o700)
        let metalHash = try file(metallib, text: "metallib fixture", mode: 0o600)
        let environment = [GLM5NextCalibrationLaunch.appIdentityVariable: appHash,
            GLM5NextCalibrationLaunch.peerIdentityVariable: f.request.peerIdentitySHA256,
            "JACCL_RANK": "0", "JACCL_IBV_DEVICES": root.appendingPathComponent("matrix.json").path,
            "JACCL_COORDINATOR": "127.0.0.1:5000"]
        var object = try #require(JSONSerialization.jsonObject(with: Q.canonical(f.request)) as? [String: Any])
        object["appSHA256"] = appHash
        var selection = try #require(object["selection"] as? [String: Any])
        var expected = try #require(selection["environment"] as? [String: Any])
        expected["binarySHA256"] = workerHash; expected["metallibSHA256"] = metalHash
        expected["variableSHA256"] = environment.filter {
            $0.key.hasPrefix("MLX_") || $0.key.hasPrefix("DARKBLOOM_")
        }.mapValues(GLM5NextCalibrationLaunch.digest)
        selection["environment"] = expected; object["selection"] = selection
        let request = try JSONDecoder().decode(Q.Request.self, from: JSONSerialization.data(withJSONObject: object))
        let id = f.base.identity
        let identity = ClusterWorkerIdentity(membershipEpoch: id.membershipEpoch, modelID: id.modelID,
            artifactSHA256: id.artifactSHA256, configurationSHA256: id.configurationSHA256,
            peers: [.init(id: id.peers[0].id, buildSHA256: workerHash), id.peers[1]])
        let authorized = try A.authorize(request, identity: identity, rank: 0, now: 1000,
            memberIdentity: f.base.signer.key.publicKey.x963Representation,
            peerIdentity: f.base.peer.publicKey.x963Representation, appSHA256: appHash,
            signer: f.base.signer, verifySelection: {})
        let document = try A.write(authorized, directory: root, now: 1000)
        #expect(document.lastPathComponent.hasPrefix("glm-calibration-quote-"))
        #expect((try FileManager.default.attributesOfItem(atPath: document.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        var current = true
        let now = DispatchTime.now().uptimeNanoseconds, deadline = now + 10_000_000_000
        let prepared = try GLM5NextCalibrationQuoteLaunch.prepare(authorized: authorized,
            document: document, installedApp: app, worker: worker, metallib: metallib,
            modelDirectory: model, environment: environment, deadline: deadline, nowUptime: now, nowUnix: 1000,
            requireCurrentSelection: { guard current else { throw GLM5NextCalibrationDocument.invalid("Selection changed") } })
        let launch = prepared.launch
        #expect(launch.arguments.first == "--glm-calibration-quote")
        #expect(launch.arguments.count == 11)
        #expect(launch.environment == environment)
        #expect(launch.initialInput == authorized.credentialInput)
        try prepared.requireUnchanged()
        if let output = ProcessInfo.processInfo.environment["DARKBLOOM_CALIBRATION_QUOTE_LAUNCH_FIXTURE"] {
            let exported: [String: Any] = ["document": authorized.document.base64EncodedString(),
                "memberPublicKey": f.base.signer.key.publicKey.x963Representation.base64EncodedString(),
                "peerPublicKey": f.base.peer.publicKey.x963Representation.base64EncodedString(),
                "epoch": request.selection.epoch.uuidString.lowercased(), "rank": 0, "now": 1000,
                "arguments": launch.arguments, "environment": launch.environment, "nowUptime": now]
            try JSONSerialization.data(withJSONObject: exported, options: [.sortedKeys]).write(to: URL(fileURLWithPath: output))
        }
        current = false
        #expect(throws: (any Error).self) { try prepared.requireUnchanged() }
        current = true
        try Data("changed installed worker".utf8).write(to: worker)
        #expect(throws: (any Error).self) { try prepared.requireUnchanged() }
        #expect(throws: (any Error).self) { try A.write(authorized, directory: root, now: 1100) }
    }
}
