import Foundation
import Testing
@testable import ProviderCore

/// UNRUN drafts. Required metadata/helper inputs fail explicitly when opted in;
/// no optional divergence fixture, fabricated grant or injected child completion.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_GLM_METADATA_BINDING_REQUIRED"] == "1"))
struct GLM5NextCalibrationDispatchRunTests {
    typealias F = GLM5NextCalibrationDispatchRunFixture
    typealias W = GLM5NextCalibrationDispatchWire
    final class Pause: @unchecked Sendable {
        let arrived = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var entered = false
        func stop() throws {
            try lock.withLock { try #require(!entered); entered = true }
            arrived.signal()
            try #require(released.wait(timeout: .now() + 1.5) == .success, "Controlled CPU pause expired")
        }
        func awaitArrival() throws {
            try #require(arrived.wait(timeout: .now() + 6) == .success, "Driver never reached actual boundary")
        }
        func resume() { released.signal() }
    }
    @Test func actualBothNativeCommitsRelayChildrenReportsExitsAndDurableFencesComplete() throws {
        let f = try F(); defer { f.cleanup() }
        f.start()
        try f.requireSuccess(f.join())
    }
    @Test func authenticatedAckQueuedBeforePeerCloseStillRequiresAndGetsAppConsumption() throws {
        let pause = Pause(); defer { pause.resume() }
        let f = try F { rank, event, _ in
            if rank == 1, case .beforeTerminalConsume = event { try pause.stop() }
        }
        defer { f.cleanup() }
        f.start(); try pause.awaitArrival()
        #expect(f.nodes[1].terminalObservation.received)
        #expect(!f.nodes[1].terminalObservation.consumed)
        try f.wait({ f.ledger.result(0) != nil }, seconds: 1)
        try f.wait({ f.nodes[1].terminalObservation.peerClosed }, seconds: 0.3)
        #expect(!f.nodes[1].terminalObservation.poisoned)
        #expect(f.ledger.result(1) == nil)
        #expect(FileManager.default.fileExists(atPath: f.pending(1).path))
        pause.resume()
        try f.requireSuccess(f.join())
        #expect(f.nodes[1].terminalObservation.consumed)
    }
    @Test func expectedCloseDuringActualArchiveSyncCannotRetroactivelyCancelRetiredOutcome() throws {
        let pause = Pause(); defer { pause.resume() }
        let f = try F { rank, event, _ in
            if rank == 1, case .archiveSynced = event { try pause.stop() }
        }
        defer { f.cleanup() }
        f.start(); try pause.awaitArrival()
        #expect(f.nodes[1].terminalObservation.consumed)
        let archive = f.fences[1].appendingPathComponent(f.session.uuidString.lowercased() + ".finite-result.json")
        #expect(FileManager.default.fileExists(atPath: archive.path)) // actual write/fsync completed
        #expect(FileManager.default.fileExists(atPath: f.pending(1).path)) // unlink not bypassed
        try f.wait({ f.ledger.result(0) != nil }, seconds: 1)
        try f.wait({ f.nodes[1].terminalObservation.peerClosed }, seconds: 0.3)
        #expect(f.ledger.owner(1)?.status().cancelled == false)
        pause.resume()
        try f.requireSuccess(f.join())
    }
    @Test func genuineDisconnectBeforeTerminalPoisonsAndKeepsPairQuarantine() throws {
        let f = try F { rank, event, node in
            if rank == 1, case .bootstrapPublished(0) = event { node.close() }
        }
        defer { f.cleanup() }
        f.start()
        try f.wait({ f.ledger.result(0) != nil && f.ledger.result(1) != nil }, seconds: 8)
        for rank in 0...1 {
            guard case .failure? = f.ledger.result(rank) else { Issue.record("Operational disconnect returned a result"); continue }
            #expect(f.nodes[rank].terminalObservation.poisoned)
            #expect(!f.nodes[rank].terminalObservation.consumed)
            #expect(FileManager.default.fileExists(atPath: f.pending(rank).path))
            let owner = try #require(f.ledger.owner(rank))
            #expect(owner.status().journalResolved)
            if owner.status().observedExit { #expect(owner.actualExit()?.localJournalResolved == true) }
            #expect(!FileManager.default.fileExists(atPath: f.fences[rank].appendingPathComponent(f.session.uuidString.lowercased() + ".finite-result.json").path))
        }
    }
    @Test func outOfPhaseAuthenticatedCommitAckRefusesBeforeEitherChildLaunch() throws {
        let f = try F { rank, event, node in
            if rank == 0, case .committed = event {
                // Send actual encrypted, sequenced but out-of-phase content.
                // The other real driver is waiting for .commit, not this ack.
                try node.send(.commitAck, W.canonical(W.Digest(sha256: String(repeating: "0", count: 64))),
                    deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000)
            }
        }
        defer { f.cleanup() }
        f.start()
        try f.wait({ f.ledger.result(0) != nil && f.ledger.result(1) != nil }, seconds: 6)
        for rank in 0...1 {
            guard case .failure? = f.ledger.result(rank) else { Issue.record("Out-of-phase commit acknowledgment admitted"); continue }
            #expect(!FileManager.default.fileExists(atPath: f.seed.base.model.appendingPathComponent("dispatch-start-\(rank)").path))
            if let owner = f.ledger.owner(rank) {
                #expect(!owner.status().launchAttempted && !owner.status().observedExit && owner.status().journalResolved)
            }
        }
    }
    @Test func observerCannotInjectOperationalSendAfterTerminalArming() throws {
        let f = try F { rank, event, node in
            if rank == 0, case .beforeTerminalConsume = event {
                // Arming closes all operational send entry points, including a
                // caller attempting to supply its own terminal proof.
                try node.send(.resultAck, W.canonical(W.Digest(sha256: String(repeating: "0", count: 64))),
                    deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000)
            }
        }
        defer { f.cleanup() }
        f.start()
        try f.wait({ f.ledger.result(0) != nil && f.ledger.result(1) != nil }, seconds: 8)
        // Operational send is denied once terminal is armed. A test cannot
        // inject a terminal proof through its observer; neither fence clears.
        #expect(f.nodes[0].terminalObservation.poisoned)
        #expect(FileManager.default.fileExists(atPath: f.pending(0).path))
    }
}
