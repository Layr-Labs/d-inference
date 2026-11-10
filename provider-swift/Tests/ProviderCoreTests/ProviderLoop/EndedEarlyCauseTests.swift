import Foundation
import Testing

@testable import ProviderCore

#if DEBUG
/// `darkbloom status` says what stopped each request that ended early and whether the coordinator pays: the
/// coordinator's cancel with its reason (from coordinators that send one), a cancel without one, this Mac's dropped
/// connection, or this Mac's own stop. A cancel that lands after the engine finished the answer stopped nothing. The
/// requests travel the encrypted coordinator path to the Me-first harness's engine, a queue with no tensors.
@Suite("Requests that ended early, by cause", .serialized, .timeLimit(.minutes(1)))
struct EndedEarlyCauseTests {
    /// Each request streams one token, then something stops it; each is counted under its own cause.
    @Test func eachCauseIsCountedUnderItsOwnName() async throws {
        let h = try await MeFirstGiveWayTests.harness(meFirst: false, slots: 1)
        var index = 0
        func streamOneToken(_ id: String) async throws {
            try await h.network(id)
            h.engine.token(index)
            index += 1
            try #require(await waitUntil { h.outbound.contentFrames(for: id, decryptingWith: h.sender) == 1 },
                         "\(id) sent output")
        }
        func endsWithItsPartialAnswer(_ id: String) async throws {
            try #require(await waitUntil { h.outbound.completed(for: id) }, "\(id) ended with its partial usage")
        }

        try await streamOneToken("requester-left")
        await h.loop.routeCoordinatorCancel("requester-left", reason: .init(code: "client_gone_post", paid: true))
        try await endsWithItsPartialAnswer("requester-left")

        try await streamOneToken("hedge-lost")
        await h.loop.routeCoordinatorCancel("hedge-lost", reason: .init(code: "hedge_loser", paid: false))
        try await endsWithItsPartialAnswer("hedge-lost")

        try await streamOneToken("too-late")
        await h.loop.routeCoordinatorCancel("too-late", reason: .init(code: "late_content", paid: false))
        try await endsWithItsPartialAnswer("too-late")

        try await streamOneToken("pair-ended")
        await h.loop.routeCoordinatorCancel("pair-ended", reason: .init(code: "pair_ended", paid: false))
        try await endsWithItsPartialAnswer("pair-ended")

        try await streamOneToken("no-reason")
        await h.loop.routeCoordinatorCancel("no-reason")
        try await endsWithItsPartialAnswer("no-reason")

        try await streamOneToken("add-on-hold")
        await h.loop.handleCancellation(requestId: "add-on-hold", receivedFromCoordinator: false)
        try await endsWithItsPartialAnswer("add-on-hold")

        try await streamOneToken("dropped")
        await h.loop.cancelAllInflight(cause: .connectionLost)
        try await endsWithItsPartialAnswer("dropped")

        var expected = EndedEarlyCounts()
        expected.requesterLeftPaid = 1
        expected.anotherMacFirst = 1
        expected.startedTooLate = 1
        expected.otherUnpaid = 1
        expected.noReason = 1
        expected.stoppedOnThisMac = 1
        expected.connectionLost = 1
        let stats = await h.loop.stats
        #expect(stats.endedEarly == expected)
        #expect(stats.cancellationsPartialComplete == 7)
        #expect(stats.requestsServed == 7)
        #expect(await h.loop.coordinatorCancelReasons.isEmpty, "every reason was applied")
        await h.remove()
    }

    /// The engine finished the answer; the requester's cancel arrived while the loop was still sending it. The
    /// request is served whole (the coordinator pays it in full): it did not end early.
    @Test func aCancelAfterTheEngineFinishedTheAnswerEndsNothingEarly() async throws {
        let h = try await MeFirstGiveWayTests.harness(meFirst: false, slots: 1)
        let outbound = HeldFirstContentOutbound(receiver: h.sender)
        let body = try JSONSerialization.data(withJSONObject: [
            "model": MeFirstGiveWayTests.model, "messages": [["role": "user", "content": "fixture"]],
            "max_tokens": 8, "stream": true, "reasoning_parser": "none",
        ])
        let encrypted = try h.sender.encrypt(recipientPublicKey: await h.loop.keyPair.publicKeyBytes, plaintext: body)
        await h.loop.handleInferenceRequest(requestId: "whole", ciphertext: encrypted,
            senderPublicKey: h.sender.publicKeyBytes, cacheReceiptNonce: nil,
            authenticatedCacheScope: "ended-early-tenant", send: SendHandle(outbound.record))
        try #require(await waitUntil { h.engine.submittedCount == 1 }, "the request reached the engine")

        h.engine.token(0)
        try #require(await waitUntil { outbound.isHolding }, "the loop is sending the first content frame")
        h.engine.finish(0)
        try #require(await waitUntil { await h.bridge._testLivePumpCount() == 0 }, "the engine finished the answer")
        await h.loop.routeCoordinatorCancel("whole", reason: .init(code: "client_gone_post", paid: true))
        try #require(await waitUntil { await h.loop.cancellationRegistry.token(for: "whole") == nil },
                     "the cancel reached the request")
        outbound.release()

        try #require(await waitUntil { outbound.completed("whole") }, "the request completed")
        let stats = await h.loop.stats
        #expect(stats.requestsServed == 1)
        #expect(stats.cancellationsPartialComplete == 0)
        #expect(stats.endedEarly == EndedEarlyCounts())
        await h.remove()
    }
}

/// Records what the loop sends, and holds the loop inside its first content frame until released.
private final class HeldFirstContentOutbound: @unchecked Sendable {
    private let receiver: NodeKeyPair
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var messages: [OutboundMessage] = []
    private var held = false
    private var holding = false

    init(receiver: NodeKeyPair) { self.receiver = receiver }

    var isHolding: Bool { lock.withLock { holding } }

    func release() { gate.signal() }

    func completed(_ id: String) -> Bool {
        lock.withLock { messages }.contains {
            if case .inferenceComplete(let request, _, _, _, _, _) = $0 { return request == id }
            return false
        }
    }

    func record(_ message: OutboundMessage) {
        let holdHere = lock.withLock { () -> Bool in
            messages.append(message)
            guard !held, case .inferenceChunk(_, _, let encrypted?) = message,
                  let raw = try? receiver.decryptPayload(encrypted),
                  let frame = String(data: raw, encoding: .utf8), frame.contains(#""content":"a""#)
            else { return false }
            held = true
            holding = true
            return true
        }
        if holdHere { gate.wait() }
    }
}

/// Polls `condition` for up to 5 s of real time.
private func waitUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while await !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}
#endif
