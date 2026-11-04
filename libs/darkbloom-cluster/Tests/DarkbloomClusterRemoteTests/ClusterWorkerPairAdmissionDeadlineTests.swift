import Foundation
import XCTest
@testable import DarkbloomClusterProcess
import DarkbloomClusterProtocol

/// One rank of a pair, scripted in this process: no worker, model or GPU. It
/// answers a reservation at once, or only when the test gives the answer (a
/// rank whose loop is inside a long step), runs a started request on rank 0
/// one committed token per decision, `tokenNanoseconds` apart (a decode step),
/// and gives back a reservation it is told to cancel. It records every
/// reservation with its delivery deadline, every cancel and every fence.
private final class ScriptedRank: ClusterWorkerEndpoint, @unchecked Sendable {
    static let identity = ClusterWorkerIdentity(membershipEpoch: UUID(), modelID: "fabricated-lanes",
        artifactSHA256: String(repeating: "a", count: 64), configurationSHA256: String(repeating: "b", count: 64),
        peers: [.init(id: "peer0", buildSHA256: String(repeating: "c", count: 64)),
                .init(id: "peer1", buildSHA256: String(repeating: "d", count: 64))])
    static let profile = ClusterWorkerProfile(id: "fabricated-lanes", vocabularySize: 100, maximumPromptTokens: 64,
        maximumOutputTokens: 128, maximumChunkTokens: 16, maximumContextTokens: 256)
    static let plan = String(repeating: "e", count: 64)
    let expectedIdentity = ScriptedRank.identity
    let expectedProfile = ScriptedRank.profile
    let executionPlanSHA256 = ScriptedRank.plan
    let rank: Int
    var readiness: ClusterWorkerReady? { lock.withLock { fenceReasons.isEmpty && !closed ? ready : nil } }
    var localLifetimeDeadlineUptimeNanoseconds: UInt64 { UInt64.max }
    var nativeCleanupObserved: Bool { lock.withLock { ended } }
    private let ready: ClusterWorkerReady
    private let tokenNanoseconds: UInt64
    private let lock = NSLock()
    private let arrived = DispatchSemaphore(value: 0)
    private var events: [ClusterWorkerEventFrame] = []
    private var sequence: UInt64 = 0
    private var handler: (@Sendable () -> Void)?
    private var ended = false, closed = false, holdNext = false, closeWhenAsked = false, holdStart = false
    private var held = Set<UUID>()
    private var requests: [UUID: (prompt: Int, output: Int)] = [:]
    private var sent: [(id: UUID, delivery: UInt64)] = []
    private var cancelled: [UUID] = []
    private var commandCount = 0
    private var fenceReasons: [String] = []

    var reservations: [(id: UUID, delivery: UInt64)] { lock.withLock { sent } }
    var cancels: [UUID] { lock.withLock { cancelled } }
    var commands: Int { lock.withLock { commandCount } }
    var fences: [String] { lock.withLock { fenceReasons } }

    init(rank: Int, tokenNanoseconds: UInt64 = 0) {
        self.rank = rank; self.tokenNanoseconds = tokenNanoseconds
        ready = ClusterWorkerReady(identity: Self.identity, rank: rank, profile: Self.profile,
            executionPlanSHA256: Self.plan, requestCapacityBytes: 1 << 20)
        emit(nil, .ready(ready))
    }

    /// The next reservation is answered only by `answerHeld`.
    func holdNextAdmission() { lock.withLock { holdNext = true } }
    func answerHeld(_ id: UUID) {
        if lock.withLock({ held.remove(id) != nil }) { emit(id, .admitted(reservedBytes: 64)) }
    }
    /// The link to this rank closes for good when it is next asked anything.
    func closeLinkWhenAsked() { lock.withLock { closeWhenAsked = true } }
    /// Rank 0 starts the next request but commits no token for it until it is
    /// cancelled: a rank still inside that request's long prompt.
    func holdNextStart() { lock.withLock { holdStart = true } }

    private func emit(_ requestID: UUID?, _ event: ClusterWorkerEvent) {
        lock.withLock {
            events.append(.init(membershipEpoch: Self.identity.membershipEpoch, sequence: sequence,
                requestID: requestID, event: event))
            sequence += 1
        }
        arrived.signal()
    }

    private func emitToken(_ id: UUID, ordinal: Int) {
        let prompt = lock.withLock { requests[id]?.prompt ?? 0 }
        let token = ClusterWorkerEvent.committedToken(ordinal: ordinal, tokenID: 10 + ordinal % 50,
            committedTokens: prompt + ordinal)
        guard tokenNanoseconds > 0 else { return emit(id, token) }
        DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(tokenNanoseconds))) { self.emit(id, token) }
    }

    func setInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
        let now = lock.withLock { () -> Bool in self.handler = handler; return closed || !fenceReasons.isEmpty }
        if now { DispatchQueue.global().async(execute: handler) }
    }

    func sendWorkerCommand(_ command: ClusterWorkerCommand, requestID: UUID?, deadline: UInt64) throws {
        let lost = lock.withLock { () -> (@Sendable () -> Void)? in
            commandCount += 1
            guard closeWhenAsked && !closed else { return nil }
            closed = true; return handler
        }
        if let lost { DispatchQueue.global().async(execute: lost) }
        let answerLater = try lock.withLock { () -> Bool in
            guard fenceReasons.isEmpty, !closed, !ended, deadline > DispatchTime.now().uptimeNanoseconds else {
                throw ClusterWorkerOwnerError.closed
            }
            switch command {
            case .reserve(let value):
                sent.append((requestID!, deadline))
                requests[requestID!] = (value.promptTokenIDs.count, value.outputCount)
                if holdNext { holdNext = false; held.insert(requestID!); return true }
            case .start where rank == 0 && holdStart: holdStart = false; return true
            case .cancel: cancelled.append(requestID!)
            default: break
            }
            return false
        }
        switch command {
        case .reserve where !answerLater: emit(requestID, .admitted(reservedBytes: 64))
        case .start where rank == 0 && !answerLater: emitToken(requestID!, ordinal: 0)
        case .start where rank == 0: break
        case .start: emit(requestID, .finished(.length)); emit(requestID, .retired(.clean))
        case .tokenDecision(let ordinal, _):
            if ordinal + 1 >= lock.withLock({ requests[requestID!]?.output ?? 0 }) {
                emit(requestID, .finished(.length)); emit(requestID, .retired(.clean))
            } else { emitToken(requestID!, ordinal: ordinal + 1) }
        case .cancel: emit(requestID, .retired(.cancelled))
        case .shutdown: emit(nil, .shutdownComplete); lock.withLock { ended = true }
        default: break
        }
    }

    func receiveWorkerEvent(until deadline: UInt64, cancelled: () -> Bool) throws -> ClusterWorkerEventFrame {
        while true {
            if cancelled() { throw ClusterWorkerOwnerError.cancelled }
            if let next = lock.withLock({ events.isEmpty ? nil : events.removeFirst() }) { return next }
            if lock.withLock({ closed || !fenceReasons.isEmpty }) { throw ClusterWorkerOwnerError.closed }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw ClusterWorkerOwnerError.deadline }
            _ = arrived.wait(timeout: .init(uptimeNanoseconds: min(deadline, now + 5_000_000)))
        }
    }

    func requestNativeCleanup() { requestNativeCleanup(reason: "fenced without a cause") }
    func requestNativeCleanup(reason: String) {
        let notify = lock.withLock { () -> (@Sendable () -> Void)? in
            let first = fenceReasons.isEmpty && !closed
            fenceReasons.append(reason); ended = true
            return first ? handler : nil
        }
        arrived.signal()
        if let notify { DispatchQueue.global().async(execute: notify) }
    }
    func waitForNativeCleanup() { while !nativeCleanupObserved { Thread.sleep(forTimeInterval: 0.001) } }
    func waitUntilNativeCleanup() async { while !nativeCleanupObserved { try? await Task.sleep(nanoseconds: 1_000_000) } }
}

/// What a started request delivered to its consumer.
private final class Delivered: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens = 0, finish: ClusterWorkerFinishReason?, failure: String?
    func record(_ event: ClusterWorkerRequestEvent) {
        lock.withLock {
            switch event {
            case .token: tokens += 1
            case .finished(let reason): finish = reason
            case .failed(let text): failure = text
            default: break
            }
        }
    }
    var value: (tokens: Int, finish: ClusterWorkerFinishReason?, failure: String?) { lock.withLock { (tokens, finish, failure) } }
}

private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?, done = false
    func finish(_ value: Error?) { lock.withLock { error = value; done = true } }
    var result: (done: Bool, error: Error?) { lock.withLock { (done, error) } }
}

/// Production, 2026-11-03 23:07–23:19Z (six drops of the GLM-5.3-Flash pair in
/// 19 minutes) and 2026-11-01 03:37Z: a request arrived with little of its
/// first-content budget left, and rank 0, busy with the pair's other lanes,
/// answered its reservation at its next step boundary, after that admission
/// deadline. The leader ended the whole pair: every lane in flight failed, rank 1
/// (never asked) was fenced with "the request was cancelled before it started",
/// and the reservation's delivery deadline (that same budget) let rank 0's own
/// owner fence rank 0. Only that request may end.
final class ClusterWorkerPairAdmissionDeadlineTests: XCTestCase {
    private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private func wait(seconds: Double, until condition: () -> Bool) -> Bool {
        let end = now() + UInt64(seconds * 1_000_000_000)
        while !condition() && now() < end { Thread.sleep(forTimeInterval: 0.005) }
        return condition()
    }
    private func reservation(output: Int) -> ClusterWorkerReservation {
        .init(profileID: ScriptedRank.profile.id, promptTokenIDs: [1, 2, 3], stopTokenIDs: [], outputCount: output,
              chunkSize: 4, deadlineUptimeNanoseconds: now() + 60_000_000_000, capacityLimitBytes: 1 << 20,
              sampling: nil, prefixCache: nil)
    }
    private func lanePair(_ ranks: [ScriptedRank]) throws -> ClusterWorkerPair {
        try ClusterWorkerPair(workers: ranks, startupDeadline: now() + 5_000_000_000, lanes: 4, lanesRetireAlone: true)
    }
    private func serve(_ pair: ClusterWorkerPair) throws {
        let lease = try pair.reserve(requestID: UUID(), reservation: reservation(output: 3))
        let delivered = Delivered()
        try lease.start { event in delivered.record(event); return true }
        XCTAssertTrue(wait(seconds: 10) { lease.isRetired }, "the next request did not retire")
        lease.releaseResources()
        XCTAssertEqual(delivered.value.finish, .length, "the next request did not finish: \(delivered.value)")
    }
    private func shutdown(_ pair: ClusterWorkerPair) {
        let done = DispatchSemaphore(value: 0)
        Task.detached { await pair.shutdown(); done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 20), .success, "the pair did not shut down")
    }

    /// On a lane pair, rank 0 answers a reservation 600 ms after a request
    /// arrived with 150 ms of its budget left. That request ends with a deadline
    /// outcome; nothing is fenced, the pair stays valid, the lane decoding
    /// meanwhile keeps running and finishes, and the pair serves the next request.
    func testALaneWhoseRankAnswersAfterItsAdmissionDeadlineEndsAloneWhileTheOtherLanesFinish() throws {
        let ranks = [ScriptedRank(rank: 0, tokenNanoseconds: 25_000_000), ScriptedRank(rank: 1)]
        let pair = try lanePair(ranks)
        let decoding = try pair.reserve(requestID: UUID(), reservation: reservation(output: 80))
        let delivered = Delivered()
        try decoding.start { event in delivered.record(event); return true }
        XCTAssertTrue(wait(seconds: 5) { delivered.value.tokens >= 2 }, "the first lane is not decoding")

        let late = UUID()
        ranks[0].holdNextAdmission()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(600)) { ranks[0].answerHeld(late) }
        let asked = now()
        XCTAssertThrowsError(try pair.reserve(requestID: late, reservation: reservation(output: 4),
                                              admissionDeadline: asked + 150_000_000)) { error in
            XCTAssertEqual(error as? ClusterWorkerOwnerError, .deadline)
        }
        XCTAssertTrue(pair.admissionState.isValid && pair.readiness != nil,
            "one request's admission deadline ended the pair: \(pair.lastRequestFailure ?? "no failure noted")")
        XCTAssertNil(pair.lastRequestFailure)
        XCTAssertEqual(ranks[0].fences, [], "rank 0 was fenced")
        XCTAssertEqual(ranks[1].fences, [], "rank 1, never asked, was fenced")
        XCTAssertEqual(ranks[1].reservations.map { $0.id }, [decoding.requestID], "rank 1 was asked after the deadline")
        XCTAssertEqual(ranks[0].cancels, [late], "rank 0 did not give back its late admission")
        // A rank's owner fences a worker whose reservation is unanswered past its
        // delivery deadline: the request's budget must not be that deadline.
        let delivery = try XCTUnwrap(ranks[0].reservations.first { $0.id == late }?.delivery)
        XCTAssertGreaterThanOrEqual(delivery, asked + ClusterWorkerRequest.laneAdmissionWaitNanoseconds - 1_000_000_000,
            "the reservation was delivered with the request's admission deadline, not the pair's admission wait")
        XCTAssertFalse(decoding.isRetired, "the decoding lane did not keep running")

        XCTAssertTrue(wait(seconds: 15) { decoding.isRetired }, "the decoding lane did not retire")
        decoding.releaseResources()
        XCTAssertEqual(delivered.value.tokens, 80)
        XCTAssertEqual(delivered.value.finish, .length)
        XCTAssertNil(delivered.value.failure)
        try serve(pair)
        shutdown(pair)
        XCTAssertTrue(ranks.allSatisfy { $0.fences.isEmpty && $0.nativeCleanupObserved }, "a rank did not end by its shutdown")
    }

    /// A request that ends while rank 0's answer is still on its way, before
    /// rank 1 was ever asked, never fences rank 1, whatever ended it. Here the
    /// pair fails for another reason (a lost peer, another lane's failure): the
    /// pair's owner shuts rank 1 down, it is not fenced for a request it never
    /// saw. Rank 0, which may hold the request, is fenced as before.
    func testARequestEndedBeforeRankOneWasAskedNeverFencesRankOne() throws {
        let ranks = [ScriptedRank(rank: 0), ScriptedRank(rank: 1)]
        let pair = try lanePair(ranks)
        ranks[0].holdNextAdmission()
        let outcome = Outcome(), value = reservation(output: 4)
        DispatchQueue.global().async {
            do { _ = try pair.reserve(requestID: UUID(), reservation: value); outcome.finish(nil) }
            catch { outcome.finish(error) }
        }
        XCTAssertTrue(wait(seconds: 5) { ranks[0].reservations.count == 1 }, "rank 0 was not asked")
        Thread.sleep(forTimeInterval: 0.1)
        pair.invalidate()
        XCTAssertTrue(wait(seconds: 10) { outcome.result.done }, "the reservation did not end")
        XCTAssertNotNil(outcome.result.error)
        XCTAssertEqual(ranks[1].commands, 0, "rank 1 was asked")
        XCTAssertEqual(ranks[1].fences, [], "rank 1, never asked, was fenced")
        XCTAssertFalse(ranks[0].fences.isEmpty, "rank 0's pending answer was not fenced in a failed pair")
        shutdown(pair)
        XCTAssertTrue(ranks[1].nativeCleanupObserved && ranks[1].fences.isEmpty, "rank 1 did not end by its shutdown")
    }

    /// The same request ended by its caller (the pair's own shutdown) while
    /// rank 0's answer is on its way fences nothing at all: rank 0 gives back
    /// what it admitted, and rank 1 was never asked.
    func testARequestItsCallerEndsBeforeRankOneWasAskedFencesNothing() throws {
        let ranks = [ScriptedRank(rank: 0), ScriptedRank(rank: 1)]
        let pair = try lanePair(ranks)
        let request = UUID()
        ranks[0].holdNextAdmission()
        let outcome = Outcome(), value = reservation(output: 4)
        DispatchQueue.global().async {
            do { _ = try pair.reserve(requestID: request, reservation: value); outcome.finish(nil) }
            catch { outcome.finish(error) }
        }
        XCTAssertTrue(wait(seconds: 5) { ranks[0].reservations.count == 1 }, "rank 0 was not asked")
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(300)) { ranks[0].answerHeld(request) }
        shutdown(pair)
        XCTAssertTrue(wait(seconds: 10) { outcome.result.done }, "the reservation did not end")
        XCTAssertEqual(outcome.result.error as? ClusterWorkerOwnerError, .cancelled)
        XCTAssertEqual(ranks[1].reservations.count, 0, "rank 1 was asked")
        XCTAssertEqual(ranks.map(\.fences), [[], []], "a rank was fenced for a request its caller ended")
        XCTAssertEqual(ranks[0].cancels, [request], "rank 0 did not give back its admission")
    }

    /// Regression: a peer that is really gone still ends the pair. The link to
    /// rank 1 closes for good as it is asked; the request fails and the pair is
    /// invalidated, as before.
    func testALinkThatClosesDuringAdmissionStillEndsThePair() throws {
        let ranks = [ScriptedRank(rank: 0), ScriptedRank(rank: 1)]
        let pair = try lanePair(ranks)
        ranks[1].closeLinkWhenAsked()
        XCTAssertThrowsError(try pair.reserve(requestID: UUID(), reservation: reservation(output: 4),
                                              admissionDeadline: now() + 10_000_000_000)) { error in
            XCTAssertEqual(error as? ClusterWorkerOwnerError, .closed)
        }
        XCTAssertFalse(pair.admissionState.isValid)
        XCTAssertNil(pair.readiness)
        XCTAssertEqual(pair.lastRequestFailure?.hasSuffix("failed on the pair: admission: a rank's command stream closed"), true,
            "\(pair.lastRequestFailure ?? "no failure noted")")
        shutdown(pair)
    }

    // MARK: A consumer that goes away during its prompt

    /// Production (DevNet, 2026-11-04, Qwen 3.8 27B on a tensor-parallel pair):
    /// a client closed its connection 15 s into a 58–62K-token prompt. The
    /// clean stop its going away asked for ends a request at its first token,
    /// so the pair first finished the whole prompt (about 4 minutes). The pair
    /// prefills one prompt at a time, so every newer request waited behind it
    /// and failed at its own first-token deadline. On a lane pair a request
    /// still in its prompt is cancelled instead: its lane alone ends, at once,
    /// and the pair serves the next request.
    func testAConsumerThatLeavesDuringItsPromptFreesItsLaneAtOnce() throws {
        let ranks = [ScriptedRank(rank: 0), ScriptedRank(rank: 1)]
        let pair = try lanePair(ranks)
        ranks[0].holdNextStart()
        let prompt = try pair.reserve(requestID: UUID(), reservation: reservation(output: 4))
        let delivered = Delivered()
        try prompt.start { event in delivered.record(event); return true }
        Thread.sleep(forTimeInterval: 0.2)
        // What the engine does when the consumer goes away: the lease's clean
        // stop if it takes one, else a cancel.
        if !prompt.requestCleanStop() { prompt.cancel() }
        XCTAssertTrue(wait(seconds: 5) { prompt.isRetired },
            "the request kept its lane after its consumer left: its whole prompt would run first")
        prompt.releaseResources()
        XCTAssertEqual(delivered.value.tokens, 0)
        XCTAssertEqual(ranks[0].cancels, [prompt.requestID], "rank 0 was not told to end the prompt")
        XCTAssertEqual(ranks[1].cancels, [prompt.requestID], "rank 1 was not told to end the prompt")
        XCTAssertEqual(ranks.map(\.fences), [[], []], "a rank was fenced")
        XCTAssertTrue(pair.admissionState.isValid && pair.readiness != nil,
            "the pair ended: \(pair.lastRequestFailure ?? "no failure noted")")
        XCTAssertNil(pair.lastRequestFailure)
        try serve(pair)
        shutdown(pair)
        XCTAssertTrue(ranks.allSatisfy { $0.fences.isEmpty && $0.nativeCleanupObserved }, "a rank did not end by its shutdown")
    }

    /// A lane that has produced a token keeps the clean stop: no rank is told
    /// to cancel it. The scripted ranks always finish `length`, so the request
    /// asks for one token and its consumer leaves at it.
    func testALaneThatProducedATokenKeepsTheCleanStop() throws {
        let ranks = [ScriptedRank(rank: 0), ScriptedRank(rank: 1)]
        let pair = try lanePair(ranks)
        let lease = try pair.reserve(requestID: UUID(), reservation: reservation(output: 1))
        let delivered = Delivered()
        try lease.start { event in
            delivered.record(event)
            if case .token = event, !lease.requestCleanStop() { lease.cancel() }
            return true
        }
        XCTAssertTrue(wait(seconds: 5) { lease.isRetired }, "the request did not retire")
        lease.releaseResources()
        XCTAssertTrue(lease.cleanStopWasRequested, "a lane that produced a token refused the clean stop")
        XCTAssertEqual(ranks.map(\.cancels), [[], []], "a rank was told to cancel the request")
        XCTAssertNil(delivered.value.failure)
        XCTAssertNil(pair.lastRequestFailure)
        shutdown(pair)
    }

    /// A pair whose workers do not retire a lane alone keeps the clean stop
    /// before the first token: a cancel there ends the pair.
    func testWithoutLanesARequestStillInItsPromptKeepsTheCleanStop() throws {
        let ranks = [ScriptedRank(rank: 0), ScriptedRank(rank: 1)]
        let pair = try ClusterWorkerPair(workers: ranks, startupDeadline: now() + 5_000_000_000)
        ranks[0].holdNextStart()
        let prompt = try pair.reserve(requestID: UUID(), reservation: reservation(output: 4))
        try prompt.start { _ in true }
        XCTAssertTrue(prompt.requestCleanStop(), "a pair without lanes refused the clean stop")
        XCTAssertEqual(ranks.map(\.cancels), [[], []], "a rank was told to end the prompt")
        prompt.cancel()
        XCTAssertTrue(wait(seconds: 10) { prompt.isRetired }, "the request did not retire")
        prompt.releaseResources()
        shutdown(pair)
    }
}
