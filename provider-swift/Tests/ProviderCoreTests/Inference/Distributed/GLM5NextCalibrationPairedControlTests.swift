import Foundation
import Testing
import DarkbloomClusterSecurity
@testable import ProviderCore

/// UNRUN. Actual loopback encrypted control sockets and actual metadata fixture
/// children only. No native model, real installation, credential or RDMA claim.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_GLM_METADATA_BINDING_REQUIRED"] == "1"))
struct GLM5NextCalibrationPairedControlTests {
    typealias C = GLM5NextCalibrationPairedControl
    typealias W = GLM5NextCalibrationDispatchWire
    final class Fixture {
        let seed: GLM5NextCalibrationPeerQuoteFixture
        let quotes: [GLM5NextCalibrationInstalledQuote.Completed]
        let nodes: [C]
        let session: UUID
        var deadline: UInt64 { DispatchTime.now().uptimeNanoseconds + 2_000_000_000 }
        init(otherSession: UUID? = nil) throws {
            let session = UUID(); self.session = session
            let seed = try GLM5NextCalibrationPeerQuoteFixture()
            // Original metadata fixtures never needed an edge key. Create only
            // fixture secrets, in each actual store's own private directory.
            let hex = Data((String(repeating: "17", count: 32) + "\n").utf8)
            let firstSecret = URL(fileURLWithPath: seed.local.pair.record.link.secretFile)
            try hex.write(to: firstSecret); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: firstSecret.path)
            let root = seed.base.device.deletingLastPathComponent()
            let store = ClusterPairingStore(directory: root.appendingPathComponent("opposite-pair"))
            var records = try JSONSerialization.jsonObject(with: Data(contentsOf: store.recordsFile)) as! [String: Any]
            var pairs = records["pairings"] as! [[String: Any]]
            var link = pairs[0]["link"] as! [String: Any]
            let secondSecret = store.recordsFile.deletingLastPathComponent().appendingPathComponent("edge-fixture.secret")
            link["secretFile"] = secondSecret.path; pairs[0]["link"] = link; records["pairings"] = pairs
            try hex.write(to: secondSecret); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secondSecret.path)
            try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys]).write(to: store.recordsFile)
            let opposite = try GLM5NextCalibrationInstalledQuote.complete(input: root.appendingPathComponent("opposite-input.json"),
                installedExecutable: seed.base.app, deviceDirectory: seed.peerDevice,
                quoteTimeoutNanoseconds: seed.base.timeout, loadPair: { cluster, pin in
                    try GLM5NextCalibrationInstalledPair.load(clusterID: cluster, peerPin: pin, store: store, loadSigner: { seed.peerSigner })
                })
            let quotes = [seed.local, opposite].sorted { $0.authorized.request.selection.rank < $1.authorized.request.selection.rank }
            let listener = try C.isolatedLoopbackTests(completed: quotes[0], sessionID: session, port: 0)
            let connector = try C.isolatedLoopbackTests(completed: quotes[1], sessionID: otherSession ?? session, port: try #require(listener.boundPort))
            self.seed = seed; self.quotes = quotes; nodes = [listener, connector]
            try listener.connect(deadline: deadline); try connector.connect(deadline: deadline)
        }
        deinit { for node in nodes { node.close() } }
        func receive(_ node: C) throws -> W.Packet {
            try #require(try node.receive(deadline: deadline))
        }
    }
    @Test func actualEncryptedChannelAdmitsOnlyItsReceivedPeerQuotation() throws {
        let f = try Fixture()
        let bytes = try GLM5NextCalibrationPeerQuote.outbound(completed: f.quotes[0], now: Int64(Date().timeIntervalSince1970), deadline: f.deadline)
        try f.nodes[0].send(.quotation, bytes, deadline: f.deadline)
        let received = try f.receive(f.nodes[1])
        #expect(received.kind == .quotation)
        let admitted = try GLM5NextCalibrationPeerQuote.admit(completed: f.quotes[1], receiveFromAuthenticatedPair: { pair, _ in
            try f.nodes[1].requireCurrent(pair: pair); return received.payload
        }, now: Int64(Date().timeIntervalSince1970), deadline: f.deadline)
        #expect(admitted.peerSummarySHA256 == W.hash(bytes))
    }
    @Test func wrongSessionPoisonsEvenARealAuthenticatedConnection() throws {
        let f = try Fixture(otherSession: UUID())
        // The receiver can poison and close before the sender finishes its
        // delivery wait. Either operation must reject this actual wrong session.
        #expect(throws: (any Error).self) {
            try f.nodes[0].send(.hello, W.canonical(W.Empty()), deadline: f.deadline)
            _ = try f.receive(f.nodes[1])
        }
        #expect(throws: (any Error).self) { try f.nodes[1].requireCurrent(pair: f.quotes[1].pair) }
    }
    @Test func reconnectCannotRefreshTheOldFiniteConnection() throws {
        let f = try Fixture()
        let port = try #require(f.nodes[0].boundPort)
        f.nodes[1].close()
        let replacement = try C.isolatedLoopbackTests(completed: f.quotes[1], sessionID: f.session, port: port)
        defer { replacement.close() }
        let until = Date().addingTimeInterval(2)
        while Date() < until {
            do { try f.nodes[0].requireCurrent(pair: f.quotes[0].pair); Thread.sleep(forTimeInterval: 0.005) }
            catch { break }
        }
        #expect(throws: (any Error).self) { try f.nodes[0].requireCurrent(pair: f.quotes[0].pair) }
        // A replacement TCP handshake may race teardown; it cannot refresh the
        // old authenticated finite context, regardless of that transport outcome.
        _ = try? replacement.connect(deadline: f.deadline)
        #expect(throws: (any Error).self) { try f.nodes[0].requireCurrent(pair: f.quotes[0].pair) }
        #expect(throws: (any Error).self) { try f.nodes[0].send(.hello, W.canonical(W.Empty()), deadline: f.deadline) }
    }
    @Test func aRealChannelCannotBeSubstitutedForAnotherCompletedOrSession() throws {
        let f = try Fixture()
        try f.nodes[0].requireContext(completed: f.quotes[0], sessionID: f.session)
        #expect(throws: (any Error).self) { try f.nodes[0].requireContext(completed: f.quotes[0], sessionID: UUID()) }
        #expect(throws: (any Error).self) { try f.nodes[0].requireContext(completed: f.quotes[1], sessionID: f.session) }
    }
    @Test func retainedPairMutationRefusesAnOtherwiseLiveChannel() throws {
        let f = try Fixture()
        let rank = f.seed.local.authorized.request.selection.rank
        let store = f.seed.base.pairing.store
        let before = try #require(try store.load())
        // The random fixture signer may be rank1. Change its actual retained
        // store and check that same rank, rather than assuming local is rank0.
        try f.seed.base.pairing.write { $0["transcriptSHA256"] = String(repeating: "b", count: 64) }
        let changed = try #require(try store.load())
        #expect(changed != before)
        #expect(throws: (any Error).self) { try f.nodes[rank].requireCurrent(pair: f.quotes[rank].pair) }
    }
}
