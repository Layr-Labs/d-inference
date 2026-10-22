import Foundation
import Testing
@testable import ProviderCore

/// Real encrypted sockets, both real drivers and CPU children.
/// RED and GREEN must use this identical schedule-only test and fixture.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_GLM_METADATA_BINDING_REQUIRED"] == "1"))
struct GLM5NextCalibrationTerminalStatusRaceTests {
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var entered = false
        private let arrived = DispatchSemaphore(value: 0)
        private let released = DispatchSemaphore(value: 0)
        func stopOnce() throws {
            guard lock.withLock({ if entered { return false }; entered = true; return true }) else { return }
            arrived.signal()
            try #require(released.wait(timeout: .now() + 1.5) == .success,
                         "Terminal status schedule watchdog expired")
        }
        func awaitArrival() throws {
            try #require(arrived.wait(timeout: .now() + 6) == .success,
                         "Actual driver never reached terminal status schedule")
        }
        func resume() { released.signal() }
    }
    @Test func expectedCloseBetweenTerminalStatusObservationsCompletesBothRealDrivers() throws {
        let sampled = Gate(), archiveSynced = Gate()
        let f = try GLM5NextCalibrationDispatchRunFixture(afterTerminalContextSample: { rank in
            if rank == 1 { try sampled.stopOnce() }
        }) { rank, event, _ in
            if rank == 0, case .archiveSynced = event { try archiveSynced.stopOnce() }
        }
        // Release gates before cleanup can join or need the channel condition.
        defer { sampled.resume(); archiveSynced.resume(); f.cleanup() }
        f.start()
        try sampled.awaitArrival()
        try archiveSynced.awaitArrival()
        // Rank0 has durably written its actual archive but cannot close yet.
        // Rank1 holds the real condition lock AFTER computing closed == false.
        // Its reader is free to process authenticated frames and update status.
        let before = try #require(f.nodes[1].transportObservationForTests)
        try #require(before.connected && before.sessions == 1 && before.peerRestarts == 0)
        try #require(f.ledger.result(1) == nil)
        try #require(FileManager.default.fileExists(atPath: f.pending(1).path))
        for rank in 0...1 {
            let owner = try #require(f.ledger.owner(rank))
            try #require(owner.actualExit()?.termination == .exited(0))
            try #require(owner.actualExit()?.localJournalResolved == true)
        }
        archiveSynced.resume()
        // Observe transport directly: the ordered disconnect event waits for
        // rank1's held condition lock. Never call terminalObservation until release.
        try f.wait({
            guard let status = f.nodes[1].transportObservationForTests else { return false }
            return !status.connected && status.lastDisconnect == .peerClosed
        }, seconds: 0.5)
        try f.wait({ f.ledger.result(0) != nil }, seconds: 0.5)
        let after = try #require(f.nodes[1].transportObservationForTests)
        try #require(after.sessions == before.sessions && after.peerIncarnation == before.peerIncarnation
                     && after.peerRestarts == before.peerRestarts)
        sampled.resume()
        // RED: old guard re-reads connected == false with closed == false and
        // throws "terminal transport lost". GREEN: one stored observation passes;
        // all later checks still validate the actual closed peer and exact ack.
        try f.requireSuccess(f.join())
        for rank in 0...1 {
            #expect(f.nodes[rank].terminalObservation.consumed)
            #expect(!f.nodes[rank].terminalObservation.poisoned)
            #expect(!f.nodes[rank].queuedResultAcknowledgment)
        }
    }
}
