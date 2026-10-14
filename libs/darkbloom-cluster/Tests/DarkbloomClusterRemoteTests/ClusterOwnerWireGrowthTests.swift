import Darwin
import Foundation
import XCTest
import DarkbloomClusterProtocol
@testable import DarkbloomClusterRemote

/// Round 6c, case 5 (27B, 15 minutes of mixed load): rank 0 (`start --local`) grew about 20.6 MiB a minute and its Mac's
/// worker owner about 22.7 MiB a minute. Rank 0 reaches its own Mac's worker through the worker owner: every decoded
/// token is a command (`tokenDecision`) rank 0 encodes on its owner writer and the owner decodes, then an event
/// (`committedToken`) the owner encodes and rank 0 decodes. Those owner wire records are made with JSONSerialization on
/// dispatch queues whose loops never return, so nothing drains what JSONSerialization autoreleases: rank 0's heap held
/// 43,609 4 KB `NSConcreteData` and as many `_NSJSONWriter` buffers after 11 minutes. These checks run the same records
/// on a thread that never drains a pool and hold the bytes in use flat per token. No worker, no model, no cable.
final class ClusterOwnerWireGrowthTests: XCTestCase {
    static func bytesInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    /// Runs `body` on a detached thread that never drains an autorelease pool (like the owner loops) and returns the
    /// growth of the bytes in use across `count` passes after one warm pass.
    static func growthOnUndrainedThread(count: Int, _ body: @escaping @Sendable (Int) throws -> Void) throws -> Int {
        let finished = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var grown = 0
        nonisolated(unsafe) var failure: Error?
        Thread.detachNewThread {
            defer { finished.signal() }
            do {
                try body(0)
                let before = bytesInUse()
                for index in 1...count { try body(index) }
                grown = bytesInUse() - before
            } catch { failure = error }
        }
        finished.wait()
        if let failure { throw failure }
        return grown
    }

    static let epoch = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let lease = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let incarnation = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let request = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!

    /// One decoded token through the owner route: rank 0 encodes the command, the owner decodes it; the owner encodes
    /// the committed-token event, rank 0 decodes it.
    static func oneToken(_ index: Int) throws {
        let ordinal = index % 4_000 + 1  // inside the protocol's output bound
        let command = ClusterWorkerCommandFrame(membershipEpoch: epoch, sequence: UInt64(index + 2), requestID: request,
                                                command: .tokenDecision(ordinal: ordinal, decision: .proceed))
        let now = DispatchTime.now().uptimeNanoseconds
        let outgoing = try OwnerWire.command(command, lease: lease, incarnation: incarnation, sequence: UInt64(index + 1),
                                             now: now, deliveryDeadline: now + 5_000_000_000)
        let received = try OwnerWire.decode(try outgoing.encoded(commandStream: true), commandStream: true)
        XCTAssertEqual(received.kind, "command")
        var event = OwnerWire(kind: "event", epoch: epoch, lease: lease, incarnation: incarnation, sequence: UInt64(index + 1))
        event.payload = try ClusterWorkerCodec.encode(ClusterWorkerEventFrame(membershipEpoch: epoch, sequence: UInt64(index + 2),
            requestID: request, event: .committedToken(ordinal: ordinal, tokenID: 7, committedTokens: ordinal)))
        let back = try OwnerWire.decode(try event.encoded(commandStream: false), commandStream: false)
        XCTAssertEqual(back.kind, "event")
    }

    func testOwnerWireTokensLeaveNothingOnAThreadThatNeverDrains() throws {
        let tokens = 5_000
        let grown = try Self.growthOnUndrainedThread(count: tokens) { index in try Self.oneToken(index) }
        // Before the fix: about 25 KiB per token (six JSON records' writers, 4 KB buffers and parsed dictionaries).
        XCTAssertLessThan(grown, 8 * 1024 * 1024,
            "\(grown / 1024) KiB still in use after \(tokens) tokens through the owner wire (\(grown / tokens) bytes a token)")
    }

    /// A request's other owner records (reserve with its prompt, renewals) take the same route.
    func testOwnerWireReserveAndRenewalLeaveNothingOnAThreadThatNeverDrains() throws {
        let requests = 1_000
        let prompt = Array(0..<512)
        let grown = try Self.growthOnUndrainedThread(count: requests) { index in
            let epoch = Self.epoch, lease = Self.lease, incarnation = Self.incarnation
            let now = DispatchTime.now().uptimeNanoseconds
            let reservation = ClusterWorkerReservation(profileID: "invented", promptTokenIDs: prompt, stopTokenIDs: [2],
                outputCount: 64, chunkSize: 256, deadlineUptimeNanoseconds: now + 60_000_000_000, capacityLimitBytes: 1 << 30, sampling: nil)
            let reserve = try OwnerWire.command(ClusterWorkerCommandFrame(membershipEpoch: epoch, sequence: UInt64(index + 1),
                requestID: UUID(), command: .reserve(reservation)), lease: lease, incarnation: incarnation,
                sequence: UInt64(2 * index + 1), now: now, deliveryDeadline: now + 5_000_000_000)
            _ = try OwnerWire.decode(try reserve.encoded(commandStream: true), commandStream: true)
            var renew = OwnerWire(kind: "renew", epoch: epoch, lease: lease, incarnation: incarnation, sequence: UInt64(2 * index + 2))
            renew.remaining = ClusterWorkerLease.ttlNanoseconds
            _ = try OwnerWire.decode(try renew.encoded(commandStream: true), commandStream: true)
        }
        XCTAssertLessThan(grown, 8 * 1024 * 1024,
            "\(grown / 1024) KiB still in use after \(requests) reserve + renewal records (\(grown / requests) bytes a request)")
    }
}
