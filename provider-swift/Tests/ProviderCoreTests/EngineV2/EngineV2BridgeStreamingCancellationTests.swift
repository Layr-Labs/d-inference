// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore


@Suite("EngineV2 event framing matches the legacy GenerationEvent shape")
struct EngineV2EventFramingTests {

    @Test("happy path: chunks then a single usage info, then finish")
    func happyPath() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .delta(text: "Hello", tokens: [10], logprobs: nil),
            .delta(text: " world", tokens: [11], logprobs: nil),
            // Empty-text delta (BPE intermediate): counted, never yielded.
            .delta(text: "", tokens: [12], logprobs: nil),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 3)),
        ]))
        let bridge = makeBridge(engine: engine)
        let (events, tps) = await record(
            await bridge.submit(request: makeRequest())
        )
        // Recorded legacy shape (BatchScheduler+EngineBridge): every
        // non-empty text delta is one `.chunk`, a successful terminal is
        // exactly one `.info(prompt, completion, tps)`, then finish.
        let legacyShape: [RecordedEvent] = [
            .chunk("Hello"),
            .chunk(" world"),
            .info(prompt: 5, completion: 3),
        ]
        #expect(events == legacyShape)
        #expect(tps.count == 1)
        #expect(tps[0] >= 0)
    }

    @Test("length finish frames usage like stop but preserves finish_reason 'length'")
    func lengthFramesLikeStop() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .delta(text: "x", tokens: [10], logprobs: nil),
            // Terminal under-reports the prompt (4 < the 5 tokens the bridge
            // tokenized) — the bridge-known count wins (legacy max() rule).
            .finished(reason: .length, usage: CBv2Usage(promptTokens: 4, completionTokens: 1)),
        ]))
        let bridge = makeBridge(engine: engine)
        let (events, _) = await record(await bridge.submit(request: makeRequest()))
        #expect(events == [.chunk("x"), .info(prompt: 5, completion: 1)])
    }

    /// Deadline-first-principles regression: a typed platform/engine terminal
    /// used to be flattened into a generic string error with ZERO usage. It now
    /// surfaces as `.terminal` carrying the machine-readable cause AND the
    /// engine-reconciled usage the watchdog observed before firing.
    @Test("typed platform terminal surfaces as .terminal with cause + reconciled usage")
    func typedTerminalCarriesCauseAndUsage() async {
        // Watchdog-style: no deltas, the engine reports the real counts it saw.
        let engine = ScriptedCBv2Engine(script: .stream([
            .finished(
                reason: .terminal(cause: .decodeStall, message: "decode made no progress"),
                usage: CBv2Usage(promptTokens: 11, completionTokens: 5)),
        ]))
        let bridge = makeBridge(engine: engine)
        let (events, _) = await record(await bridge.submit(request: makeRequest()))
        #expect(events == [.terminal(cause: .decodeStall, prompt: 11, completion: 5)])
        // It is NOT flattened into a legacy string error.
        #expect(!events.contains { if case .error = $0 { return true }; return false })
    }

    /// `.legacyRequestTimeout` (the rollback kill-switch's terminal) has NO wire
    /// cause — the bridge must fall back to the legacy `.error(String)` shape
    /// byte-for-byte, never guess a typed cause.
    @Test(".legacyRequestTimeout has no wire cause → legacy .error string")
    func legacyTimeoutTerminalStaysLegacyError() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .finished(
                reason: .terminal(
                    cause: .legacyRequestTimeout, message: "request exceeded 120s deadline"),
                usage: CBv2Usage(promptTokens: 3, completionTokens: 0)),
        ]))
        let bridge = makeBridge(engine: engine)
        let (events, _) = await record(await bridge.submit(request: makeRequest()))
        #expect(events == [.error("request exceeded 120s deadline")])
    }

    /// Regression: the v2 bridge used to flatten `.length` into the same
    /// `.info` shape as `.stop`, so clients saw finish_reason "stop" on a
    /// max_tokens truncation. The reason now rides on GenerationEvent.info.
    @Test("finish reason threads through: .length => 'length', .stop => 'stop', cancel partial => nil")
    func finishReasonThreadsThroughInfoEvent() async {
        func terminalReason(_ finish: CBv2FinishReason) async -> String?? {
            let engine = ScriptedCBv2Engine(script: .stream([
                .delta(text: "x", tokens: [10], logprobs: nil),
                .finished(reason: finish, usage: CBv2Usage(promptTokens: 4, completionTokens: 1)),
            ]))
            let bridge = makeBridge(engine: engine)
            var got: String?? = nil
            for await event in await bridge.submit(request: makeRequest()) {
                if case .info(_, _, _, let reason) = event {
                    got = .some(reason)
                }
            }
            return got
        }
        #expect(await terminalReason(.length) == .some("length"))
        #expect(await terminalReason(.stop) == .some("stop"))
        // Cancelled-with-work emits its usage info with a nil reason (the
        // terminal signal is the trailing "request cancelled" error).
        #expect(await terminalReason(.cancelled) == .some(String?.none))
    }

    @Test("terminal usage can only raise observed counts (billing-zero defense)")
    func usageMaxDefense() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .delta(text: "a", tokens: [10], logprobs: nil),
            .delta(text: "b", tokens: [11, 12], logprobs: nil),
            // Terminal under-reports (0 completion) — must not zero billing.
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 0)),
        ]))
        let bridge = makeBridge(engine: engine)
        let (events, _) = await record(await bridge.submit(request: makeRequest()))
        #expect(events == [.chunk("a"), .chunk("b"), .info(prompt: 5, completion: 3)])
    }

    @Test("cancel that did work: usage info BEFORE the cancel error (legacy abort framing)")
    func cancelledWithWork() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .delta(text: "Hi", tokens: [10], logprobs: nil),
            .finished(reason: .cancelled, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
        ]))
        let bridge = makeBridge(engine: engine)
        let (events, _) = await record(await bridge.submit(request: makeRequest()))
        #expect(events == [
            .chunk("Hi"),
            .info(prompt: 5, completion: 1),
            .error("request cancelled"),
        ])
    }

    @Test("cancel before any decode: prompt-only usage info, then cancel error")
    func cancelledWithoutWork() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .finished(reason: .cancelled, usage: CBv2Usage(promptTokens: 0, completionTokens: 0)),
        ]))
        let bridge = makeBridge(engine: engine)
        let (events, _) = await record(await bridge.submit(request: makeRequest()))
        // The bridge tokenized a 5-token prompt, so even a did-nothing
        // cancel reports prompt usage before the error — exactly the legacy
        // abort framing (`recordFinish` max()es the bridge-known prompt).
        #expect(events == [
            .info(prompt: 5, completion: 0),
            .error("request cancelled"),
        ])
    }

    @Test("engine error: error only — no info (legacy failure framing)")
    func engineError() async {
        let telemetry = TelemetrySink()
        let engine = ScriptedCBv2Engine(script: .stream([
            .delta(text: "x", tokens: [10], logprobs: nil),
            .finished(
                reason: .error("metal command buffer failed"),
                usage: CBv2Usage(promptTokens: 4, completionTokens: 1)
            ),
        ]))
        let bridge = makeBridge(engine: engine, telemetry: telemetry)
        let (events, _) = await record(await bridge.submit(request: makeRequest()))
        #expect(events == [.chunk("x"), .error("metal command buffer failed")])
        // engine_v2-tagged inference_error telemetry (allowlisted fields
        // only — never the raw engine message).
        let errorEvents = telemetry.events.filter { $0.kind == .inferenceError }
        #expect(errorEvents.count == 1)
        #expect(errorEvents.first?.fields?["backend"]?.description == "engine_v2")
        #expect(errorEvents.first?.fields?["operation"]?.description == "engine_v2_error")
    }

    @Test("stream closed without terminal → teardown sentinel error")
    func teardownSentinel() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .delta(text: "partial", tokens: [10], logprobs: nil)
            // no .finished — engine torn down mid-request
        ]))
        let bridge = makeBridge(engine: engine)
        let (events, _) = await record(await bridge.submit(request: makeRequest()))
        #expect(events == [
            .chunk("partial"),
            .error("request stream closed by engine teardown"),
        ])
        // Local bookkeeping must be dropped.
        let counters = await bridge._testCounters()
        #expect(counters.active == 0)
    }

    @Test("tokenize failure surfaces as a tokenize error without touching the engine")
    func tokenizeFailure() async {
        let engine = ScriptedCBv2Engine(script: .stream([]))
        var tokenizer = StubTokenizer()
        tokenizer.failTemplate = true
        let bridge = makeBridge(engine: engine, tokenizer: tokenizer)
        let (events, _) = await record(await bridge.submit(request: makeRequest()))
        #expect(events.count == 1)
        if case .error(let message)? = events.first {
            #expect(message.hasPrefix("Failed to tokenize:"))
        }
        #expect(engine.submitted.isEmpty)
    }
}

// MARK: - Logprobs passthrough (delta logprobs → per-request channel)

@Suite("EngineV2 logprobs passthrough")
struct EngineV2LogprobsPassthroughTests {

    @Test("delta logprobs publish to the channel in OpenAI entry shape, in order")
    func logprobsFlowToChannel() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .delta(
                text: "He", tokens: [10],
                logprobs: [
                    CBv2TokenLogprob(
                        token: 10, logprob: -0.1,
                        topLogprobs: [(token: 10, logprob: -0.1), (token: 12, logprob: -2.0)]
                    )
                ]),
            .delta(
                text: "llo", tokens: [11],
                logprobs: [CBv2TokenLogprob(token: 11, logprob: -0.9)]),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 2)),
        ]))
        let bridge = makeBridge(engine: engine)
        let channel = EngineV2LogprobsChannel()
        let (events, _) = await record(await bridge.submit(
            request: makeRequest(logprobs: true, topLogprobs: 2),
            requestId: "req-lp",
            logprobsChannel: channel
        ))
        // The GenerationEvent stream is untouched — logprobs ride out-of-band.
        #expect(events == [
            .chunk("He"), .chunk("llo"), .info(prompt: 5, completion: 2),
        ])
        // Sampling translation asked the engine to capture logprobs.
        #expect(engine.submitted[0].sampling.topLogprobs == 2)
        // Entries arrive converted (StubTokenizer decodes id → "t<id>"),
        // in emission order, with alternatives preserved.
        let entries = channel.drain()
        #expect(entries.count == 2)
        #expect(entries[0].token == "t10")
        #expect(entries[0].logprob == -0.1)
        #expect(entries[0].bytes == Array("t10".utf8).map(Int.init))
        #expect(entries[0].topLogprobs.count == 2)
        #expect(entries[0].topLogprobs[1].token == "t12")
        #expect(entries[1].token == "t11")
        #expect(entries[1].topLogprobs.isEmpty)
        // drain() empties the channel.
        #expect(channel.drain().isEmpty)
    }

    @Test("nil/empty delta logprobs leave the channel empty")
    func noLogprobsNoEntries() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .delta(text: "x", tokens: [10], logprobs: nil),
            .delta(text: "y", tokens: [11], logprobs: []),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 2)),
        ]))
        let bridge = makeBridge(engine: engine)
        let channel = EngineV2LogprobsChannel()
        _ = await record(await bridge.submit(
            request: makeRequest(), requestId: "req-nolp", logprobsChannel: channel
        ))
        #expect(channel.drain().isEmpty)
    }

    @Test("no channel wired → logprob-bearing deltas stream normally (dropped)")
    func logprobsWithoutChannelAreDropped() async {
        let engine = ScriptedCBv2Engine(script: .stream([
            .delta(
                text: "x", tokens: [10],
                logprobs: [CBv2TokenLogprob(token: 10, logprob: -0.5)]),
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 5, completionTokens: 1)),
        ]))
        let bridge = makeBridge(engine: engine)
        let (events, _) = await record(await bridge.submit(request: makeRequest()))
        #expect(events == [.chunk("x"), .info(prompt: 5, completion: 1)])
    }
}

// MARK: - Error mapping (capacity → retryable class)


@Suite("EngineV2 cancellation wiring")
struct EngineV2CancellationTests {

    @Test("bridge cancel maps the provider request-id to the minted engine id")
    func bridgeCancelMapsId() async {
        let engine = ScriptedCBv2Engine(script: .manual)
        let budget = TestBudgets.ample()
        let bridge = makeBridge(
            engine: engine,
            kvBytesPerToken: 4_000,
            kvBudget: budget)
        let stream = await bridge.submit(request: makeRequest(), requestId: "req-abc")
        let engineId = await bridge._testEngineRequestId(for: "req-abc")
        #expect(engineId != nil)
        #expect(await budget.outstandingReservedBytes() > 0)

        await bridge.cancel(requestId: "req-abc")
        #expect(engine.cancelled == [engineId!])

        // Engine delivers the cancelled terminal; the stream tears down
        // with the legacy abort framing.
        engine.manualContinuation?.yield(
            .finished(reason: .cancelled, usage: CBv2Usage(promptTokens: 5, completionTokens: 0)))
        engine.manualContinuation?.finish()
        let (events, _) = await record(stream)
        #expect(events.last == .error("request cancelled"))
        #expect(await bridge._testEngineRequestId(for: "req-abc") == nil)
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    @Test("cancel for an unknown id is a no-op")
    func cancelUnknownId() async {
        let engine = ScriptedCBv2Engine(script: .manual)
        let bridge = makeBridge(engine: engine)
        await bridge.cancel(requestId: "req-never-submitted")
        #expect(engine.cancelled.isEmpty)
    }

    @Test("runtime fan-out (the ProviderLoop handleCancellation hook path)")
    func runtimeFanOut() async {
        let engine = ScriptedCBv2Engine(script: .manual)
        let bridge = makeBridge(engine: engine)
        let runtime = EngineV2Runtime()
        await runtime.register(modelId: "gemma-4-27b-it", bridge: bridge)

        // Hold the stream for the whole test: dropping it would fire
        // `onTermination(.cancelled)` and race a second (idempotent)
        // engine cancel into the count assertions below.
        let stream = await bridge.submit(request: makeRequest(), requestId: "req-xyz")
        let owned = await runtime.cancel(requestId: "req-xyz")
        #expect(owned)
        #expect(engine.cancelled.count == 1)

        // Unknown id: no bridge owns it (legacy path's request).
        let unowned = await runtime.cancel(requestId: "req-legacy")
        #expect(!unowned)
        #expect(engine.cancelled.count == 1)
        withExtendedLifetime(stream) {}
    }
}

// MARK: - Capacity mapping


@Suite("EngineV2 bridge shutdown")
struct EngineV2ShutdownTests {
    @Test("shutdown drains through the engine")
    func shutdownForwards() async {
        let engine = ScriptedCBv2Engine(script: .manual)
        let bridge = makeBridge(engine: engine)
        await bridge.shutdown()
        #expect(engine.shutdownCalls == 1)
    }
}

// MARK: - Shared-budget KV accounting (fix #2)

// MARK: - Hardening (request-id validation, id overflow, pump lifecycle)

@Suite("EngineV2 bridge hardening")
struct EngineV2HardeningTests {

    @Test("request-id validation: nil / empty / over-long / control chars → fresh id (fix #4)")
    func requestIdValidation() {
        // Valid ids pass through verbatim.
        #expect(EngineV2Bridge.isValidRequestId("req-abc123"))
        #expect(EngineV2Bridge.isValidRequestId(String(repeating: "a", count: 256)))
        #expect(EngineV2Bridge.normalizedRequestId("req-coord-1") == "req-coord-1")
        // Invalid ids are rejected and replaced with a generated one.
        #expect(!EngineV2Bridge.isValidRequestId(""))
        #expect(!EngineV2Bridge.isValidRequestId(String(repeating: "a", count: 257)))
        #expect(!EngineV2Bridge.isValidRequestId("req\u{0}embedded-nul"))
        #expect(!EngineV2Bridge.isValidRequestId("req\u{7f}del"))
        #expect(!EngineV2Bridge.isValidRequestId("line\nbreak"))
        // nil and each invalid form normalize to a fresh, valid `req-…` id.
        for bad in [nil, "", "line\nbreak", String(repeating: "z", count: 300)] {
            let normalized = EngineV2Bridge.normalizedRequestId(bad)
            #expect(normalized.hasPrefix("req-"))
            #expect(EngineV2Bridge.isValidRequestId(normalized))
        }
    }

    @Test("a malformed request-id is normalized before it becomes a cancel handle")
    func malformedIdNormalizedInSubmit() async {
        let engine = ScriptedCBv2Engine(script: .manual)
        let bridge = makeBridge(engine: engine)
        // Submit with a control-char id: the bridge must NOT key its state on it.
        let stream = await bridge.submitTokenized(
            promptTokens: [1, 2, 3], request: makeRequest(), requestId: "bad\u{0}id")
        // The raw malformed id maps to nothing (a fresh id was minted).
        #expect(await bridge._testEngineRequestId(for: "bad\u{0}id") == nil)
        // Exactly one request is live under the normalized id.
        let counters = await bridge._testCounters()
        #expect(counters.active == 1)
        withExtendedLifetime(stream) {}
    }

    @Test("shutdown cancels live pump tasks and releases their reservations (fix #7)")
    func shutdownCancelsLivePumps() async {
        // A manual engine keeps the request in-flight (stream never finishes)
        // so the pump is parked on `for await`. Shutdown must cancel it.
        let engine = ScriptedCBv2Engine(script: .manual)
        let budget = TestBudgets.ample()
        let bridge = makeBridge(engine: engine, kvBytesPerToken: 4000, kvBudget: budget)
        let stream = await bridge.submitTokenized(
            promptTokens: [1, 2, 3, 4, 5], request: makeRequest(maxTokens: 16),
            requestId: "req-live-1")
        // Reservation is recorded synchronously with admission (no poll), and
        // the pump task is tracked for shutdown.
        #expect(await budget.outstandingReservedBytes() == 84_000)
        #expect(await bridge._testLivePumpCount() == 1)
        let consumer = Task { await record(stream) }

        await bridge.shutdown()
        #expect(engine.shutdownCalls == 1)
        // The cancelled pump unwinds (AsyncStream.next() returns nil under
        // cancellation → teardown path), releasing its reservation and
        // clearing its task handle.
        _ = await consumer.value
        for _ in 0..<200 where await bridge._testLivePumpCount() != 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await bridge._testLivePumpCount() == 0)
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    @Test("nextRawId uses wrapping increment (fix #5)")
    func nextRawIdWraps() async {
        // A stream engine so each submit runs to a terminal and self-clears,
        // letting the same provider id be reused across submits.
        let engine = ScriptedCBv2Engine(script: .stream([
            .finished(reason: .stop, usage: CBv2Usage(promptTokens: 1, completionTokens: 0))
        ]))
        let bridge = makeBridge(engine: engine)
        // Two sequential submits mint two distinct engine ids (raw 1, 2).
        _ = await record(await bridge.submitTokenized(
            promptTokens: [1], request: makeRequest(), requestId: "r1"))
        _ = await record(await bridge.submitTokenized(
            promptTokens: [1], request: makeRequest(), requestId: "r2"))
        #expect(engine.submitted.count == 2)
        #expect(engine.submitted[0].id == CBv2RequestID(1))
        #expect(engine.submitted[1].id == CBv2RequestID(2))
    }
}

// MARK: - Logprobs channel cap (fix #8)

@Suite("EngineV2 logprobs channel bounding")
struct EngineV2LogprobsChannelCapTests {

    private func entry(_ token: String) -> SSETokenLogprob {
        SSETokenLogprob(token: token, logprob: -0.1, bytes: nil, topLogprobs: [])
    }

    @Test("undrained channel is capped at maxEntries with drop-oldest")
    func channelCapsWithDropOldest() {
        let channel = EngineV2LogprobsChannel()
        let cap = EngineV2LogprobsChannel.maxEntries
        // Append cap + 10 entries, tagged by index, without ever draining.
        for i in 0..<(cap + 10) {
            channel.append([entry("t\(i)")])
        }
        let drained = channel.drain()
        // Buffer never exceeds the cap; the 10 OLDEST were dropped.
        #expect(drained.count == cap)
        #expect(channel.droppedCount == 10)
        // The freshest entries are retained (drop-oldest): first kept is t10,
        // last is t<cap+9>.
        #expect(drained.first?.token == "t10")
        #expect(drained.last?.token == "t\(cap + 9)")
    }

    @Test("under the cap nothing is dropped; drain empties the buffer")
    func channelUnderCapNoDrops() {
        let channel = EngineV2LogprobsChannel()
        for i in 0..<100 { channel.append([entry("t\(i)")]) }
        #expect(channel.droppedCount == 0)
        #expect(channel.drain().count == 100)
        #expect(channel.drain().isEmpty)
    }
}
