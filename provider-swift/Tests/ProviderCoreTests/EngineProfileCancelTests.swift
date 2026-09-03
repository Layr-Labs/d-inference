// Profiler cancel-path tests over a fake engine (no weights, no Metal):
// the handler builds its cancelled terminal BEFORE the engine delivers
// `.finished(.cancelled)`, so the bridge's late first/last-delta stamps must
// be clamped to `terminal_built`, `tokens_after_cancel` must still be
// computed, and the cumulative counter must land through the builder hook.

import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

/// Engine whose event delivery is driven by the test, one request at a time.
private final class ControlledEngine: CBv2Engine, @unchecked Sendable {
    /// Verdict the deadline-capable submit returns once its gate opens.
    enum DeadlineVerdict { case admitted, unreachable }

    private let lock = NSLock()
    private var continuation: AsyncStream<CBv2Event>.Continuation?
    private var cancelled: [CBv2RequestID] = []
    private var deadlineGate: AsyncGate?
    private var deadlineVerdict: DeadlineVerdict = .admitted
    private var deadlineSubmitEntered = false

    /// Arm the atomic deadline submit: it parks on `gate` (the bridge actor
    /// is suspended meanwhile) and then returns `verdict`.
    func armDeadlineSubmit(gate: AsyncGate, verdict: DeadlineVerdict) {
        lock.withLock {
            deadlineGate = gate
            deadlineVerdict = verdict
            deadlineSubmitEntered = false
        }
    }

    var enteredDeadlineSubmit: Bool { lock.withLock { deadlineSubmitEntered } }

    func submit(
        _ request: CBv2Request, firstTokenDeadline: CBv2FirstTokenDeadlineAdmission
    ) async throws -> CBv2FirstTokenDeadlineResult {
        let (gate, verdict) = lock.withLock {
            deadlineSubmitEntered = true
            return (deadlineGate, deadlineVerdict)
        }
        if let gate { await gate.wait() }
        switch verdict {
        case .unreachable:
            return .deadlineUnreachable(projectedWork: .unbounded)
        case .admitted:
            return .admitted(
                stream: try submit(request), projectedWork: .unbounded, admittedAt: .now,
                retirement: CBv2RequestRetirement(waitUntilRetired: {}))
        }
    }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        lock.withLock { self.continuation = continuation }
        return stream
    }

    func emit(_ event: CBv2Event) {
        lock.withLock { continuation }?.yield(event)
    }

    func cancel(_ id: CBv2RequestID) {
        lock.withLock { cancelled.append(id) }
    }

    var cancelledIDs: [CBv2RequestID] { lock.withLock { cancelled } }

    func capacity() -> CBv2CapacitySnapshot {
        CBv2CapacitySnapshot(
            activeRequests: 1, waitingRequests: 0, kvBytesInUse: 4096,
            kvBytesCapacity: 1 << 20, activeTokens: 3, stepsExecuted: 42)
    }
    func updateKVBytesCapacity(_ bytes: Int) {}
    func shutdown() async {}
}

/// One-shot async gate: `wait()` parks until `open()`.
private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        opened = true
        let parked = waiters
        waiters = []
        lock.unlock()
        parked.forEach { $0.resume() }
    }
}

/// The submission task never registered a pending id (it threw or never
/// started) — surfaced as a failure instead of an unbounded poll.
private struct PendingSubmissionNeverRegistered: Error {}

/// Wait (bounded) until `submitTokenized` has registered its pending id and
/// parked on the pre-submit gate.
private func awaitPendingSubmission(
    on bridge: EngineV2Bridge, attempts: Int = 20_000
) async throws {
    for _ in 0..<attempts {
        if await bridge._testPendingSubmissionCount() > 0 { return }
        await Task.yield()
    }
    throw PendingSubmissionNeverRegistered()
}

/// Lock-boxed sink for the builder's `onTokensAfterCancel` hook.
private final class TokensAfterCancelSink: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    func add(_ v: Int64) { lock.withLock { values.append(v) } }
    var recorded: [Int64] { lock.withLock { values } }
}

private func makeProfileWithHook(_ sink: TokensAfterCancelSink) -> RequestProfileBuilder {
    let profile = RequestProfileBuilder()
    // Mirrors the handler entry: dequeued stamp + hook under one lock, then the
    // stamps a request has by the time it reaches the bridge.
    profile.update { f, now in
        f.mark(.dequeued, offsetUs: now)
        f.onTokensAfterCancel = { sink.add($0) }
    }
    profile.mark(.acceptedSent)
    return profile
}

private func submitControlled(
    bridge: EngineV2Bridge, requestId: String, profile: RequestProfileBuilder,
    deadline: FirstContentDeadline? = nil
) async throws -> AsyncStream<GenerationEvent> {
    try await bridge.submitTokenized(
        promptTokens: [1, 2, 3],
        request: ChatCompletionRequest(
            model: "fake-model",
            messages: [ChatMessage(role: "user", content: "hi")]),
        requestId: requestId,
        firstContentDeadline: deadline,
        profile: profile)
}

/// The bridge never reached the fake engine's deadline submit.
private struct DeadlineSubmitNeverEntered: Error {}

/// Wait (bounded) until the bridge is parked inside the fake engine's atomic
/// deadline submit — the only pre-admission suspension on this path.
private func awaitDeadlineSubmitEntered(
    _ engine: ControlledEngine, attempts: Int = 20_000
) async throws {
    for _ in 0..<attempts {
        if engine.enteredDeadlineSubmit { return }
        await Task.yield()
    }
    throw DeadlineSubmitNeverEntered()
}

// These helpers use the bridge's debug-only test seams.
#if DEBUG
/// Bounded wait for the bridge's pending maps to drain (the retirement
/// transfer completes on a background task).
private func awaitPendingDrained(on bridge: EngineV2Bridge, attempts: Int = 20_000) async -> Bool {
    for _ in 0..<attempts {
        if await bridge._testPendingSubmissionCount() == 0,
            await bridge._testPendingProfileCount() == 0
        {
            return true
        }
        await Task.yield()
    }
    return false
}

/// A bridge on the atomic deadline-submit path: enforce mode + a seeded
/// isolated prefill rate (both required by `firstTokenDeadlineAdmission`).
private func makeDeadlineBridge(engine: ControlledEngine) async -> EngineV2Bridge {
    let bridge = EngineV2Bridge(
        engine: engine, modelId: "fake-model",
        tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [],
        prefillDeadlineMode: .enforce)
    await bridge._testSeedIsolatedPrefillEwma(1_000)
    return bridge
}
#endif

@Suite("EngineProfile cancel path")
struct EngineProfileCancelTests {

    @Test("coordinator cancel mid-decode after the terminal is built keeps the order chain and counts tokens_after_cancel")
    func coordinatorCancelMidDecodeAfterTerminalBuilt() async throws {
        let engine = ControlledEngine()
        let bridge = EngineV2Bridge(
            engine: engine, modelId: "fake-model",
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [])
        let sink = TokensAfterCancelSink()
        let profile = makeProfileWithHook(sink)

        let stream = try await submitControlled(
            bridge: bridge, requestId: "req-minted", profile: profile)
        var iterator = stream.makeAsyncIterator()

        // Two decode deltas reach the consumer (pump bookkeeping is complete
        // by the time the outer chunk is observed).
        engine.emit(.delta(text: "a", tokens: [10], logprobs: nil))
        _ = await iterator.next()
        engine.emit(.delta(text: "b", tokens: [11], logprobs: nil))
        _ = await iterator.next()

        // The coordinator cancel arrives under the COORDINATOR id: the bridge's
        // id map misses, but the profile identity finds the row and snapshots
        // the completion count (2) at receipt.
        let owned = await bridge.cancelIfOwned(requestId: "coordinator-uuid", profile: profile)
        #expect(owned == false)
        #expect(engine.cancelledIDs.isEmpty, "semantics unchanged: no engine cancel on the miss path")

        // The handler builds its cancelled terminal NOW — before the engine
        // has delivered `.finished(.cancelled)`.
        profile.mark(.cancelAborted)
        profile.update { f, now in f.mark(.terminalBuilt, offsetUs: now) }
        try await Task.sleep(for: .milliseconds(3))

        // Late engine events: two more tokens, then the cancelled terminal.
        engine.emit(.delta(text: "cd", tokens: [12, 13], logprobs: nil))
        _ = await iterator.next()
        engine.emit(.finished(
            reason: .cancelled, usage: CBv2Usage(promptTokens: 3, completionTokens: 4)))
        while await iterator.next() != nil {}

        let wire = profile.wireObject()
        let admitted = try #require(wire.engineAdmittedUs)
        let firstDelta = try #require(wire.firstDeltaUs)
        let lastDelta = try #require(wire.lastDeltaUs)
        let terminalBuilt = try #require(wire.terminalBuiltUs)
        // The coordinator's order chain over present stamps must hold even
        // though the last delta physically arrived after the terminal.
        #expect(admitted <= firstDelta)
        #expect(firstDelta <= lastDelta)
        #expect(lastDelta <= terminalBuilt)
        // The late delta was pinned exactly to the terminal, not merely below it.
        #expect(lastDelta == terminalBuilt)
        #expect(wire.tokensAfterCancel == 2)
        #expect(sink.recorded == [2], "counter hook fires once with the delta")
        #expect(wire.stepsAtFinish == 42)
        #expect(wire.engine?.finishReason == .cancelled)
        #expect(wire.cancelAbortedUs != nil)
        // The bridge-internal snapshot never reaches the wire.
        let encoded = try JSONEncoder().encode(wire)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["tokens_at_cancel"] == nil)
        #expect(object["tokens_after_cancel"] as? Int == 2)
    }

    @Test("cancel by the engine-minted id snapshots at the bridge and cancels the engine row")
    func bridgeIdCancelSnapshotsAndCancelsRow() async throws {
        let engine = ControlledEngine()
        let bridge = EngineV2Bridge(
            engine: engine, modelId: "fake-model",
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [])
        let sink = TokensAfterCancelSink()
        let profile = makeProfileWithHook(sink)

        let stream = try await submitControlled(
            bridge: bridge, requestId: "req-minted", profile: profile)
        var iterator = stream.makeAsyncIterator()
        engine.emit(.delta(text: "a", tokens: [10], logprobs: nil))
        _ = await iterator.next()

        // Task-cancellation teardown path: `bridge.cancel(requestId:)` under
        // the minted id reaches the engine AND snapshots (1 token so far).
        await bridge.cancel(requestId: "req-minted")
        #expect(engine.cancelledIDs.count == 1)
        // A second cancel via the MISS path (the coordinator id, racing the
        // teardown) must neither move the first snapshot nor cancel again.
        engine.emit(.delta(text: "b", tokens: [11], logprobs: nil))
        _ = await iterator.next()
        let ownedAgain = await bridge.cancelIfOwned(requestId: "coordinator-uuid", profile: profile)
        #expect(ownedAgain == false)
        #expect(engine.cancelledIDs.count == 1)
        engine.emit(.delta(text: "c", tokens: [12], logprobs: nil))
        _ = await iterator.next()
        engine.emit(.finished(
            reason: .cancelled, usage: CBv2Usage(promptTokens: 3, completionTokens: 3)))
        while await iterator.next() != nil {}

        let wire = profile.wireObject()
        #expect(wire.tokensAfterCancel == 2)
        #expect(sink.recorded == [2])
        let firstDelta = try #require(wire.firstDeltaUs)
        let lastDelta = try #require(wire.lastDeltaUs)
        #expect(firstDelta <= lastDelta)
        // No terminal was built on this path, so the delta stamps are unclamped
        // and `terminal_built` is absent (the order check skips absent stamps).
        #expect(wire.terminalBuiltUs == nil)
    }

    @Test("the cumulative counter lands even when the profile map entry was removed before the engine finished")
    func counterLandsAfterProfileRemovedFromMap() async throws {
        let engine = ControlledEngine()
        let bridge = EngineV2Bridge(
            engine: engine, modelId: "fake-model",
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [])
        // The real sink: the hook captures ONLY this process-lifetime object.
        let stats = AtomicProviderStats()
        let profile = RequestProfileBuilder()
        profile.update { f, now in
            f.mark(.dequeued, offsetUs: now)
            f.onTokensAfterCancel = { stats.addTokensAfterCancel(UInt64(max(0, $0))) }
        }
        // Stand-in for `ProviderLoop.inflightProfiles`.
        var inflightProfiles: [String: RequestProfileBuilder] = ["coordinator-uuid": profile]

        let stream = try await submitControlled(
            bridge: bridge, requestId: "req-minted", profile: profile)
        var iterator = stream.makeAsyncIterator()
        engine.emit(.delta(text: "a", tokens: [10], logprobs: nil))
        _ = await iterator.next()

        // handleCancellation: snapshot via the map entry…
        _ = await bridge.cancelIfOwned(
            requestId: "coordinator-uuid", profile: inflightProfiles["coordinator-uuid"])
        // …then finishInflightRequest drops the entry BEFORE the engine finishes.
        inflightProfiles.removeValue(forKey: "coordinator-uuid")
        #expect(inflightProfiles.isEmpty)

        engine.emit(.delta(text: "b", tokens: [11], logprobs: nil))
        _ = await iterator.next()
        engine.emit(.finished(
            reason: .cancelled, usage: CBv2Usage(promptTokens: 3, completionTokens: 2)))
        while await iterator.next() != nil {}

        #expect(stats.tokensAfterCancelTotal == 1)
        #expect(stats.snapshot().tokensAfterCancelTotal == 1)
        #expect(profile.wireObject().tokensAfterCancel == 1)
    }

    @Test("cancelIfOwned under the engine-minted id takes the HIT path: owned, one engine cancel, first snapshot kept")
    func cancelIfOwnedHitPathSnapshotsAndCancelsOnce() async throws {
        let engine = ControlledEngine()
        let bridge = EngineV2Bridge(
            engine: engine, modelId: "fake-model",
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [])
        let sink = TokensAfterCancelSink()
        let profile = makeProfileWithHook(sink)

        let stream = try await submitControlled(
            bridge: bridge, requestId: "req-minted", profile: profile)
        var iterator = stream.makeAsyncIterator()
        engine.emit(.delta(text: "a", tokens: [10], logprobs: nil))
        _ = await iterator.next()

        // HIT: the id map knows the minted id → snapshot (1 token) + engine cancel.
        let owned = await bridge.cancelIfOwned(requestId: "req-minted", profile: profile)
        #expect(owned == true)
        #expect(engine.cancelledIDs.count == 1)

        // A second HIT after more tokens cancels the row again (engine-side
        // idempotent) but must NOT move the first snapshot.
        engine.emit(.delta(text: "b", tokens: [11], logprobs: nil))
        _ = await iterator.next()
        let ownedAgain = await bridge.cancelIfOwned(requestId: "req-minted", profile: nil)
        #expect(ownedAgain == true)
        #expect(engine.cancelledIDs.count == 2)

        engine.emit(.delta(text: "c", tokens: [12], logprobs: nil))
        _ = await iterator.next()
        engine.emit(.finished(
            reason: .cancelled, usage: CBv2Usage(promptTokens: 3, completionTokens: 3)))
        while await iterator.next() != nil {}

        let wire = profile.wireObject()
        // 3 completion tokens − 1 at the FIRST snapshot (not 2 at the second).
        #expect(wire.tokensAfterCancel == 2)
        #expect(sink.recorded == [2])
        #expect(wire.engine?.finishReason == .cancelled)
        // After finish the row is gone: the same id now takes the miss path.
        let afterFinish = await bridge.cancelIfOwned(requestId: "req-minted", profile: profile)
        #expect(afterFinish == false)
        #expect(engine.cancelledIDs.count == 2)
    }

    // The pending-admission cases drive the bridge's debug-only test seams.
    #if DEBUG
    @Test("a cancel that lands while the row is still pending admission is owned, latched, refused before the engine, and records tokens_after_cancel = 0")
    func pendingAdmissionCancelIsLatchedAndRecorded() async throws {
        let engine = ControlledEngine()
        let bridge = EngineV2Bridge(
            engine: engine, modelId: "fake-model",
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [])
        let sink = TokensAfterCancelSink()
        let profile = makeProfileWithHook(sink)

        // Park the submission right after `pendingSubmissionIDs.insert`,
        // before the engine submit.
        let gate = AsyncGate()
        await bridge._testInstallPreSubmitGate { await gate.wait() }
        let submission = Task {
            try await submitControlled(bridge: bridge, requestId: "req-minted", profile: profile)
        }
        try await awaitPendingSubmission(on: bridge)

        // The coordinator cancel arrives under the coordinator id while the
        // row is pending: matched by profile identity → owned, latched,
        // zero baseline seeded, nothing to cancel in the engine yet.
        let owned = await bridge.cancelIfOwned(requestId: "coordinator-uuid", profile: profile)
        #expect(owned == true)
        #expect(engine.cancelledIDs.isEmpty)

        // Submission resumes: the latch is honoured at the next pre-submit
        // check — the request is REFUSED before the engine ever sees the row
        // (the existing minted-id semantics), so it can never admit and
        // generate after the cancel.
        gate.open()
        var refused = false
        do {
            _ = try await submission.value
        } catch is CancellationError {
            refused = true
        }
        #expect(refused, "a latched pending cancel refuses the submission")
        #expect(engine.cancelledIDs.isEmpty, "the engine never saw the row")
        #expect(await bridge._testPendingSubmissionCount() == 0)

        // Recorded as an explicit 0, never omitted; the hook adds nothing.
        let wire = profile.wireObject()
        #expect(wire.tokensAfterCancel == 0)
        #expect(sink.recorded.isEmpty)
        #expect(wire.engine == nil)
        // The bridge no longer retains the profile (pending map drained with
        // the pending id — a real leak check).
        #expect(await bridge._testPendingProfileCount() == 0)

        // Control: without a latched cancel the same gate lets a row admit
        // and generate normally (the pending map is cleaned up either way).
        let control = makeProfileWithHook(TokensAfterCancelSink())
        let controlGate = AsyncGate()
        await bridge._testInstallPreSubmitGate { await controlGate.wait() }
        let controlSubmission = Task {
            try await submitControlled(bridge: bridge, requestId: "req-control", profile: control)
        }
        try await awaitPendingSubmission(on: bridge)
        controlGate.open()
        let stream = try await controlSubmission.value
        var iterator = stream.makeAsyncIterator()
        engine.emit(.delta(text: "a", tokens: [10], logprobs: nil))
        _ = await iterator.next()
        engine.emit(.finished(reason: .stop, usage: CBv2Usage(promptTokens: 3, completionTokens: 1)))
        while await iterator.next() != nil {}
        #expect(control.wireObject().tokensAfterCancel == nil)
        #expect(engine.cancelledIDs.isEmpty)
        #expect(await bridge._testPendingProfileCount() == 0)
        #expect(await bridge._testPendingSubmissionCount() == 0)
    }

    @Test("deadline path: a cancel latched during the atomic submit that ends in .deadlineUnreachable records tokens_after_cancel = 0 (never admitted)")
    func deadlineUnreachableAfterLatchedCancelRecordsZero() async throws {
        let engine = ControlledEngine()
        let bridge = await makeDeadlineBridge(engine: engine)
        let sink = TokensAfterCancelSink()
        let profile = makeProfileWithHook(sink)
        let gate = AsyncGate()
        engine.armDeadlineSubmit(gate: gate, verdict: .unreachable)

        let submission = Task {
            try await submitControlled(
                bridge: bridge, requestId: "req-minted", profile: profile,
                deadline: FirstContentDeadline(relativeBudgetMilliseconds: 30_000))
        }
        try await awaitDeadlineSubmitEntered(engine)
        #expect(await bridge._testPendingSubmissionCount() == 1)

        // Cancel lands while the bridge is suspended in the engine's atomic
        // submit: coordinator id → profile identity → pending latch.
        let owned = await bridge.cancelIfOwned(requestId: "coordinator-uuid", profile: profile)
        #expect(owned == true)

        gate.open()
        var refused = false
        do { _ = try await submission.value } catch is CancellationError { refused = true }
        #expect(refused)
        #expect(engine.cancelledIDs.isEmpty, "never admitted → nothing to cancel")
        #expect(profile.wireObject().tokensAfterCancel == 0)
        #expect(sink.recorded.isEmpty)
        #expect(await awaitPendingDrained(on: bridge))
    }

    @Test("deadline path: a cancel latched during the atomic submit that ends in .admitted tears the row down and OMITS tokens_after_cancel")
    func admittedThenLatchedTeardownOmitsTokensAfterCancel() async throws {
        let engine = ControlledEngine()
        let bridge = await makeDeadlineBridge(engine: engine)
        let sink = TokensAfterCancelSink()
        let profile = makeProfileWithHook(sink)
        let gate = AsyncGate()
        engine.armDeadlineSubmit(gate: gate, verdict: .admitted)

        let submission = Task {
            try await submitControlled(
                bridge: bridge, requestId: "req-minted", profile: profile,
                deadline: FirstContentDeadline(relativeBudgetMilliseconds: 30_000))
        }
        try await awaitDeadlineSubmitEntered(engine)
        let owned = await bridge.cancelIfOwned(requestId: "coordinator-uuid", profile: profile)
        #expect(owned == true)

        gate.open()
        var refused = false
        do { _ = try await submission.value } catch is CancellationError { refused = true }
        #expect(refused)
        // Admitted, then dropped exactly once; an in-flight step could have
        // produced a token, so the field must be ABSENT — not a fabricated 0.
        #expect(engine.cancelledIDs.count == 1)
        #expect(profile.wireObject().tokensAfterCancel == nil)
        #expect(sink.recorded.isEmpty)
        // The retirement transfer releases the pending bookkeeping.
        #expect(await awaitPendingDrained(on: bridge))
    }

    #endif

    @Test("a clean finish with no cancel neither sets tokens_after_cancel nor fires the hook")
    func cleanFinishLeavesCancelFieldsAbsent() async throws {
        let engine = ControlledEngine()
        let bridge = EngineV2Bridge(
            engine: engine, modelId: "fake-model",
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [])
        let sink = TokensAfterCancelSink()
        let profile = makeProfileWithHook(sink)

        let stream = try await submitControlled(
            bridge: bridge, requestId: "req-minted", profile: profile)
        var iterator = stream.makeAsyncIterator()
        engine.emit(.delta(text: "a", tokens: [10], logprobs: nil))
        _ = await iterator.next()
        engine.emit(.finished(reason: .stop, usage: CBv2Usage(promptTokens: 3, completionTokens: 1)))
        while await iterator.next() != nil {}

        let wire = profile.wireObject()
        #expect(wire.tokensAfterCancel == nil)
        #expect(sink.recorded.isEmpty)
        #expect(wire.engine?.finishReason == .stop)
        // A cancel that lands AFTER the finish: the bridge scan misses (row
        // gone) and the handler's linearized fallback records an explicit 0.
        let late = await bridge.cancelIfOwned(requestId: "coordinator-uuid", profile: profile)
        #expect(late == false)
        profile.recordTokensAfterCancelIfFinished()
        #expect(profile.wireObject().tokensAfterCancel == 0)
        #expect(sink.recorded.isEmpty)
        #expect(wire.deadlineMode == DeadlineMode.none)
        #expect(wire.stepsAtSubmit == 42)
        #expect(wire.runningAtAdmit == 1)
        #expect(wire.kvBytesInUseAtAdmit == 4096)
    }
}
