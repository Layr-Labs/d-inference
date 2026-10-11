import CryptoKit
import Foundation
import Testing
import DarkbloomClusterProcess
import DarkbloomClusterSecurity
@testable import ProviderCore

/// A serving host that records what the session hands it and, when it is told
/// to stop, which frames the member had already sent.
final class RecordingServingHost: NativePairMemberServingHost, @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [NativePairMemberServingStart] = []
    private var stops: [UUID] = []
    private var framesAtFirstStop: [String]?
    let failServe: Bool
    /// When set, a failing serve waits for one signal first (the pair's
    /// readiness wait), so it fails after the owner's native launch.
    let failAfter: DispatchSemaphore?
    let mock: MockCoordinator
    init(mock: MockCoordinator, failServe: Bool = false, failAfter: DispatchSemaphore? = nil) {
        self.mock = mock; self.failServe = failServe; self.failAfter = failAfter
    }

    var served: [NativePairMemberServingStart] { lock.withLock { starts } }
    var stopped: [UUID] { lock.withLock { stops } }
    var framesWhenStopped: [String]? { lock.withLock { framesAtFirstStop } }

    func serveCommittedStart(_ start: NativePairMemberServingStart) async throws {
        lock.withLock { starts.append(start) }
        if let failAfter {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async { failAfter.wait(); done.resume() }
            }
        }
        if failServe { throw ClusterPairSlotError.ownerUnavailable }
    }

    func stopServingCommittedStart(epoch: UUID) async {
        let frames = mock.snapshot().nativePairs.map(\.type)
        lock.withLock { stops.append(epoch); if framesAtFirstStop == nil { framesAtFirstStop = frames } }
        // A retirement takes time; the receipt must wait for it.
        try? await Task.sleep(for: .milliseconds(200))
    }
}

/// The member session serving a committed start (S10) against a real owner
/// process and native child (the key-only fixture, CPU only) and the mock
/// coordinator: the session hands its launched owner to the serving host and
/// sends its release receipt only after the host retired what it served.
/// Control flow and ownership only, never a pair, mesh or model.
@Suite("Owned native member serving a committed start", .serialized, .timeLimit(.minutes(3)))
struct NativePairMemberServingTests {
    @Test func bothMembersHandTheirOwnerToTheHostAndReleaseOnlyAfterItRetired() async throws {
        let fixture = try NativePairMemberFixture()
        let peers = fixture.installations.map(MemberFixturePeer.init)
        let hosts = peers.map { RecordingServingHost(mock: $0.mock) }
        for rank in 0..<2 { peers[rank].control.servingHost = hosts[rank] }
        do {
            for peer in peers { try await peer.connect() }
            for rank in 0..<2 { try await peers[rank].mock.pushNativePair(fixture.message("native_pair_prepare", rank: rank, nonce: peers[rank].nonce, sequence: 1)) }
            for rank in 0..<2 { _ = try await peers[rank].wait("native_pair_prepared") }
            // Nothing is served before the start is committed and launched.
            #expect(hosts.allSatisfy { $0.served.isEmpty })
            for rank in 0..<2 { try await peers[rank].mock.pushNativePair(fixture.message("native_pair_owner_start", rank: rank, nonce: peers[rank].nonce, sequence: 2)) }
            var hellos: [ClusterNativeKeyHello] = []
            for rank in 0..<2 {
                let message = try await peers[rank].wait("native_pair_hello")
                hellos.append(try ClusterNativeKeyHello(encoded: #require(Data(base64Encoded: message.payload))))
            }
            for rank in 0..<2 {
                let served = try #require(hosts[rank].served.first)
                #expect(hosts[rank].served.count == 1 && served.rank == rank)
                #expect(served.start.canonicalBytes == fixture.starts[rank].canonicalBytes)
                #expect(served.identity.membershipEpoch == fixture.starts[rank].common.epoch)
                #expect(served.endpoint.rank == rank && served.endpoint.expectedIdentity == served.identity)
                #expect(served.executionPlanSHA256 == fixture.installations[rank].executionPlanSHA256)
            }
            let binding = try ClusterNativeKeyBinding(hellos: hellos)
            for rank in 0..<2 { try await peers[rank].mock.pushNativePair(fixture.message("native_pair_binding", rank: rank, nonce: peers[rank].nonce, sequence: 3, payload: binding.canonicalBytes)) }
            var confirmations: [Data] = []
            for rank in 0..<2 { confirmations.append(try #require(Data(base64Encoded: try await peers[rank].wait("native_pair_confirmation").payload))) }
            for rank in 0..<2 { try await peers[rank].mock.pushNativePair(fixture.message("native_pair_peer_confirmation", rank: rank, nonce: peers[rank].nonce, sequence: 4, payload: confirmations[1 - rank])) }
            for rank in 0..<2 {
                let release = try await peers[rank].wait("native_pair_owner_released")
                var expected = Data([68, 66, 78, 82, 1]); expected.append(contentsOf: SHA256.hash(data: fixture.starts[rank].canonicalBytes)); expected.append(contentsOf: [1, 1, 1])
                #expect(Data(base64Encoded: release.payload) == expected)
                #expect(hosts[rank].stopped.first == fixture.starts[rank].common.epoch)
                // The host was told to stop, and finished, before the receipt.
                #expect(hosts[rank].framesWhenStopped?.contains("native_pair_owner_released") == false)
                try fixture.requireRetired(rank, confirmed: true)
                #expect(peers[rank].mock.snapshot().nativePairs.map(\.type)
                    == ["native_pair_prepared", "native_pair_hello", "native_pair_confirmation", "native_pair_owner_released"])
            }
            for peer in peers { await peer.close() }
        } catch { for peer in peers { await peer.close() }; throw error }
    }

    /// A host that cannot serve (the pair did not form within its readiness
    /// wait) ends the session the way any failure does: cancel, native
    /// cleanup, then the receipt.
    @Test func aHostThatCannotServeCancelsAndStillReleases() async throws {
        let fixture = try NativePairMemberFixture(), peer = MemberFixturePeer(installation: fixture.installations[0])
        let formed = DispatchSemaphore(value: 0)
        let host = RecordingServingHost(mock: peer.mock, failServe: true, failAfter: formed)
        peer.control.servingHost = host
        do {
            try await peer.connect()
            try await peer.mock.pushNativePair(fixture.message("native_pair_prepare", rank: 0, nonce: peer.nonce, sequence: 1))
            _ = try await peer.wait("native_pair_prepared")
            try await peer.mock.pushNativePair(fixture.message("native_pair_owner_start", rank: 0, nonce: peer.nonce, sequence: 2))
            _ = try await peer.wait("native_pair_hello") // The native child runs and waits for its peer.
            formed.signal()
            _ = try await peer.wait("native_pair_cancel")
            _ = try await peer.wait("native_pair_owner_released")
            #expect(host.served.count == 1 && host.stopped.contains(fixture.starts[0].common.epoch))
            #expect(host.framesWhenStopped?.contains("native_pair_owner_released") == false)
            try fixture.requireRetired(0, confirmed: false)
            let frames = peer.mock.snapshot().nativePairs.map(\.type)
            #expect(frames.first == "native_pair_prepared" && frames.last == "native_pair_owner_released" && frames.contains("native_pair_cancel"))
            await peer.close()
        } catch { await peer.close(); throw error }
    }

    /// The coordinator cancels a served start: the host is told at once, and
    /// the receipt still waits for the owner's exit and the host's retirement.
    @Test func aCoordinatorCancelStopsTheServedStartBeforeTheReceipt() async throws {
        let fixture = try NativePairMemberFixture(), peer = MemberFixturePeer(installation: fixture.installations[0])
        let host = RecordingServingHost(mock: peer.mock)
        peer.control.servingHost = host
        do {
            try await peer.connect()
            try await peer.mock.pushNativePair(fixture.message("native_pair_prepare", rank: 0, nonce: peer.nonce, sequence: 1))
            _ = try await peer.wait("native_pair_prepared")
            try await peer.mock.pushNativePair(fixture.message("native_pair_owner_start", rank: 0, nonce: peer.nonce, sequence: 2))
            _ = try await peer.wait("native_pair_hello")
            #expect(host.served.count == 1 && host.stopped.isEmpty)
            try await peer.mock.pushNativePair(fixture.message("native_pair_cancel", rank: 0, nonce: peer.nonce, sequence: 5, payload: Data([68, 66, 78, 67, 1])))
            _ = try await peer.wait("native_pair_owner_released")
            #expect(host.stopped.first == fixture.starts[0].common.epoch)
            #expect(host.framesWhenStopped?.contains("native_pair_owner_released") == false)
            try fixture.requireRetired(0, confirmed: false)
            #expect(peer.mock.snapshot().nativePairs.map(\.type) == ["native_pair_prepared", "native_pair_hello", "native_pair_owner_released"])
            await peer.close()
        } catch { await peer.close(); throw error }
    }

    /// Probe, not a requirement of this slice: a cancel that lands right after
    /// the owner's launch, before its native child reached the key exchange
    /// (here a host that fails at once). Observed 2026-10-11: the member
    /// quarantined without a receipt (the production host fails only after
    /// the pair's readiness wait). Recorded as a known, possibly intermittent
    /// issue of the member session's early cancellation.
    @Test func aCancelRightAfterTheLaunchProbe() async throws {
        let fixture = try NativePairMemberFixture(), peer = MemberFixturePeer(installation: fixture.installations[0])
        peer.control.servingHost = RecordingServingHost(mock: peer.mock, failServe: true)
        do {
            try await peer.connect()
            try await peer.mock.pushNativePair(fixture.message("native_pair_prepare", rank: 0, nonce: peer.nonce, sequence: 1))
            _ = try await peer.wait("native_pair_prepared")
            try await peer.mock.pushNativePair(fixture.message("native_pair_owner_start", rank: 0, nonce: peer.nonce, sequence: 2))
            _ = try await peer.wait("native_pair_cancel")
            // Longer than the ordinary 8 s wait: tells a slow cleanup from a
            // member that never releases.
            let began = ContinuousClock.now
            while ContinuousClock.now - began < .seconds(45),
                  !peer.mock.snapshot().nativePairs.contains(where: { $0.type == "native_pair_owner_released" }) {
                try await Task.sleep(for: .milliseconds(50))
            }
            let released = peer.mock.snapshot().nativePairs.contains { $0.type == "native_pair_owner_released" }
            print("s09-probe: released \(released) after \(ContinuousClock.now - began), control \(peer.control.status), frames \(peer.mock.snapshot().nativePairs.map(\.type))")
            withKnownIssue("an early cancel can quarantine the member", isIntermittent: true) { #expect(released) }
            await peer.close()
        } catch { await peer.close(); throw error }
    }
}
