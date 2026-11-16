// Copyright © 2026 Eigen Labs.

import Foundation
import Testing

@testable import ProviderCore

/// While admission is stalled, coordinator requests queued behind it hold
/// their ciphertext. Past `CoordinatorQueueBudget` a request is refused on
/// arrival instead of buffered without bound, and the connection reader keeps
/// reading control frames.
@Suite("Serve loop coordinator queue budget", .serialized)
struct ServeLoopQueueBudgetTests {
    static let coldModel = "queue-budget-cold-fixture"

    @Test("a request past the queue budget is refused on arrival, and the budget drains")
    func requestPastBudgetIsRefusedOnArrival() async throws {
        let fixture = try await ServeLoopFixture.make(models: [ModelLoadingFixtures.model(Self.coldModel)])
        // Serial admission: a request waiting for its model load holds the FIFO.
        await fixture.loop.setColdLoadReleasesWorkFIFOForTesting(false)
        await fixture.loop.setCoordinatorQueueBudgetForTesting(requests: 2, bytes: .max)
        let task = fixture.start()
        _ = try await fixture.awaitRegistration()
        await fixture.loop.modelLoadingMarkLoading(Self.coldModel)

        try await fixture.pushChatRequest(requestId: "cold", body: Self.body(model: Self.coldModel))
        try await Self.until { await fixture.loop.modelLoadingLoadingWaiterCount(Self.coldModel) == 1 }
        try await fixture.pushChatRequest(requestId: "queued")
        let reservation = UUID().uuidString.lowercased()
        let providerKey = await fixture.loop.keyPair.publicKeyBase64
        try await fixture.mock.pushInferenceRequest(
            requestId: "over", providerPublicKeyBase64: providerKey,
            chatRequestJSON: Self.body(model: ServeLoopFixture.modelId), serviceReservationID: reservation)

        let refused = try await fixture.mock.waitForSnapshot(timeout: .seconds(15)) {
            ServeLoopFixture.terminalCount($0, requestId: "over") > 0 && !$0.serviceReservationReleases.isEmpty
        }
        let snapshot = try #require(refused)
        let error = try #require(snapshot.inferenceErrors.first { $0.requestId == "over" })
        #expect(error.failureCode == .capacity)
        #expect(error.statusCode == 429)
        #expect(error.errorReason == .queueFull)
        #expect(snapshot.serviceReservationReleases == [reservation], "the refused request's service reservation is released")
        #expect(ServeLoopFixture.terminalCount(snapshot, requestId: "queued") == 0, "still queued behind the load")
        #expect(await fixture.loop.modelLoadingLoadingWaiterCount(Self.coldModel) == 1, "the load still holds admission")
        #expect(await fixture.loop.queuedCoordinatorBytesForTesting() > 0)

        // The failed load returns the first admission; the queued request is
        // then served, and nothing stays charged.
        await fixture.loop.modelLoadingResumeLoadingWaiters(Self.coldModel, failure: "scripted")
        try await fixture.awaitSubmissions(1)
        fixture.completeSubmission(0)
        let served = try await fixture.mock.waitForSnapshot(timeout: .seconds(15)) {
            ServeLoopFixture.terminalCount($0, requestId: "queued") > 0
                && ServeLoopFixture.terminalCount($0, requestId: "cold") > 0
        }
        #expect(try #require(served).inferenceComplete.contains { $0.requestId == "queued" })
        try await Self.until { await fixture.loop.queuedCoordinatorBytesForTesting() == 0 }
        #expect(await fixture.stop(task))
    }

    private static func body(model: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model": model, "messages": [["role": "user", "content": "fixture"]],
            "max_tokens": 1, "stream": true, "reasoning_parser": "none",
        ])
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
