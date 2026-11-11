import Foundation
import Testing

@testable import ProviderCore

#if DEBUG
/// `darkbloom status` says what stopped each request that ended early and whether the coordinator pays: the
/// coordinator's cancel with its reason (from coordinators that send one), a cancel without one, this Mac's dropped
/// connection, or this Mac's own stop. A paid stop that lands after the engine finished the answer is paid as
/// delivered and not counted; an unpaid one still counts. The requests travel the encrypted coordinator path to the
/// Me-first harness's engine, a queue with no tensors.
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
        func endsWithItsPartialAnswer(_ id: String, countedIn cause: KeyPath<EndedEarlyCounts, UInt64>) async throws {
            try #require(await waitUntil { h.outbound.completed(for: id) }, "\(id) ended with its partial usage")
            #expect(await h.loop.stats.endedEarly[keyPath: cause] == 1, "\(id) is counted under its own cause")
        }

        try await streamOneToken("requester-left")
        await h.loop.routeCoordinatorCancel("requester-left", reason: .init(code: "client_gone_post", paid: true))
        try await endsWithItsPartialAnswer("requester-left", countedIn: \.requesterLeftPaid)

        try await streamOneToken("hedge-lost")
        await h.loop.routeCoordinatorCancel("hedge-lost", reason: .init(code: "hedge_loser", paid: false))
        try await endsWithItsPartialAnswer("hedge-lost", countedIn: \.anotherMacFirst)

        try await streamOneToken("too-late")
        await h.loop.routeCoordinatorCancel("too-late", reason: .init(code: "late_content", paid: false))
        try await endsWithItsPartialAnswer("too-late", countedIn: \.startedTooLate)

        try await streamOneToken("pair-ended")
        await h.loop.routeCoordinatorCancel("pair-ended", reason: .init(code: "pair_ended", paid: false))
        try await endsWithItsPartialAnswer("pair-ended", countedIn: \.otherUnpaid)

        try await streamOneToken("no-reason")
        await h.loop.routeCoordinatorCancel("no-reason")
        try await endsWithItsPartialAnswer("no-reason", countedIn: \.noReason)

        try await streamOneToken("add-on-hold")
        await h.loop.handleCancellation(
            requestId: "add-on-hold", receivedFromCoordinator: false, localCause: .stoppedOnThisMac)
        try await endsWithItsPartialAnswer("add-on-hold", countedIn: \.stoppedOnThisMac)

        try await streamOneToken("dropped")
        await h.loop.handleCoordinatorDisconnected()
        try await endsWithItsPartialAnswer("dropped", countedIn: \.connectionLost)

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

    /// The engine finished the answer; the requester's paid cancel arrived while the loop was still sending it.
    /// The coordinator pays it as delivered: it is not counted as ended early. The same for this Mac's own stop.
    @Test func aPaidStopAfterTheEngineFinishedTheAnswerEndsNothingEarly() async throws {
        let left = try await finishedThenStopped("whole") { h in
            await h.loop.routeCoordinatorCancel("whole", reason: .init(code: "client_gone_post", paid: true))
        }
        #expect(left.requestsServed == 1)
        #expect(left.cancellationsPartialComplete == 0)
        #expect(left.endedEarly == EndedEarlyCounts())
        let own = try await finishedThenStopped("own-stop") { h in
            await h.loop.handleCancellation(
                requestId: "own-stop", receivedFromCoordinator: false, localCause: .stoppedOnThisMac)
        }
        #expect(own.cancellationsPartialComplete == 0 && own.endedEarly == EndedEarlyCounts())
    }

    /// Every unpaid stop counts under its own cause whenever it lands: a finished engine is not a delivered
    /// answer, and the coordinator pays nothing for it. A cancel without a reason may be unpaid, so it counts too.
    @Test func anUnpaidStopAfterTheEngineFinishedCountsUnderItsOwnCause() async throws {
        let unpaid: [(id: String, reason: CoordinatorCancelReason?, countedIn: KeyPath<EndedEarlyCounts, UInt64>)] = [
            ("hedge-lost", .init(code: "hedge_loser", paid: false), \.anotherMacFirst),
            ("too-late", .init(code: "late_content", paid: false), \.startedTooLate),
            ("deadline", .init(code: "first_chunk_timeout", paid: false), \.startedTooLate),
            ("pair-ended", .init(code: "pair_ended", paid: false), \.otherUnpaid),
            ("no-reason", nil, \.noReason),
        ]
        for stop in unpaid {
            let (id, reason) = (stop.id, stop.reason)
            let stats = try await finishedThenStopped(id) { h in
                await h.loop.routeCoordinatorCancel(id, reason: reason)
            }
            #expect(stats.endedEarly[keyPath: stop.countedIn] == 1, "\(stop.id) is counted under its own cause")
            #expect(stats.endedEarly.total == 1 && stats.cancellationsPartialComplete == 1, "\(stop.id) counts once")
        }
    }

    /// A requester-left cancel is paid only with `paid`: one the coordinator no longer holds a record for (a
    /// non-streaming requester, or a cancel re-sent after the 30 s grace) is unpaid, finished engine or not.
    @Test func aRequesterLeftCancelWithoutPaidIsUnpaid() async throws {
        var counts = EndedEarlyCounts()
        counts.add(.coordinatorCancel(.init(code: "client_gone_post", paid: false)))
        counts.add(.coordinatorCancel(.init(code: "hedge_loser", paid: true)))
        var expected = EndedEarlyCounts()
        expected.otherUnpaid = 1
        expected.otherPaid = 1
        #expect(counts == expected, "only `paid` makes a cancel paid")

        let stats = try await finishedThenStopped("left-unpaid") { h in
            await h.loop.routeCoordinatorCancel("left-unpaid", reason: .init(code: "client_gone_post", paid: false))
        }
        var unpaid = EndedEarlyCounts()
        unpaid.otherUnpaid = 1
        #expect(stats.endedEarly == unpaid)
    }

    /// The connection to the coordinator dropped (`.disconnected`): the coordinator flushes an error to the
    /// requester and refunds, so the request counts as unpaid, before or after the engine finished the answer.
    @Test func aDroppedConnectionIsCountedUnpaid() async throws {
        let h = try await MeFirstGiveWayTests.harness(meFirst: false, slots: 1)
        try await h.network("streaming")
        h.engine.token(0)
        try #require(await waitUntil { h.outbound.contentFrames(for: "streaming", decryptingWith: h.sender) == 1 },
                     "streaming sent output")
        await h.loop.handleCoordinatorDisconnected()
        try #require(await waitUntil { h.outbound.completed(for: "streaming") }, "streaming ended")
        var dropped = EndedEarlyCounts()
        dropped.connectionLost = 1
        #expect(await h.loop.stats.endedEarly == dropped)
        await h.remove()

        let finished = try await finishedThenStopped("finished") { h in await h.loop.handleCoordinatorDisconnected() }
        #expect(finished.endedEarly == dropped)
    }

    /// Holds the loop inside its first content frame while the engine finishes the answer, then stops the request.
    private func finishedThenStopped(
        _ id: String, stop: (MeFirstGiveWayTests.Harness) async -> Void
    ) async throws -> AtomicProviderStats {
        let h = try await MeFirstGiveWayTests.harness(meFirst: false, slots: 1)
        let outbound = HeldFirstContentOutbound(receiver: h.sender)
        let body = try JSONSerialization.data(withJSONObject: [
            "model": MeFirstGiveWayTests.model, "messages": [["role": "user", "content": "fixture"]],
            "max_tokens": 8, "stream": true, "reasoning_parser": "none",
        ])
        let encrypted = try h.sender.encrypt(recipientPublicKey: await h.loop.keyPair.publicKeyBytes, plaintext: body)
        await h.loop.handleInferenceRequest(requestId: id, ciphertext: encrypted,
            senderPublicKey: h.sender.publicKeyBytes, cacheReceiptNonce: nil,
            authenticatedCacheScope: "ended-early-tenant", send: SendHandle(outbound.record))
        try #require(await waitUntil { h.engine.submittedCount == 1 }, "the request reached the engine")

        h.engine.token(0)
        try #require(await waitUntil { outbound.isHolding }, "the loop is sending the first content frame")
        h.engine.finish(0)
        try #require(await waitUntil { await h.bridge._testLivePumpCount() == 0 }, "the engine finished the answer")
        await stop(h)
        try #require(await waitUntil { await h.loop.cancellationRegistry.token(for: id) == nil },
                     "the stop reached the request")
        outbound.release()

        try #require(await waitUntil { outbound.completed(id) }, "the request completed")
        let stats = await h.loop.stats
        await h.remove()
        return stats
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
