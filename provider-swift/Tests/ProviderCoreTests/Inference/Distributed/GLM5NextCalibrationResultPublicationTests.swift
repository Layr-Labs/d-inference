import Foundation
import Testing
@testable import ProviderCore

/// UNRUN actual-driver schedule. No injected Completed, authenticated receive,
/// retirement or child completion; all outcome evidence is produced normally.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_GLM_METADATA_BINDING_REQUIRED"] == "1"))
struct GLM5NextCalibrationResultPublicationTests {
    @Test func peerAckQueuedAfterLastLocalResultCompletesBothRealDrivers() throws {
        typealias F = GLM5NextCalibrationDispatchRunFixture
        let peerResultValidated = DispatchSemaphore(value: 0)
        let localResultPublished = GLM5NextCalibrationDispatchRunTests.Pause()
        let f = try F(holdReportForRank: 1) { rank, event, _ in
            guard rank == 1 else { return }
            switch event {
            case .peerResultValidated: peerResultValidated.signal()
            case .localResultPublished: try localResultPublished.stop()
            default: break
            }
        }
        // Release any driver pause before cancellation/endpoint cleanup joins.
        defer { localResultPublished.resume(); f.cleanup() }
        f.start()

        // Rank0's real result was validated while rank1's actual CPU child is
        // held alive before emitting its report or exiting. No guessed sleep.
        try #require(peerResultValidated.wait(timeout: .now() + 6) == .success,
                     "Rank1 never validated the actual peer result")
        try f.wait({ FileManager.default.fileExists(atPath: f.reportHeld(1).path) }, seconds: 1)
        let owner = try #require(f.ledger.owner(1))
        try #require(owner.actualExit() == nil)
        try #require(owner.status().bootstrapCompleted && !owner.status().observedExit)
        try #require(f.ledger.result(1) == nil)
        try f.releaseReport(1)

        // The real child now reports/exits and rank1 sends/records its result.
        // Hold precisely before the old unconditional running-phase receive.
        try localResultPublished.awaitArrival()
        try #require(owner.actualExit()?.termination == .exited(0))
        try #require(owner.actualExit()?.localJournalResolved == true)
        try f.wait({ f.nodes[1].queuedResultAcknowledgment }, seconds: 0.6)
        try #require(!f.nodes[1].terminalObservation.consumed)
        try #require(!f.nodes[1].terminalObservation.poisoned)
        try #require(f.ledger.result(1) == nil)
        try #require(FileManager.default.fileExists(atPath: f.pending(1).path))
        localResultPublished.resume()

        // Old loop: valid ack hits the running switch's default and join throws.
        // Parent break: strict terminal arming validates/consumes the same queue.
        // Both runs must use this identical test and exact newly compiled helper.
        try f.requireSuccess(f.join())
        for rank in 0...1 {
            #expect(f.nodes[rank].terminalObservation.consumed)
            #expect(!f.nodes[rank].queuedResultAcknowledgment)
            #expect(!FileManager.default.fileExists(atPath: f.pending(rank).path))
        }
    }
}
