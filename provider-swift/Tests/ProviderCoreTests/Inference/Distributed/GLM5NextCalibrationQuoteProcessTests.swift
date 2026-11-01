import CryptoKit
import DarkbloomClusterProtocol
import Darwin
import Foundation
import Testing
import DarkbloomClusterProcess
@testable import ProviderCore

@Suite(.serialized) struct GLM5NextCalibrationQuoteProcessTests {
    final class Fixture {
        let root: URL
        let script: URL
        var children: [GLM5NextCalibrationQuoteProcess] = []
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            script = root.appendingPathComponent("child.py")
            try Data("""
            import os, sys, time, signal
            mode, root = sys.argv[1:]
            if mode == 'blocked':
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                while True: time.sleep(.01)
            credential = sys.stdin.buffer.readline()
            if credential != b'credential-fixture\\n' or os.environ.get('QUOTE_FIXTURE') != 'exact': sys.exit(8)
            if mode == 'stubborn': signal.signal(signal.SIGTERM, signal.SIG_IGN)
            os.write(1, b'{"quote":true}\\n')
            open(root + '/reported', 'w').close()
            if mode == 'nonzero': sys.exit(9)
            if mode == 'oversize': os.write(1, b'x' * 70000)
            if mode == 'trailing': os.write(1, b' ')
            if mode == 'second': os.write(1, b'{}\\n')
            if mode == 'stderr': os.write(2, b'x' * 70000)
            if mode == 'wait' or mode == 'stubborn' or mode == 'eof':
                if mode == 'eof': os.close(1); os.close(2)
                while not os.path.exists(root + '/release'): time.sleep(.01)
            """.utf8).write(to: script)
        }
        func start(_ mode: String, milliseconds: UInt64 = 2500,
                   preflight: @escaping () throws -> Void = {}) throws -> GLM5NextCalibrationQuoteProcess {
            let child = try GLM5NextCalibrationQuoteProcess(launch: .init(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: [script.path, mode, root.path], environment: ["QUOTE_FIXTURE": "exact"],
                initialInput: Data("credential-fixture\n".utf8)),
                deadline: DispatchTime.now().uptimeNanoseconds + milliseconds * 1_000_000, preflight: preflight)
            try child.start(); children.append(child); return child
        }
        func reported() throws {
            let end = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            while !FileManager.default.fileExists(atPath: root.appendingPathComponent("reported").path), DispatchTime.now().uptimeNanoseconds < end { usleep(5000) }
            try #require(FileManager.default.fileExists(atPath: root.appendingPathComponent("reported").path))
        }
        func release() throws { try Data().write(to: root.appendingPathComponent("release")) }
        func cleanup() {
            for child in children {
                child.cancel()
                #expect(child.waitUntilExited(deadline: DispatchTime.now().uptimeNanoseconds + 4_000_000_000))
            }
            try? FileManager.default.removeItem(at: root)
        }
    }
    @Test func successRequiresActualZeroExitAndExactInputEnvironment() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let child = try f.start("wait"); try f.reported()
        #expect(!child.observedExit)
        #expect(throws: (any Error).self) { try child.response() }
        #expect(!child.waitUntilExited(deadline: DispatchTime.now().uptimeNanoseconds + 20_000_000))
        try f.release()
        #expect(child.waitUntilExited(deadline: child.deadline))
        #expect(try child.response() == Data("{\"quote\":true}".utf8))
        child.cancel()
        #expect(try !child.response().isEmpty)
    }
    @Test(arguments: ["nonzero", "oversize", "trailing", "second", "stderr"])
    func invalidOutputAndNonzeroExitNeverReturnResponse(mode: String) throws {
        let f = try Fixture(); defer { f.cleanup() }
        let child = try f.start(mode)
        #expect(child.waitUntilExited(deadline: child.deadline + 2_000_000_000))
        #expect(throws: (any Error).self) { try child.response() }
        #expect(child.diagnosticTail.count <= 4096)
    }
    @Test func liveEOFIsNotExit() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let child = try f.start("eof"); try f.reported()
        #expect(!child.waitUntilExited(deadline: DispatchTime.now().uptimeNanoseconds + 50_000_000))
        #expect(throws: (any Error).self) { try child.response() }
        try f.release(); #expect(child.waitUntilExited(deadline: child.deadline))
        #expect(try !child.response().isEmpty)
    }
    @Test func cancellationRetiresStubbornChild() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let child = try f.start("stubborn"); try f.reported(); child.cancel()
        #expect(child.waitUntilExited(deadline: DispatchTime.now().uptimeNanoseconds + 3_000_000_000))
        #expect(throws: (any Error).self) { try child.response() }
    }
    @Test func blockedInputAndDeadlineRetireChild() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let child = try f.start("blocked", milliseconds: 300)
        #expect(child.waitUntilExited(deadline: child.deadline + 3_000_000_000))
        #expect(throws: (any Error).self) { try child.response() }
    }
    @Test func preflightFailureNeverSpawns() throws {
        let f = try Fixture(); defer { f.cleanup() }
        #expect(throws: (any Error).self) { try f.start("wait", preflight: { throw GLM5NextCalibrationQuoteProcess.Failure.invalidLaunch }) }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("reported").path))
    }
    @Test func preparedFenceRechecksSelectionAndFilesImmediatelyBeforeSpawn() throws {
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
        let selectionChild = try GLM5NextCalibrationQuoteProcess(prepared: prepared)
        current = false
        #expect(throws: (any Error).self) { try selectionChild.start() }
        #expect(!selectionChild.observedExit)
        current = true
        let fileChild = try GLM5NextCalibrationQuoteProcess(prepared: prepared)
        try Data("changed after preparation".utf8).write(to: worker)
        #expect(throws: (any Error).self) { try fileChild.start() }
        #expect(!fileChild.observedExit)
    }

    @Test func callerDropDoesNotAbandonLiveChild() throws {
        let f = try Fixture(); defer { f.cleanup() }
        var child: GLM5NextCalibrationQuoteProcess? = try f.start("wait")
        weak var observed = child
        try f.reported(); f.children.removeAll(); child = nil
        #expect(observed != nil)
        try f.release()
        let end = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while observed != nil, DispatchTime.now().uptimeNanoseconds < end { usleep(5000) }
        #expect(observed == nil)
    }
}
