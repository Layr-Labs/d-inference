import Foundation
import XCTest
import DarkbloomClusterProcess
import DarkbloomClusterProtocol
@testable import DarkbloomClusterRemote

private final class DiscardingWorkerTransport: ClusterLinkWorkerTransport, @unchecked Sendable {
    func send(_ bytes: Data) throws {}
}

/// Candidate 35 (2026-10-22): at ~1,040,000 prompt tokens the owner writer of a rank gave up on the ~7 MB record
/// after its half second, the endpoint failed and the leader ended the pair. A command now has its own delivery
/// deadline. And a reservation the follower's own owner cannot take is that request's refusal, said to the leader
/// on the link (`commandRefused`) without touching the worker's event sequence, instead of a fence.
final class ClusterLinkWorkerCommandRefusalTests: XCTestCase {
    let identity = ClusterWorkerIdentity(membershipEpoch: UUID(), modelID: "invented",
        artifactSHA256: String(repeating: "a", count: 64), configurationSHA256: String(repeating: "b", count: 64),
        peers: [.init(id: "first", buildSHA256: String(repeating: "c", count: 64)),
                .init(id: "second", buildSHA256: String(repeating: "d", count: 64))])
    let profile = ClusterWorkerProfile(id: "invented", vocabularySize: 1000,
        maximumPromptTokens: 8, maximumOutputTokens: 4, maximumChunkTokens: 4, maximumContextTokens: 12)
    let plan = String(repeating: "e", count: 64)

    func testAnOwnerCommandHasItsOwnDeliveryDeadline() {
        let now: UInt64 = 1_000_000_000_000, retirement = now + 120_000_000_000
        XCTAssertEqual(ClusterRemoteWorkerEndpoint.ownerWriteDeadline(now: now, ownerRetirement: retirement), now + 500_000_000)
        XCTAssertEqual(ClusterRemoteWorkerEndpoint.ownerWriteDeadline(now: now, ownerRetirement: retirement,
            commandDelivery: now + 30_000_000_000), now + 30_000_000_000)
        XCTAssertEqual(ClusterRemoteWorkerEndpoint.ownerWriteDeadline(now: now, ownerRetirement: now + 1_000,
            commandDelivery: now + 30_000_000_000), now + 1_000)
    }

    func testOnlyAReservationTheFollowersOwnerCouldNotTakeIsThatRequestsRefusal() {
        let reserve = ClusterWorkerCommand.reserve(.init(profileID: "invented", promptTokenIDs: [1], stopTokenIDs: [],
            outputCount: 1, chunkSize: 1, deadlineUptimeNanoseconds: 1, capacityLimitBytes: 1, sampling: nil))
        XCTAssertEqual(ClusterLinkWorkerWire.requestRefusal(relaying: reserve, failure: ClusterWorkerOwnerError.refused(.busy)), .busy)
        XCTAssertEqual(ClusterLinkWorkerWire.requestRefusal(relaying: reserve,
            failure: ClusterWorkerProtocolError.invalid("too large")), .profile)
        XCTAssertNil(ClusterLinkWorkerWire.requestRefusal(relaying: reserve, failure: ClusterWorkerOwnerError.refused(.unavailable)))
        XCTAssertNil(ClusterLinkWorkerWire.requestRefusal(relaying: reserve, failure: ClusterWorkerOwnerError.closed))
        XCTAssertNil(ClusterLinkWorkerWire.requestRefusal(relaying: .start, failure: ClusterWorkerOwnerError.refused(.busy)))
    }

    func testTheRefusedCommandWireCarriesExactlyItsRequestAndReason() throws {
        var wire = ClusterLinkWorkerWire(kind: .commandRefused, epoch: identity.membershipEpoch, session: UUID(), sequence: 3)
        wire.requestID = UUID(); wire.detail = ClusterWorkerRefusal.busy.rawValue
        XCTAssertEqual(try ClusterLinkWorkerWire.decode(try wire.encoded()), wire)
        var unavailable = wire; unavailable.detail = ClusterWorkerRefusal.unavailable.rawValue
        XCTAssertThrowsError(try unavailable.encoded())
        var unnamed = wire; unnamed.requestID = nil
        XCTAssertThrowsError(try unnamed.encoded())
        var carrying = wire; carrying.worker = Data([1])
        XCTAssertThrowsError(try carrying.encoded())
    }

    /// The leader hears the follower's refusal as that rank's `refused` event for the request, the endpoint stays
    /// valid and the worker's own next event (its sequence untouched) is still accepted.
    func testTheLeaderHearsARelayedRefusalAsThatRequestsAndServesOn() throws {
        let endpoint = try ClusterLinkWorkerEndpoint(transport: DiscardingWorkerTransport(), clusterID: "fixture",
            expectedIdentity: identity, profile: profile, rank: 1, executionPlanSHA256: plan,
            lifetimeDeadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 20_000_000_000, bootstrapRelay: nil)
        let epoch = identity.membershipEpoch
        var sequence: UInt64 = 0
        func wire(_ kind: ClusterLinkWorkerWire.Kind) -> ClusterLinkWorkerWire {
            defer { sequence += 1 }
            return ClusterLinkWorkerWire(kind: kind, epoch: epoch, session: endpoint.session, sequence: sequence)
        }
        func event(_ value: ClusterWorkerEvent, _ native: UInt64, request: UUID?) throws -> ClusterLinkWorkerWire {
            var w = wire(.event)
            w.worker = try ClusterWorkerCodec.encode(ClusterWorkerEventFrame(membershipEpoch: epoch, sequence: native,
                requestID: request, event: value))
            return w
        }
        endpoint.accept(wire(.accepted))
        let ready = ClusterWorkerReady(identity: identity, rank: 1, profile: profile, executionPlanSHA256: plan,
            requestCapacityBytes: 1024)
        endpoint.accept(try event(.ready(ready), 0, request: nil))
        XCTAssertNotNil(endpoint.readiness)
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        XCTAssertEqual(try endpoint.receiveWorkerEvent(until: deadline, cancelled: { false }).event, .ready(ready))

        let refused = UUID()
        var refusal = wire(.commandRefused)
        refusal.requestID = refused; refusal.detail = ClusterWorkerRefusal.busy.rawValue
        endpoint.accept(refusal)
        let heard = try endpoint.receiveWorkerEvent(until: deadline, cancelled: { false })
        XCTAssertEqual(heard.requestID, refused)
        XCTAssertEqual(heard.event, .refused(.busy))
        XCTAssertNotNil(endpoint.readiness, "a request's refusal leaves the follower serving")

        // The worker never saw that reservation: its next event is still its sequence 1.
        let next = UUID()
        endpoint.accept(try event(.admitted(reservedBytes: 100), 1, request: next))
        let admitted = try endpoint.receiveWorkerEvent(until: deadline, cancelled: { false })
        XCTAssertEqual(admitted.requestID, next)
        XCTAssertEqual(admitted.event, .admitted(reservedBytes: 100))
        XCTAssertNotNil(endpoint.readiness)
    }
}
