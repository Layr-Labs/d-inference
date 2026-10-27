import CryptoKit
import Foundation
import Testing
import DarkbloomClusterProcess
import DarkbloomClusterRemote
import DarkbloomClusterSecurity
@testable import ProviderCore

/// A serving host that records what the session hands it and, when it is told
/// to stop, which frames the member had already sent.
final class RecordingServingHost: NativePairMemberServingHost, @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [NativePairMemberServingStart] = []
    private var stops: [UUID] = []
    private var completedStops: [UUID] = []
    private var framesAtFirstStop: [String]?
    let failServe: Bool
    /// When set, a failing serve waits for one signal first (the pair's
    /// readiness wait), so it fails after the owner's native launch.
    let failAfter: DispatchSemaphore?
    /// Holds all stop calls until the test permits retirement to finish.
    let finishStopAfter: DispatchGroup?
    let mock: MockCoordinator
    init(mock: MockCoordinator, failServe: Bool = false, failAfter: DispatchSemaphore? = nil,
         finishStopAfter: DispatchGroup? = nil) {
        self.mock = mock; self.failServe = failServe; self.failAfter = failAfter
        self.finishStopAfter = finishStopAfter
    }

    var served: [NativePairMemberServingStart] { lock.withLock { starts } }
    var stopped: [UUID] { lock.withLock { stops } }
    var finishedStopping: [UUID] { lock.withLock { completedStops } }
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
        if let finishStopAfter {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                finishStopAfter.notify(queue: .global()) { done.resume() }
            }
        } else {
            // A retirement takes time; the receipt must wait for it.
            try? await Task.sleep(for: .milliseconds(200))
        }
        lock.withLock { completedStops.append(epoch) }
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

    /// A member stop (pub2 on hardware: the leader closed its control
    /// connection before its owner ended, so no receipt could arrive and the
    /// coordinator fenced both devices for about two minutes): the member
    /// ends its served start while the connection is open and returns only
    /// after the owner released and the receipt was sent. No cancel frame.
    @Test func aMemberStopEndsTheServedStartAndSendsTheReceiptBeforeReturning() async throws {
        let fixture = try NativePairMemberFixture(), peer = MemberFixturePeer(installation: fixture.installations[0])
        let host = RecordingServingHost(mock: peer.mock)
        peer.control.servingHost = host
        do {
            try await peer.connect()
            // Nothing running: returns at once.
            #expect(await peer.control.endSessionBeforeClose(timeout: 1))
            try await peer.mock.pushNativePair(fixture.message("native_pair_prepare", rank: 0, nonce: peer.nonce, sequence: 1))
            _ = try await peer.wait("native_pair_prepared")
            try await peer.mock.pushNativePair(fixture.message("native_pair_owner_start", rank: 0, nonce: peer.nonce, sequence: 2))
            _ = try await peer.wait("native_pair_hello")
            #expect(host.served.count == 1 && host.stopped.isEmpty)
            #expect(await peer.control.endSessionBeforeClose(timeout: 20))
            // The session already ended released when the stop returns: its
            // receipt was written (processed by the connection) before, so a
            // close that follows cannot overtake it. The mock reads it a moment later.
            #expect(["idle", "released"].contains(peer.control.status))
            _ = try await peer.wait("native_pair_owner_released")
            #expect(peer.mock.snapshot().nativePairs.map(\.type) == ["native_pair_prepared", "native_pair_hello", "native_pair_owner_released"])
            #expect(host.stopped.first == fixture.starts[0].common.epoch)
            #expect(host.framesWhenStopped?.contains("native_pair_owner_released") == false)
            try fixture.requireRetired(0, confirmed: false)
            await peer.close()
        } catch { await peer.close(); throw error }
    }

    /// The coordinator's cancel repeats the session's first grant expiry even
    /// after a renewal moved it (hardware pub4): the member still stops the
    /// served start and sends its receipt on the same connection. A cancel
    /// that arrives after the session ended is ignored, the connection stays.
    @Test func aCancelWithTheFirstGrantAfterARenewalStillReleasesAndKeepsTheConnection() async throws {
        let fixture = try NativePairMemberFixture(), peer = MemberFixturePeer(installation: fixture.installations[0])
        let host = RecordingServingHost(mock: peer.mock)
        peer.control.servingHost = host
        do {
            try await peer.connect()
            try await peer.mock.pushNativePair(fixture.message("native_pair_prepare", rank: 0, nonce: peer.nonce, sequence: 1))
            _ = try await peer.wait("native_pair_prepared")
            try await peer.mock.pushNativePair(fixture.message("native_pair_owner_start", rank: 0, nonce: peer.nonce, sequence: 2))
            _ = try await peer.wait("native_pair_hello")
            // A renewal: ordinal 1, expiry 40 s later; the frame repeats it.
            let renewed = fixture.expiresUnix + 40_000_000_000
            var payload = Data([68, 66, 78, 76, 1])
            for shift in stride(from: 56, through: 0, by: -8) { payload.append(UInt8(truncatingIfNeeded: UInt64(1) >> shift)) }
            for shift in stride(from: 56, through: 0, by: -8) { payload.append(UInt8(truncatingIfNeeded: UInt64(renewed) >> shift)) }
            try await peer.mock.pushNativePair(NativePairMessage(type: "native_pair_lease", memberNonce: peer.nonce,
                epoch: withUnsafeBytes(of: fixture.starts[0].common.epoch.uuid) { memberHex(Data($0)) },
                generation: 7, sequence: 3, payload: payload,
                prepareBeforeUnixNano: fixture.prepareUnix, expiresAtUnixNano: renewed))
            try await Task.sleep(for: .milliseconds(200))
            #expect(peer.context.isLive)
            // The cancel carries the first grant (fixture.message's expiry).
            try await peer.mock.pushNativePair(fixture.message("native_pair_cancel", rank: 0, nonce: peer.nonce, sequence: 4, payload: Data([68, 66, 78, 67, 1])))
            _ = try await peer.wait("native_pair_owner_released")
            #expect(peer.context.isLive)
            #expect(host.stopped.first == fixture.starts[0].common.epoch)
            try fixture.requireRetired(0, confirmed: false)
            #expect(peer.mock.snapshot().nativePairs.map(\.type) == ["native_pair_prepared", "native_pair_hello", "native_pair_owner_released"])
            // A late cancel for the ended session: ignored, still attached.
            try await peer.mock.pushNativePair(fixture.message("native_pair_cancel", rank: 0, nonce: peer.nonce, sequence: 6, payload: Data([68, 66, 78, 67, 1])))
            try await Task.sleep(for: .milliseconds(300))
            #expect(peer.context.isLive)
            await peer.close()
        } catch { await peer.close(); throw error }
    }

    /// An immediate host failure needs no binding or coordinator cancel:
    /// the session cancels, retires its real owner and child, then waits for
    /// the host to finish stopping before it sends a release receipt.
    @Test func anImmediatelyFailingHostCancelsAndReleasesAfterRetirement() async throws {
        let fixture = try NativePairMemberFixture(), peer = MemberFixturePeer(installation: fixture.installations[0])
        let stopGate = DispatchGroup()
        stopGate.enter()
        let host = RecordingServingHost(mock: peer.mock, failServe: true, finishStopAfter: stopGate)
        // The control's host reference is weak; the test owns it through cleanup.
        peer.control.servingHost = host
        var stopsReleased = false
        func releaseStops() {
            guard !stopsReleased else { return }
            stopsReleased = true; stopGate.leave()
        }
        defer { releaseStops(); withExtendedLifetime((fixture, host)) {} }
        do {
            try await peer.connect()
            try await peer.mock.pushNativePair(fixture.message("native_pair_prepare", rank: 0, nonce: peer.nonce, sequence: 1))
            _ = try await peer.wait("native_pair_prepared")
            try await peer.mock.pushNativePair(fixture.message("native_pair_owner_start", rank: 0, nonce: peer.nonce, sequence: 2))
            let cancellation = try await peer.wait("native_pair_cancel")
            #expect(Data(base64Encoded: cancellation.payload) == Data([68, 66, 78, 67, 1]))
            let served = try #require(host.served.first)
            #expect(host.served.count == 1 && served.rank == 0)
            #expect(served.start.canonicalBytes == fixture.starts[0].canonicalBytes)
            let epoch = fixture.starts[0].common.epoch
            let owner = try #require(served.endpoint as? any ClusterOwnedWorkerEndpoint)
            let ownerReleased = await owner.waitUntilOwnerReleased(
                deadline: DispatchTime.now().uptimeNanoseconds + 8_000_000_000)
            try #require(ownerReleased, "the real owner must exit with its authenticated release acknowledgement")
            try fixture.requireRetired(0, confirmed: false)
            try await memberFixtureWaitUntil { host.stopped.contains(epoch) }
            // Native retirement alone cannot publish a receipt while host
            // retirement is held. No test teardown has cancelled the session.
            let prematureRelease = try await peer.mock.waitForSnapshot(timeout: .milliseconds(200)) {
                $0.nativePairs.contains { $0.type == "native_pair_owner_released" }
            }
            #expect(prematureRelease == nil)
            #expect(host.finishedStopping.isEmpty)
            releaseStops()
            let release = try await peer.wait("native_pair_owner_released")
            var expected = Data([68, 66, 78, 82, 1])
            expected.append(contentsOf: SHA256.hash(data: fixture.starts[0].canonicalBytes))
            expected.append(contentsOf: [1, 1, 1])
            #expect(Data(base64Encoded: release.payload) == expected)
            #expect(release.epoch == cancellation.epoch && release.generation == cancellation.generation)
            #expect(release.sequence > cancellation.sequence)
            #expect(host.finishedStopping.contains(epoch))
            #expect(host.framesWhenStopped?.contains("native_pair_owner_released") == false)
            #expect(peer.context.isLive)
            let frames = peer.mock.snapshot().nativePairs.map(\.type)
            #expect(frames.first == "native_pair_prepared" && frames.last == "native_pair_owner_released")
            #expect(frames.filter { $0 == "native_pair_cancel" }.count == 1)
            #expect(frames.filter { $0 == "native_pair_owner_released" }.count == 1)
            #expect(!frames.contains("native_pair_confirmation"))
            await peer.closeAfterJoiningSession()
        } catch {
            releaseStops()
            await peer.closeAfterJoiningSession()
            throw error
        }
    }
}
