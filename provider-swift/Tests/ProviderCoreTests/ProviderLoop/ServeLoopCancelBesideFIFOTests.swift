// Copyright © 2026 Eigen Labs.

import Foundation
import Testing

@testable import ProviderCore

#if DEBUG
/// A coordinator cancel reaches its request's engine, and a pair's engine can
/// be held by a rank reservation for up to 30 s. While a cancel waits there,
/// the connection still answers attestation challenges and admits the next
/// request, and the cancel still lands once the engine frees.
@Suite("Serve loop cancels beside the work FIFO", .serialized)
struct ServeLoopCancelBesideFIFOTests {
    @Test("a cancel waiting on the engine holds back neither a challenge nor the next request, and still lands")
    func stalledCancelHoldsNothingBack() async throws {
        let fixture = try await ServeLoopFixture.make()
        let hold = EngineQueueHold()
        fixture.engine.setCapacityHold(hold)
        let task = fixture.start()
        let register = try await fixture.awaitRegistration()

        try await fixture.pushChatRequest(requestId: "held")
        try await fixture.awaitSubmissions(1)

        // The engine is held, as a reservation holds a pair's engine queue:
        // the cancel's engine work waits there.
        hold.hold()
        try await fixture.mock.pushCancel(requestId: "held")
        try await Self.until { hold.heldCount >= 1 }

        let nonce = "c3RhbGxlZC1jYW5jZWw="
        try await fixture.mock.pushAttestationChallenge(nonce: nonce, timestamp: "2026-11-04T18:00:00Z")
        let answered = try await fixture.mock.waitForSnapshot(timeout: .seconds(5)) {
            $0.attestationResponses.contains { $0.nonce == nonce }
        }
        #expect(answered != nil, "the challenge waited behind the cancel")
        #expect(answered?.attestationResponses.first { $0.nonce == nonce }?.publicKey == register.publicKey)

        try await fixture.pushChatRequest(requestId: "next")
        let accepted = try await fixture.mock.waitForSnapshot(timeout: .seconds(5)) {
            $0.inferenceAccepted.contains { $0.requestId == "next" }
        }
        #expect(accepted != nil, "the next request waited behind the cancel")
        #expect(fixture.engine.cancelledRequestIDs.isEmpty, "the cancel reached the engine while it was held")

        // The engine frees: the cancel lands, with its one terminal.
        hold.release()
        try await fixture.awaitEngineCancellations(1)
        let ended = try await fixture.mock.waitForSnapshot(timeout: .seconds(15)) {
            ServeLoopFixture.terminalCount($0, requestId: "held") > 0
        }
        let snapshot = try #require(ended)
        #expect(ServeLoopFixture.terminalCount(snapshot, requestId: "held") == 1)
        #expect(snapshot.inferenceErrors.first { $0.requestId == "held" }?.failureCode == .cancelled)

        // The next request is served.
        try await fixture.awaitSubmissions(2)
        fixture.completeSubmission(1)
        let served = try await fixture.mock.waitForSnapshot(timeout: .seconds(10)) {
            $0.inferenceComplete.contains { $0.requestId == "next" }
        }
        #expect(served != nil)
        #expect(ServeLoopFixture.terminalCount(try #require(served), requestId: "next") == 1)
        #expect(await fixture.stop(task))
    }

    private static func until(
        timeout: Duration = .seconds(10), _ condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition())
    }
}
#endif
