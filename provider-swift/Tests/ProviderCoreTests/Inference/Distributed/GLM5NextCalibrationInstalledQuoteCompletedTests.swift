import CryptoKit
import Darwin
import Foundation
import Testing
import DarkbloomClusterProtocol
@_spi(OwnerService) import DarkbloomClusterRemote
@testable import ProviderCore

/// Actual task-private child/pair/filesystem lifecycle tests. The child emits a
/// schema fixture, NOT an actual GLM plan or model/payload qualification receipt.
/// Pinned config/index bytes are copied from the parent's existing metadata
/// directory solely to exercise the real installed pin/vocabulary checks.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_GLM_METADATA_INPUT"] != nil
    || ProcessInfo.processInfo.environment["DARKBLOOM_GLM_METADATA_BINDING_REQUIRED"] == "1"))
struct GLM5NextCalibrationInstalledQuoteCompletedTests {
    typealias C = GLM5NextCalibrationInstalledQuote
    typealias Q = GLM5NextCalibrationQuoteDocument

    final class Fixture {
        let pairing: GLM5NextCalibrationInstalledPairTests.Fixture
        let app: URL, worker: URL, metallib: URL, model: URL, input: URL, device: URL
        let vocabulary: Int
        let requestID: UUID
        let timeout: UInt64 = 5_000_000_000

        init(mode: String = "normal") throws {
            let metadataInput = try #require(ProcessInfo.processInfo.environment["DARKBLOOM_GLM_METADATA_INPUT"])
            let fixture = try GLM5NextCalibrationQuoteAuthorizerTests.Fixture()
            pairing = try .init()
            requestID = fixture.request.authorization.requestID
            let pairingRoot = pairing.root
            do {
                // Foundation may keep /var even after resolvingSymlinksInPath().
                // Preserve C realpath spelling for the unchanged no-follow guards.
                let pairingRootPath = pairingRoot.path
                var canonicalRoot = [CChar](repeating: 0, count: Int(PATH_MAX))
                try #require(realpath(pairingRootPath, &canonicalRoot) != nil)
                let root = URL(fileURLWithPath: String(cString: canonicalRoot), isDirectory: true)
                let manager = FileManager.default
                app = root.appendingPathComponent(BuildEnvironment.current.appBundleName)
                    .appendingPathComponent("Contents/MacOS").appendingPathComponent(BuildEnvironment.current.cliName)
                worker = app.deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("Helpers/darkbloom-cluster-worker")
                metallib = worker.deletingLastPathComponent().appendingPathComponent("mlx.metallib")
                model = root.appendingPathComponent("model")
                input = root.appendingPathComponent("input.json")
                device = root.appendingPathComponent("device")
                for directory in [app.deletingLastPathComponent(), worker.deletingLastPathComponent(), model, device] {
                    try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700])
                }
                // This fixture selector contains public metadata paths, no keys.
                let metadata = try #require(JSONSerialization.jsonObject(
                    with: Data(contentsOf: URL(fileURLWithPath: metadataInput))) as? [String: Any])
                let source = URL(fileURLWithPath: try #require(metadata["modelDirectory"] as? String))
                for name in ["config.json", "model.safetensors.index.json"] {
                    let destination = model.appendingPathComponent(name)
                    try manager.copyItem(at: source.appendingPathComponent(name), to: destination)
                    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                }
                let config = try Data(contentsOf: model.appendingPathComponent("config.json"))
                vocabulary = try GLM5NextCalibrationBinding.configurationVocabulary(config,
                    expectedSHA256: "949a3db19177feacc434abe791f0d73f24f34ad577334d8773ac5a0afbfd2e8b")
                try Data("installed CLI fixture".utf8).write(to: app)
                try Data("AOT fixture bytes; no GPU".utf8).write(to: metallib)
                // Consumes the actual signed request and actual stdin credential,
                // returns bounded JSON, and optionally reports before delayed exit.
                try Data("""
                #!/usr/bin/python3
                import base64, hashlib, json, os, sys, time, uuid
                args = sys.argv[1:]
                request_path = args[args.index('--request') + 1]
                directory = args[args.index('--model-dir') + 1]
                deadline = args[args.index('--deadline-uptime-nanoseconds') + 1]
                envelope = json.load(open(request_path))
                payload = base64.b64decode(envelope['payload'])
                request = json.loads(payload)
                selection = request['selection']
                if not sys.stdin.buffer.readline(): sys.exit(7)
                mode = os.environ['DARKBLOOM_QUOTE_COMPLETED_TEST_MODE']
                with open(directory + '/quote-deadline', 'w') as handle: handle.write(deadline)
                vocabulary = json.load(open(directory + '/config.json'))['text_config']['vocab_size']
                binding = {'profile': {'id': selection['profileID'], 'vocabularySize': vocabulary,
                    'maximumPromptTokens': selection['maximumPromptTokens'],
                    'maximumOutputTokens': selection['maximumOutputTokens'],
                    'maximumChunkTokens': selection['maximumChunkTokens'],
                    'maximumContextTokens': selection['maximumContextTokens']},
                    'executionPlanSHA256': 'e' * 64}
                if mode == 'wrongVocabulary': binding['profile']['vocabularySize'] += 1
                if mode == 'unknownBinding': binding['unexpected'] = True
                response = {'version': 1, 'purpose': 'calibrationQuotation',
                    'quoteRequestID': str(uuid.uuid4()) if mode == 'wrongRequest' else request['quoteRequestID'],
                    'quoteRequestSHA256': hashlib.sha256(payload).hexdigest(),
                    'rank': selection['rank'], 'cut': selection['cut'],
                    'repository': selection['repository'], 'revision': selection['revision'],
                    'artifactSHA256': selection['artifactSHA256'],
                    'rawConfigurationFileSHA256': selection['files']['config.json']['sha256'],
                    'normalizedConfigurationSHA256': 'b' * 64, 'descriptorSHA256': 'c' * 64,
                    'inventorySHA256': 'd' * 64, 'numericalPolicySHA256': 'e' * 64,
                    'executionEnvironmentSHA256': hashlib.sha256(json.dumps(selection['environment'],
                        sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest(),
                    'nativeBytes': 1400, 'hostBytes': 500, 'loadCapacityBytes': 1900,
                    'requestCapacityBytes': 1000, 'qualifiesMaximumEnvelope': False,
                    'payloadVerified': False, 'binding': binding}
                os.write(1, json.dumps(response, sort_keys=True, separators=(',', ':')).encode() + b'\\n')
                if mode == 'delayed': time.sleep(.25)
                with open(directory + '/finished', 'w') as handle: handle.write('fixture child finishing')
                if mode == 'nonzero': sys.exit(9)
                """.utf8).write(to: worker)
                for executable in [app, worker] {
                    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
                }
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metallib.path)
                var object = try #require(JSONSerialization.jsonObject(with: Q.canonical(fixture.request)) as? [String: Any])
                let localPin = ClusterMemberPin.of(uncompressedKey: pairing.local.key.publicKey.x963Representation)
                let rank = try #require([localPin, pairing.peerPin].sorted().firstIndex(of: localPin))
                let appSHA = try Self.hash(app)
                let peerSHA = GLM5NextCalibrationLaunch.peerFingerprint(pairing.peer.key.publicKey.x963Representation)
                let environment = [GLM5NextCalibrationLaunch.appIdentityVariable: appSHA,
                    GLM5NextCalibrationLaunch.peerIdentityVariable: peerSHA,
                    "DARKBLOOM_QUOTE_COMPLETED_TEST_MODE": mode, "JACCL_RANK": String(rank),
                    "JACCL_IBV_DEVICES": root.appendingPathComponent("matrix.json").path,
                    "JACCL_COORDINATOR": "127.0.0.1:5000"]
                object["appSHA256"] = appSHA; object["peerIdentitySHA256"] = peerSHA
                var selection = try #require(object["selection"] as? [String: Any])
                selection["rank"] = rank
                selection["expiresUnixSeconds"] = Int64(Date().timeIntervalSince1970) + 1200
                var facts = try #require(selection["environment"] as? [String: Any])
                facts["binarySHA256"] = try Self.hash(worker); facts["metallibSHA256"] = try Self.hash(metallib)
                facts["variableSHA256"] = environment.filter {
                    $0.key.hasPrefix("MLX_") || $0.key.hasPrefix("DARKBLOOM_")
                }.mapValues(GLM5NextCalibrationLaunch.digest)
                selection["environment"] = facts; object["selection"] = selection
                let request = try JSONDecoder().decode(Q.Request.self, from: JSONSerialization.data(withJSONObject: object))
                let inputValue = C.Input(schema: "darkbloom_glm_calibration_quote_input_v1", clusterID: pairing.clusterID,
                    peerPin: pairing.peerPin, peerBinarySHA256: String(repeating: "a", count: 64),
                    request: request, modelDirectory: model.path, environment: environment)
                try Q.canonical(inputValue).write(to: input)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
            } catch {
                try? FileManager.default.removeItem(at: pairingRoot)
                throw error
            }
        }
        deinit { try? FileManager.default.removeItem(at: pairing.root) }
        static func hash(_ url: URL) throws -> String {
            SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        func complete() throws -> C.Completed {
            try C.complete(input: input, installedExecutable: app, deviceDirectory: device,
                quoteTimeoutNanoseconds: timeout, loadPair: { cluster, pin in
                    try GLM5NextCalibrationInstalledPair.load(clusterID: cluster, peerPin: pin,
                        store: self.pairing.store, loadSigner: { self.pairing.local })
                })
        }
        func requireFreshDeviceLease() throws {
            let lease = try ClusterDeviceLease(directoryURL: device)
            try lease.record(clusterID: pairing.clusterID, peerID: "finite-owner-fixture", rank: 0,
                membershipEpoch: UUID(), leaseID: UUID(), ownerIncarnation: UUID(), nativeLaunchID: UUID())
            try lease.resolve()
        }
    }

    @Test func completedRequiresActualExitAndKeepsEvidenceWithoutMetadataLease() throws {
        let f = try Fixture(mode: "delayed")
        let completed = try f.complete()
        #expect(FileManager.default.fileExists(atPath: f.model.appendingPathComponent("finished").path))
        #expect(completed.authorized.request.authorization.requestID == f.requestID)
        #expect(completed.response.quoteRequestSHA256 == completed.authorized.requestSHA256)
        #expect(completed.response.binding.profile.vocabularySize == f.vocabulary)
        #expect(completed.pinnedVocabularySize == f.vocabulary)
        #expect(completed.pair.peerIdentity == f.pairing.peer.key.publicKey.x963Representation)
        #expect(completed.pair.localIdentity == f.pairing.local.key.publicKey.x963Representation)
        #expect(!completed.response.payloadVerified && !completed.response.qualifiesMaximumEnvelope)
        #expect(try Q.canonical(completed.response) == completed.responseData)
        try FileManager.default.removeItem(at: f.input) // Transient selection input is not retained authority.
        try completed.requireUnchanged(deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000)
        try f.requireFreshDeviceLease() // Completed remains alive through a fresh finite acquisition.
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.device.appendingPathComponent("glm-calibration").path).isEmpty)
        withExtendedLifetime(completed) {}
    }

    @Test func retainedRechecksUseNewFiniteDeadlineAfterQuotationDeadlineExpires() throws {
        let f = try Fixture(), completed = try f.complete()
        let deadline = try #require(UInt64(String(contentsOf: f.model.appendingPathComponent("quote-deadline"),
            encoding: .utf8)))
        while DispatchTime.now().uptimeNanoseconds <= deadline { usleep(5000) }
        #expect(throws: (any Error).self) { try completed.requireUnchanged(deadline: deadline) }
        try completed.requireUnchanged(deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000)
        try f.requireFreshDeviceLease()
        #expect(throws: (any Error).self) {
            try completed.requireUnchanged(deadline: DispatchTime.now().uptimeNanoseconds
                + ClusterWorkerLimits.deadlineNanoseconds + 1_000_000_000)
        }
    }

    @Test(arguments: ["app", "worker", "metallib", "config", "index"])
    func changedRetainedFileCannotPrepareFiniteOwner(file: String) throws {
        let f = try Fixture(), completed = try f.complete()
        let paths = ["app": f.app, "worker": f.worker, "metallib": f.metallib,
            "config": f.model.appendingPathComponent("config.json"),
            "index": f.model.appendingPathComponent("model.safetensors.index.json")]
        try Data("changed owned fixture".utf8).write(to: #require(paths[file]))
        #expect(throws: (any Error).self) {
            try completed.requireUnchanged(deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000)
        }
        try f.requireFreshDeviceLease()
    }

    @Test func changedExplicitPairCannotPrepareFiniteOwner() throws {
        let f = try Fixture(), completed = try f.complete()
        try f.pairing.write()
        #expect(throws: (any Error).self) {
            try completed.requireUnchanged(deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000)
        }
        try f.requireFreshDeviceLease()
    }

    @Test(arguments: ["nonzero", "wrongRequest", "wrongVocabulary", "unknownBinding"])
    func failedOrInvalidActualChildCannotMintCompleted(mode: String) throws {
        let f = try Fixture(mode: mode)
        #expect(throws: (any Error).self) { try f.complete() }
        try f.requireFreshDeviceLease()
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.device.appendingPathComponent("glm-calibration").path).isEmpty)
    }
}
