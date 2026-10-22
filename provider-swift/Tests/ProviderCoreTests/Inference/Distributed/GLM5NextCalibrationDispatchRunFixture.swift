import CryptoKit
import Darwin
import Foundation
import Testing
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
@_spi(OwnerService) import DarkbloomClusterRemote
@testable import ProviderCore

/// Real driver, encrypted loopback, isolated actual owners and actual CPU
/// child prelude/mesh/exits. Synthetic metadata/report content, never model/RDMA.
final class GLM5NextCalibrationDispatchRunFixture: @unchecked Sendable {
    typealias Driver = GLM5NextCalibrationDispatch
    typealias Owner = GLM5NextCalibrationInstalledOwner
    typealias C = GLM5NextCalibrationInstalledQuote
    typealias F = GLM5NextCalibrationPeerQuoteFixture
    typealias W = GLM5NextCalibrationDispatchWire
    let seed: F
    let quotes: [C.Completed]
    let nodes: [GLM5NextCalibrationPairedControl]
    let drivers: [Driver]
    let session: UUID
    let root: URL
    let fences: [URL]
    let devices: [URL]
    let ledger: Ledger

    /// Real observers record exact owner/context values, never mint completions.
    final class Ledger: @unchecked Sendable {
        let seed: F // scratch cannot disappear before all actual retirements
        private let lock = NSLock()
        private var owners: [Int: Owner] = [:]
        private var contexts: [Int: Owner.CommitContext] = [:]
        private var results: [Int: Result<Data, any Error>] = [:]
        private var started = false, cleaning = false
        init(_ seed: F) { self.seed = seed }
        func record(_ rank: Int, _ event: Driver.Observation) {
            lock.withLock {
                switch event {
                case .prepared(let owner): owners[rank] = owner
                case .committed(let context): contexts[rank] = context
                case .beforeLaunch:
                    #expect(owners.count == 2 && contexts.count == 2)
                    #expect(contexts[0]?.starts.map(\.canonicalBytes) == contexts[1]?.starts.map(\.canonicalBytes))
                    #expect(contexts[rank]?.binding.rank == rank)
                default: break
                }
            }
        }
        func start() { lock.withLock { started = true } }
        func finish(_ rank: Int, _ result: Result<Data, any Error>) { lock.withLock { results[rank] = result } }
        func result(_ rank: Int) -> Result<Data, any Error>? { lock.withLock { results[rank] } }
        func owner(_ rank: Int) -> Owner? { lock.withLock { owners[rank] } }
        func context(_ rank: Int) -> Owner.CommitContext? { lock.withLock { contexts[rank] } }
        func cleanup() {
            let values = lock.withLock { cleaning = true; return Array(owners.values) }
            for value in values { value.cancel() }
        }
        func watch() async {
            while true {
                let state = lock.withLock { (Array(owners.values), started, cleaning, results.count) }
                if state.0.count == 2 && state.0.allSatisfy({ $0.status().bootstrapCompleted }) {
                    for rank in 0...1 {
                        try? Data("actual-bootstrap-completed".utf8).write(to: seed.base.model.appendingPathComponent("dispatch-release-\(rank)"))
                    }
                }
                if state.2 {
                    for owner in state.0 { owner.cancel() }
                    let retired = state.0.allSatisfy { owner in
                        let status = owner.status()
                        return status.phase == .retired && status.journalResolved
                            && (!status.observedExit || owner.actualExit()?.localJournalResolved == true)
                    }
                    if retired && (!state.1 || state.3 == 2) { break }
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            withExtendedLifetime(seed) {}
        }
    }

    convenience init(holdReportForRank: Int? = nil, experimentLifetimeSeconds: Int = 18,
         observe: @escaping @Sendable (Int, Driver.Observation, GLM5NextCalibrationPairedControl) throws -> Void = { _, _, _ in }) throws {
        try self.init(holdReportForRank: holdReportForRank, experimentLifetimeSeconds: experimentLifetimeSeconds,
            afterTerminalContextSample: { _ in }, observe: observe)
    }

    init(holdReportForRank: Int? = nil, experimentLifetimeSeconds: Int = 18,
         afterTerminalContextSample: @escaping @Sendable (Int) throws -> Void,
         observe: @escaping @Sendable (Int, Driver.Observation, GLM5NextCalibrationPairedControl) throws -> Void = { _, _, _ in }) throws {
        try #require((1...3600).contains(experimentLifetimeSeconds))
        let env = ProcessInfo.processInfo.environment
        let helperPath = try #require(env["DARKBLOOM_GLM_DISPATCH_CPU_CHILD"])
        let helperSHA = try #require(env["DARKBLOOM_GLM_DISPATCH_CPU_CHILD_SHA256"])
        let helperSource = URL(fileURLWithPath: helperPath)
        try #require(helperSource.path.hasPrefix("/"), "Explicit CPU helper binary required")
        try #require(try F.hash(helperSource) == helperSHA, "CPU helper must match parent-built hash")
        let seed = try F(); let base = seed.base
        let root = base.device.deletingLastPathComponent()
        if let rank = holdReportForRank {
            try #require((0...1).contains(rank))
            let hold = base.model.appendingPathComponent("dispatch-report-hold-\(rank)")
            try Data("hold-before-report\n".utf8).write(to: hold)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hold.path)
        }
        let helper = root.appendingPathComponent("dispatch-cpu-child")
        try FileManager.default.copyItem(at: helperSource, to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        try #require(try F.hash(helper) == helperSHA)
        let peerStore = ClusterPairingStore(directory: root.appendingPathComponent("opposite-pair"))
        var records = try Self.object(Data(contentsOf: peerStore.recordsFile))
        var pairs = records["pairings"] as! [[String: Any]]
        var link = pairs[0]["link"] as! [String: Any]
        let old = link["localInterface"]!; link["localInterface"] = link["peerInterface"]; link["peerInterface"] = old
        let secondSecret = peerStore.recordsFile.deletingLastPathComponent().appendingPathComponent("dispatch-test.secret")
        link["secretFile"] = secondSecret.path; pairs[0]["link"] = link; records["pairings"] = pairs
        try F.json(records).write(to: peerStore.recordsFile)
        let secret = Data((String(repeating: "17", count: 32) + "\n").utf8)
        for url in [URL(fileURLWithPath: seed.local.pair.record.link.secretFile), secondSecret] {
            try secret.write(to: url); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let localRank = seed.local.authorized.request.selection.rank
        let names = localRank == 0 ? ["rdma_en6", "rdma_en1"] : ["rdma_en1", "rdma_en6"]
        let matrix = root.appendingPathComponent("matrix.json")
        try JSONSerialization.data(withJSONObject: [[NSNull(), names[0]], [names[1], NSNull()]]) .write(to: matrix)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: matrix.path)
        let original = try String(contentsOf: base.worker, encoding: .utf8)
        // exec preserves the direct-child PID and stdin credential. The helper
        // implements the actual bootstrap child ABI; no shell/grandchild owner.
        let wrapper = """
        #!/usr/bin/python3
        import os, sys
        if '--glm-calibrate' in sys.argv:
            helper = os.environ['DARKBLOOM_GLM_DISPATCH_CPU_HELPER']
            os.execve(helper, [helper] + sys.argv[1:], dict(os.environ))
        """
        try Data((wrapper + "\n" + original.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")).utf8).write(to: base.worker)
        let workerSHA = try F.hash(base.worker)
        let peerInput = root.appendingPathComponent("opposite-input.json")
        let expiry = Int64(Date().timeIntervalSince1970) + Int64(experimentLifetimeSeconds)
        for path in [base.input, peerInput] {
            var input = try Self.object(Data(contentsOf: path))
            var request = input["request"] as! [String: Any], selection = request["selection"] as! [String: Any]
            var facts = selection["environment"] as! [String: Any], environment = input["environment"] as! [String: String]
            environment["JACCL_IBV_DEVICES"] = matrix.path
            environment["DARKBLOOM_GLM_DISPATCH_CPU_HELPER"] = helper.path
            environment["DARKBLOOM_GLM_DISPATCH_CPU_HELPER_SHA256"] = helperSHA
            facts["binarySHA256"] = workerSHA; facts["variableSHA256"] = F.variables(environment)
            selection["expiresUnixSeconds"] = expiry; selection["environment"] = facts
            request["selection"] = selection; input["request"] = request
            input["environment"] = environment; input["peerBinarySHA256"] = workerSHA
            try F.json(input).write(to: path)
        }
        let own = try base.complete()
        let other = try C.complete(input: peerInput, installedExecutable: base.app, deviceDirectory: seed.peerDevice,
            quoteTimeoutNanoseconds: base.timeout, loadPair: { cluster, pin in
                try GLM5NextCalibrationInstalledPair.load(clusterID: cluster, peerPin: pin,
                    store: peerStore, loadSigner: { base.pairing.peer })
            })
        let quotes = [own, other].sorted { $0.authorized.request.selection.rank < $1.authorized.request.selection.rank }
        for quote in quotes {
            try quote.responseData.write(to: base.model.appendingPathComponent("dispatch-quote-\(quote.authorized.request.selection.rank).json"))
        }
        let session = UUID()
        let listener = try GLM5NextCalibrationPairedControl.isolatedLoopbackTests(completed: quotes[0], sessionID: session, port: 0,
            afterTerminalContextSample: { try afterTerminalContextSample(0) })
        let connector: GLM5NextCalibrationPairedControl
        do { connector = try .isolatedLoopbackTests(completed: quotes[1], sessionID: session, port: #require(listener.boundPort),
            afterTerminalContextSample: { try afterTerminalContextSample(1) }) }
        catch { listener.close(); throw error }
        let nodes = [listener, connector]
        let devices = localRank == 0 ? [base.device, seed.peerDevice] : [seed.peerDevice, base.device]
        let fences = (0...1).map { root.appendingPathComponent("dispatch-fences-\($0)") }
        let ledger = Ledger(seed)
        var drivers: [Driver] = []
        do {
            for rank in 0...1 {
                let quote = quotes[rank], node = nodes[rank]
                let interface = quote.pair.record.link.localInterface
                let environment = Owner.Resources.Environment.isolatedTests(
                    providerLock: root.appendingPathComponent("dispatch-provider-\(rank).lock"), deviceDirectory: devices[rank],
                    orphanCheck: {}, linkReady: { _ = try #require($0 == "rdma_" + interface) },
                    requirePhysicalInterface: { device, actual in
                        _ = try #require(device == "rdma_" + interface && actual == interface)
                    })
                drivers.append(try Driver.isolatedTests(completed: quote, channel: node, sessionID: session,
                    fenceDirectory: fences[rank], environment: environment, observe: { event in
                        ledger.record(rank, event); try observe(rank, event, node)
                    }))
            }
        } catch { for node in nodes { node.close() }; throw error }
        self.seed = seed; self.quotes = quotes; self.nodes = nodes; self.drivers = drivers
        self.session = session; self.root = root; self.fences = fences; self.devices = devices; self.ledger = ledger
        Task { await ledger.watch() }
    }
    deinit { cleanup() }
    func start() {
        ledger.start()
        for rank in 0...1 {
            let driver = drivers[rank], ledger = ledger
            Task.detached { ledger.finish(rank, Result { try driver.run() }) }
        }
    }
    func cleanup() {
        for driver in drivers { driver.cancel() }
        for node in nodes { node.close() }
        ledger.cleanup()
    }
    func wait(_ predicate: () -> Bool, seconds: Double = 2) throws {
        let end = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1e9)
        while !predicate(), DispatchTime.now().uptimeNanoseconds < end { usleep(1_000) }
        try #require(predicate(), "Bounded CPU fixture observation expired")
    }
    func join() throws -> [Data] {
        try wait({ ledger.result(0) != nil && ledger.result(1) != nil }, seconds: 8)
        return try (0...1).map { try #require(ledger.result($0)).get() }
    }
    func requireSuccess(_ outputs: [Data]) throws {
        try #require(outputs.count == 2)
        for rank in 0...1 {
            let summary = try Self.object(outputs[rank])
            #expect(summary["success"] as? Bool == true)
            #expect(summary["servingGrant"] as? Bool == false)
            #expect(summary["actualLocalExitObserved"] as? Bool == true)
            #expect(summary["peerAuthenticatedRetirementClaim"] as? Bool == true)
            let owner = try #require(ledger.owner(rank)), context = try #require(ledger.context(rank))
            #expect(owner.status().bootstrapCompleted && owner.status().journalResolved)
            #expect(owner.actualExit()?.termination == .exited(0))
            _ = try owner.completed() // Real supervisor/attachment/report validation.
            let actualStart = try Data(contentsOf: seed.base.model.appendingPathComponent("dispatch-start-\(rank)"))
            #expect(actualStart == context.localStart.canonicalBytes)
            #expect(try Data(contentsOf: seed.base.model.appendingPathComponent("dispatch-bootstrap-\(rank)")).count == 32)
            let archive = try Self.object(Data(contentsOf: URL(fileURLWithPath: try #require(summary["detailedReportArchive"] as? String))))
            try requireArchivedCommitProfiles(archive)
            let results = try #require(archive["results"] as? [[String: Any]])
            #expect(results.count == 2 && results.allSatisfy { $0["report"] as? String != nil && $0["journalResolved"] as? Bool == true })
            #expect(!FileManager.default.fileExists(atPath: pending(rank).path))
            let lease = try ClusterDeviceLease(directoryURL: devices[rank])
            try lease.requireHeld() // Fresh empty gate; there is no new journal to resolve.
            #expect(try Data(contentsOf: devices[rank].appendingPathComponent("native-device.lease")).isEmpty)
            withExtendedLifetime(lease) {}
        }
        #expect(ledger.context(0)?.starts.map(\.canonicalBytes) == ledger.context(1)?.starts.map(\.canonicalBytes))
    }
    /// Independent oracle: genuine signed D.Profile -> SHA256 bytes -> native
    /// common + archived wire digest. Never derives expected bytes via W.hash/hex
    /// or re-encodes the non-Encodable worker-profile projection.
    private func requireArchivedCommitProfiles(_ archive: [String: Any]) throws {
        typealias D = GLM5NextCalibrationDocument
        let commits = try #require(archive["commits"] as? [String])
        let documents = try #require(archive["signedFiniteDocuments"] as? [String])
        try #require(commits.count == 2 && documents.count == 2)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for rank in 0...1 {
            let owner = try #require(ledger.owner(rank))
            let context = try #require(ledger.context(rank))
            let documentBytes = try #require(Data(base64Encoded: documents[rank]))
            try #require(documentBytes == owner.outboundDocument)
            let signed = try JSONDecoder().decode(D.SignedDocument.self, from: documentBytes)
            let publicKey = try P256.Signing.PublicKey(x963Representation: quotes[rank].pair.localIdentity)
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: signed.signature)
            try #require(publicKey.isValidSignature(signature, for: D.domain + signed.payload))
            let body = try JSONDecoder().decode(D.Body.self, from: signed.payload)
            let expected = Data(SHA256.hash(data: try encoder.encode(body.binding.profile)))
            let expectedHex = expected.map { String(format: "%02x", $0) }.joined()
            let commitBytes = try #require(Data(base64Encoded: commits[rank]))
            let commit = try JSONDecoder().decode(W.Commit.self, from: commitBytes)
            #expect(context.localStart.common.profileSHA256 == expected)
            #expect(context.starts.allSatisfy { $0.common.profileSHA256 == expected })
            #expect(commit.profileSHA256 == expectedHex)
        }
    }
    func reportHold(_ rank: Int) -> URL {
        seed.base.model.appendingPathComponent("dispatch-report-hold-\(rank)")
    }
    func reportHeld(_ rank: Int) -> URL {
        seed.base.model.appendingPathComponent("dispatch-report-held-\(rank)")
    }
    func releaseReport(_ rank: Int) throws {
        try #require((0...1).contains(rank))
        try #require(FileManager.default.fileExists(atPath: reportHold(rank).path))
        try FileManager.default.removeItem(at: reportHold(rank))
    }
    func pending(_ rank: Int) -> URL {
        let pair = quotes[rank].pair
        return fences[rank].appendingPathComponent(W.hash(Data((pair.clusterID + ":" + pair.record.link.edgeID).utf8)) + ".finite-pending.json")
    }
    static func object(_ data: Data) throws -> [String: Any] { try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
}
