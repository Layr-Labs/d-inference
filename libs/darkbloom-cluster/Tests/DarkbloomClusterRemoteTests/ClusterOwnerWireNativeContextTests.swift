import Foundation
import XCTest
import DarkbloomClusterProtocol
@testable import DarkbloomClusterRemote

/// Candidate 33 (2026-10-22): a ~256K-token reservation never reached rank 0. Rank 0 is reached through its Mac's
/// worker owner (`ClusterRemoteWorkerEndpoint` -> owner wire -> `ClusterWorkerOwnerService` -> the worker's pipe),
/// and the endpoint's command queue held at most 1 MiB, so the reservation's JSON (~1.7 MB) was refused and the
/// leader ended the pair. Every hop now admits the largest command the codec admits: these checks carry a
/// 1,048,575-token reservation with the largest token IDs through the owner wire record and its pipe framing.
final class ClusterOwnerWireNativeContextTests: XCTestCase {
    static let epoch = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let lease = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let incarnation = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let request = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!

    func testANativeContextReservationCrossesTheOwnerWireAndItsPipe() throws {
        let now = DispatchTime.now().uptimeNanoseconds
        let prompt = Array(repeating: ClusterWorkerLimits.vocabularySize - 1, count: ClusterWorkerLimits.wireContextTokens - 1)
        let reservation = ClusterWorkerReservation(profileID: "native-context", promptTokenIDs: prompt,
            stopTokenIDs: Array(ClusterWorkerLimits.vocabularySize - 256 ..< ClusterWorkerLimits.vocabularySize),
            outputCount: 1, chunkSize: 2048, deadlineUptimeNanoseconds: now + 600_000_000_000,
            capacityLimitBytes: 1 << 40, sampling: nil)
        let frame = ClusterWorkerCommandFrame(membershipEpoch: Self.epoch, sequence: UInt64(Int64.max) - 1,
            requestID: Self.request, command: .reserve(reservation))
        let command = try ClusterWorkerCodec.encode(frame)
        XCTAssertLessThanOrEqual(command.count, ClusterWorkerLimits.commandBytes)
        // An empty owner queue takes it, with room for small commands beside it.
        XCTAssertLessThanOrEqual(command.count + 1024 * 1024, ClusterWorkerLimits.queuedCommandBytes)
        let wire = try OwnerWire.command(frame, lease: Self.lease, incarnation: Self.incarnation, sequence: 7,
            now: now, deliveryDeadline: now + 30_000_000_000)
        let record = try wire.encoded(commandStream: true)
        XCTAssertLessThanOrEqual(record.count, ClusterWorkerLimits.envelopeBytes)
        // The owner reads it from its pipe in bounded chunks, as one record.
        var lines = ClusterWorkerLineDecoder(commandStream: true), records: [Data] = []
        for start in stride(from: 0, to: record.count, by: ClusterWorkerLineDecoder.readChunkBytes) {
            records += try lines.append(record.subdata(in: start ..< min(record.count, start + ClusterWorkerLineDecoder.readChunkBytes)))
        }
        XCTAssertEqual(records, [record])
        let received = try OwnerWire.decode(record, commandStream: true)
        let local = try received.localCommand(now: now, lifetimeDeadline: now + 60_000_000_000)
        guard case .reserve(let arrived) = local.command else { return XCTFail("The reservation did not arrive as one") }
        XCTAssertEqual(arrived.promptTokenIDs, prompt)
        XCTAssertEqual(arrived.stopTokenIDs, reservation.stopTokenIDs)
    }

    func testEveryHopAdmitsTheLargestCommand() {
        XCTAssertGreaterThanOrEqual(ClusterWorkerLimits.envelopeBytes, ClusterWorkerLimits.mediaCommandBytes + 64 * 1024)
        XCTAssertGreaterThanOrEqual(ClusterWorkerLimits.queuedCommandBytes, ClusterWorkerLimits.mediaCommandBytes)
        XCTAssertGreaterThanOrEqual(ClusterLinkWorkerWire.maximumBytes, (ClusterWorkerLimits.commandBytes + 2) / 3 * 4 + 4096)
        XCTAssertGreaterThanOrEqual(ClusterLinkControlLimits().maximumBodyBytes, ClusterLinkWorkerWire.maximumBytes + 2)
    }
}
