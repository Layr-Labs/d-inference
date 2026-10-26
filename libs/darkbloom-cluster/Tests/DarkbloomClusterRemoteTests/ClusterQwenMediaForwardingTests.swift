import Foundation
import Testing
import DarkbloomClusterProtocol
@testable import DarkbloomClusterRemote

struct ClusterQwenMediaForwardingTests {
    @Test func ownerAndLinkDeadlineTranslationPreserveTheExactMediaEnvelope() throws {
        let hash = String(repeating: "a", count: 64), bytes = Data([1, 2, 3])
        let media = ClusterQwenMedia(artifactSHA256: hash, configurationSHA256: hash,
            processorSHA256: hash, processorPolicy: .qwen35, promptLength: 3,
            promptSHA256: ClusterQwenMedia.int32SHA256([1, 2, 3]), positionIDsSHA256: hash,
            decodeDeltas: [-1], items: [.init(kind: .image, sha256: ClusterQwenMedia.sha256(bytes),
                byteCount: bytes.count, decodedPixels: 1, encoded: bytes,
                temporal: 1, height: 2, width: 2, tokenOffset: 1, tokenCount: 1, patchesSHA256: hash)])
        let epoch = UUID(), request = UUID(), session = UUID()
        for carried in [media, media.withoutEncodedBytes] {
            let reservation = ClusterWorkerReservation(profileID: "qwen-media", promptTokenIDs: [1, 2, 3],
                stopTokenIDs: [], outputCount: 1, chunkSize: 1, deadlineUptimeNanoseconds: 900,
                capacityLimitBytes: 100, sampling: nil, prefixCache: nil, qwenMedia: carried)
            let frame = ClusterWorkerCommandFrame(membershipEpoch: epoch, sequence: 2,
                requestID: request, command: .reserve(reservation))
            let owner = try OwnerWire.command(frame, lease: UUID(), incarnation: UUID(), sequence: 3,
                now: 100, deliveryDeadline: 500)
            let ownerDecoded = try OwnerWire.decode(owner.encoded(commandStream: true), commandStream: true)
            let ownerLocal = try ownerDecoded.localCommand(now: 200, lifetimeDeadline: 1500)
            guard case .reserve(let local) = ownerLocal.command else { Issue.record("Owner lost reserve"); return }
            #expect(local.qwenMedia == carried)
            #expect(local.deadlineUptimeNanoseconds == 1000)
            #expect(ownerLocal.requestID == request)
            let link = try ClusterLinkWorkerWire.command(.reserve(reservation), requestID: request,
                epoch: epoch, session: session, sequence: 4, now: 100, deliveryDeadline: 500)
            let linkLocal = try link.localCommand(now: 200)
            guard case .reserve(let peer) = linkLocal.command else { Issue.record("Link lost reserve"); return }
            #expect(peer.qwenMedia == carried)
            #expect(peer.deadlineUptimeNanoseconds == 1000)
            #expect(linkLocal.requestID == request)
            #expect(linkLocal.deliveryDeadline == 600)
        }
    }
}
