import Foundation
import Testing
import DarkbloomClusterProtocol
@testable import DarkbloomClusterRemote

/// Every hop that rebuilds a reservation for another clock (the owner wire to
/// a rank's worker owner, the link wire to the follower in both directions)
/// carries the request's prefix partition unchanged, and the default (cache
/// on, no tenant) stays absent from every record that crosses.
struct ClusterPrefixCacheForwardingTests {
    @Test func ownerAndLinkDeadlineTranslationPreserveThePrefixPartition() throws {
        let salt = "authenticated-tenant-scope"
        let digest = ClusterWorkerPrefixCache.tenantDigest(salt: salt)
        let epoch = UUID(), request = UUID(), session = UUID()
        for carried in [nil, ClusterWorkerPrefixCache.disabled, .tenant(digest)] {
            let reservation = ClusterWorkerReservation(profileID: "prefix-partition", promptTokenIDs: [1, 2, 3],
                stopTokenIDs: [], outputCount: 1, chunkSize: 1, deadlineUptimeNanoseconds: 900,
                capacityLimitBytes: 100, sampling: nil, prefixCache: carried, route: .decodingRankAlone)
            let frame = ClusterWorkerCommandFrame(membershipEpoch: epoch, sequence: 2,
                requestID: request, command: .reserve(reservation))
            let owner = try OwnerWire.command(frame, lease: UUID(), incarnation: UUID(), sequence: 3,
                now: 100, deliveryDeadline: 500)
            let record = try owner.encoded(commandStream: true)
            #expect(String(decoding: record, as: UTF8.self).contains("prefixCache") == (carried != nil))
            #expect(!String(decoding: record, as: UTF8.self).contains(salt))
            let ownerLocal = try OwnerWire.decode(record, commandStream: true).localCommand(now: 200, lifetimeDeadline: 1500)
            guard case .reserve(let local) = ownerLocal.command else { Issue.record("Owner lost reserve"); return }
            #expect(local.prefixCache == carried && local.route == .decodingRankAlone)
            #expect(local.deadlineUptimeNanoseconds == 1000)
            let link = try ClusterLinkWorkerWire.command(.reserve(reservation), requestID: request,
                epoch: epoch, session: session, sequence: 4, now: 100, deliveryDeadline: 500)
            #expect(!String(decoding: try link.encoded(), as: UTF8.self).contains(salt))
            let linkLocal = try ClusterLinkWorkerWire.decode(try link.encoded()).localCommand(now: 200)
            guard case .reserve(let peer) = linkLocal.command else { Issue.record("Link lost reserve"); return }
            #expect(peer.prefixCache == carried && peer.route == .decodingRankAlone)
            #expect(peer.deadlineUptimeNanoseconds == 1000)
        }
    }
}
