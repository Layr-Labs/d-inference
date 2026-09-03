import Foundation
import Testing
import MLXLMCommon
@testable import ProviderCore

@Suite("RequestProfileBuilder")
struct RequestProfileBuilderTests {

    /// The stamp order the coordinator's ingress validator enforces over
    /// PRESENT stamps: `dequeued ≤ decrypted ≤ parsed ≤ admission ≤
    /// engine_submit ≤ engine_admitted ≤ first_delta ≤ last_delta ≤
    /// terminal_built ≤ terminal_sent ≤ total` (the other stamps here are
    /// marked in production order but only pairwise-validated). `first_frame`
    /// is deliberately absent: its only relation is `first_delta ≤ first_frame`.
    private static let orderedStamps: [RequestProfileBuilder.Stamp] = [
        .dequeued, .decrypted, .parsed, .admission, .acceptedSent,
        .loadWaitStart, .loadWaitEnd, .taskSpawned,
        .promptPrepStart, .promptPrepEnd,
        .engineSubmit, .engineAdmitted, .firstDelta, .lastDelta,
        .terminalBuilt, .terminalSent,
    ]

    private static func orderedOffsets(_ p: InferenceProfile) -> [Int64?] {
        [
            p.dequeuedUs, p.decryptedUs, p.parsedUs, p.admissionUs, p.acceptedSentUs,
            p.loadWaitStartUs, p.loadWaitEndUs, p.taskSpawnedUs,
            p.promptPrepStartUs, p.promptPrepEndUs,
            p.engineSubmitUs, p.engineAdmittedUs, p.firstDeltaUs, p.lastDeltaUs,
            p.terminalBuiltUs, p.terminalSentUs, p.totalUs,
        ]
    }

    @Test func stampsAreMonotonicFirstWriteWinsAndAtLeastOneMicrosecond() async throws {
        let builder = RequestProfileBuilder()
        for stamp in Self.orderedStamps {
            builder.mark(stamp)
        }
        let first = builder.wireObject()
        let offsets = Self.orderedOffsets(first)
        for (index, offset) in offsets.enumerated() {
            let value = try #require(offset, "stamp \(index) missing")
            #expect(value >= 1)
            if index > 0, let previous = offsets[index - 1] {
                #expect(previous <= value, "stamp \(index) precedes stamp \(index - 1)")
            }
        }

        // First write wins: re-marking after a real delay must not move it.
        try await Task.sleep(for: .milliseconds(3))
        builder.mark(.decrypted)
        builder.mark(.terminalSent, at: .now)
        let second = builder.wireObject()
        #expect(second.decryptedUs == first.decryptedUs)
        #expect(second.terminalSentUs == first.terminalSentUs)
        // total_us is recomputed on every materialization and only grows.
        let firstTotal = try #require(first.totalUs)
        let secondTotal = try #require(second.totalUs)
        #expect(secondTotal >= firstTotal)
        #expect(second.schema == 1)
        #expect(second.wallMs == builder.wallMs)
    }

    @Test func fullLifecycleStaysWithinThirtyLockAcquisitions() {
        // Mirrors the production call sequence site-for-site, including the
        // cancel path and the SSD-abandon reserve retry (worst case).
        let builder = RequestProfileBuilder()
        // ProviderLoop+InferenceHandler (actor side)
        builder.mark(.dequeued)
        builder.mark(.decrypted)
        builder.mark(.parsed)
        builder.mark(.admission)
        builder.mark(.acceptedSent)
        builder.update { f, now in
            f.mark(.loadWaitStart, offsetUs: now)
            f.set(.loadCold, false)
            f.set(.loadParked, false)
        }
        builder.mark(.loadWaitEnd)
        builder.mark(.taskSpawned)
        // MultiModelBatchSchedulerEngine
        builder.mark(.promptPrepStart)
        builder.update { f, now in
            f.mark(.promptPrepEnd, offsetUs: now)
            f.set(.promptTokens, 812)
        }
        builder.markDuration(.toolConstraint, start: .now)
        // EngineV2Bridge.submitTokenized
        builder.markDuration(.ssdStage, start: .now)
        builder.markDuration(.kvReserve, start: .now)
        builder.markDuration(.kvReserve, start: .now)  // retry after SSD abandon
        builder.update { f, now in
            f.mark(.engineSubmit, offsetUs: now)
            f.set(.runningAtAdmit, 2)
            f.set(.waitingAtAdmit, 0)
            f.set(.kvBytesInUseAtAdmit, 1 << 30)
            f.set(.kvBytesCapacity, 1 << 33)
            f.set(.stepsAtSubmit, 15_320)
            f.set(.queuedPrefillTokensAtAdmit, 0)
            f.set(.mtpActive, true)
            f.set(.partialPrefillCap, 1)
            f.deadlineMode = .projected
        }
        builder.update { f, now in
            f.mark(.engineAdmitted, offsetUs: now)
            f.set(.projectedPrefillTokens, 812)
            f.set(.projectedDecodeTokens, 256)
            f.set(.projectedServiceUs, 3_500_000)
            f.set(.budgetRemainingAtAdmitUs, 28_500_000)
        }
        // pump
        builder.mark(.firstDelta, at: .now, notBefore: .engineAdmitted)
        // handler frames loop
        builder.mark(.firstFrame)
        // cancel path (handleCancellation → bridge scan → finished check →
        // frames-loop exit)
        _ = builder.markCancelReceived()
        builder.update { f, _ in
            if f.count(.tokensAtCancel) == nil { f.set(.tokensAtCancel, 140) }
        }
        builder.recordTokensAfterCancelIfFinished()
        builder.mark(.cancelAborted)
        builder.mark(.cancelAborted)  // post-loop re-stamp (no-op)
        // bridge finish
        builder.update { f, now in
            f.mark(.lastDelta, offsetUs: now)
            f.set(.stepsAtFinish, 15_470)
            if let atCancel = f.count(.tokensAtCancel) {
                f.set(.tokensAfterCancel, 147 - atCancel)
            }
        }
        // handler terminal
        builder.update { f, now in
            f.set(.framesEmitted, 147)
            f.set(.bytesEmitted, 18_944)
            f.set(.usageRecovered, false)
            f.thermalState = .nominal
            f.set(.lowPowerMode, false)
            f.set(.mlxActiveBytesAtFinish, 1 << 34)
            f.set(.mlxPeakBytes, 1 << 34)
            f.add(.seSign, us: 1_200)
            f.mark(.terminalBuilt, offsetUs: now)
        }
        // SendHandle.send
        builder.markDuration(.flush, start: .now)
        builder.mark(.terminalSent)
        // task defer + codec
        _ = builder.cancelSummary()
        let wire = builder.wireObject()

        // The count read itself is one more acquisition.
        #expect(builder.lockAcquisitionCount <= 30)
        #expect(wire.tokensAfterCancel == 7)
        #expect(wire.cancelStage == .decode)
        #expect(wire.kvReserveUs != nil)
        #expect(wire.engine == nil)
    }

    @Test func wireObjectWithEveryBuilderFieldEncodesWithin4096Bytes() throws {
        let builder = RequestProfileBuilder(
            suspendingAnchor: .now, continuousAnchor: .now, wallMs: 1_788_307_200_123)
        let maxUs: Int64 = 3_600_000_000
        let maxCount: Int64 = 1_000_000_000
        let maxBytes: Int64 = 1 << 48
        builder.update { f, _ in
            for stamp in RequestProfileBuilder.Stamp.allCases {
                f.mark(stamp, offsetUs: maxUs)
            }
            for duration in RequestProfileBuilder.DurationField.allCases {
                f.add(duration, us: maxUs)
            }
            for count in RequestProfileBuilder.CountField.allCases {
                switch count {
                case .bytesEmitted, .kvBytesInUseAtAdmit, .kvBytesCapacity,
                    .mlxActiveBytesAtFinish, .mlxPeakBytes:
                    f.set(count, maxBytes)
                case .projectedServiceUs, .budgetRemainingAtAdmitUs:
                    f.set(count, maxUs)
                default:
                    f.set(count, maxCount)
                }
            }
            for flag in RequestProfileBuilder.FlagField.allCases {
                f.set(flag, true)
            }
            f.deadlineMode = .projected
            f.thermalState = .critical
            f.cancelStage = .postTerminal
        }
        let wire = builder.wireObject()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(wire)
        #expect(data.count <= 4096, "profile encoded to \(data.count) bytes")
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // The bridge-internal cancel snapshot never reaches the wire.
        #expect(object["tokens_at_cancel"] == nil)
        #expect(object["tokens_after_cancel"] as? Int64 == maxCount)
        #expect(object["mlx_peak_bytes"] as? Int64 == maxBytes)
        #expect(object["cancel_stage"] as? String == "post_terminal")
        #expect(object["engine"] == nil)
    }

    @Test func sleptIsNonNegativeAndTotalCoversEveryStamp() async throws {
        let builder = RequestProfileBuilder()
        builder.mark(.dequeued)
        try await Task.sleep(for: .milliseconds(2))
        builder.mark(.terminalBuilt)
        let wire = builder.wireObject()
        let slept = try #require(wire.sleptUs)
        #expect(slept >= 0)
        let total = try #require(wire.totalUs)
        let terminalBuilt = try #require(wire.terminalBuiltUs)
        #expect(total >= terminalBuilt)
        #expect(terminalBuilt >= 2_000)
    }

    @Test func cancelStageDerivesFromStampsPresentAtReceipt() {
        func stage(after stamps: [RequestProfileBuilder.Stamp]) -> CancelStage? {
            let builder = RequestProfileBuilder()
            for stamp in stamps { builder.mark(stamp) }
            let stage = builder.markCancelReceived()
            #expect(builder.wireObject().cancelStage == stage)
            return stage
        }
        #expect(stage(after: [.dequeued, .parsed]) == .preAccept)
        #expect(stage(after: [.dequeued, .acceptedSent, .loadWaitStart]) == .preEngine)
        #expect(stage(after: [.acceptedSent, .engineSubmit, .engineAdmitted]) == .prefill)
        #expect(stage(after: [.acceptedSent, .engineSubmit, .firstDelta]) == .decode)
        #expect(stage(after: [.acceptedSent, .engineSubmit, .firstDelta, .terminalBuilt])
            == .postTerminal)

        // First cancel wins; the second call reports nothing to count.
        let builder = RequestProfileBuilder()
        builder.mark(.acceptedSent)
        #expect(builder.markCancelReceived() == .preEngine)
        #expect(builder.markCancelReceived() == nil)
        let summary = builder.cancelSummary()
        #expect(summary.abortNs == nil)
        builder.mark(.cancelAborted)
        let abortNs = builder.cancelSummary().abortNs
        #expect(abortNs != nil)
        #expect((abortNs ?? -1) >= 0)
    }

    @Test func crossClockAdmittedStampIsClampedAtOrAfterSubmit() throws {
        let builder = RequestProfileBuilder()
        builder.mark(.engineSubmit)
        // An admission instant converted from the continuous clock that lands
        // (through jitter) BEFORE the submit stamp must be clamped up.
        let earlier = builder.suspendingInstant(
            fromContinuous: ContinuousClock.now - .milliseconds(5))
        builder.mark(.engineAdmitted, at: earlier, notBefore: .engineSubmit)
        let wire = builder.wireObject()
        let admitted = try #require(wire.engineAdmittedUs)
        let submitted = try #require(wire.engineSubmitUs)
        #expect(admitted >= submitted)
    }

    @Test func lateDeltaStampsAreClampedToTerminalBuilt() async throws {
        // Cancel path: the handler builds its terminal before the engine's
        // late `.delta`/`.finished` arrive; the bridge's stamps must be pinned
        // to `terminal_built` so `first ≤ last ≤ terminal_built` holds.
        let builder = RequestProfileBuilder()
        builder.mark(.engineSubmit)
        builder.mark(.engineAdmitted)
        builder.update { f, now in f.mark(.terminalBuilt, offsetUs: now) }
        try await Task.sleep(for: .milliseconds(3))
        let late = SuspendingClock.now
        builder.mark(.firstDelta, at: late, notBefore: .engineAdmitted, notAfter: .terminalBuilt)
        let lateOffset = builder.offsetUs(of: late)
        builder.update { f, _ in
            f.mark(.lastDelta, offsetUs: f.clamp(lateOffset, notBefore: .firstDelta, notAfter: .terminalBuilt))
        }
        let wire = builder.wireObject()
        let admitted = try #require(wire.engineAdmittedUs)
        let first = try #require(wire.firstDeltaUs)
        let last = try #require(wire.lastDeltaUs)
        let terminal = try #require(wire.terminalBuiltUs)
        #expect(lateOffset > terminal, "the raw instant really was after the terminal")
        #expect(admitted <= first)
        #expect(first <= last)
        #expect(last <= terminal)
        #expect(first == terminal)

        // Without a terminal present the ceiling is inert (absent stamps are
        // skipped by the coordinator's order check too).
        let open = RequestProfileBuilder()
        open.mark(.engineAdmitted)
        open.mark(.firstDelta, at: .now, notBefore: .engineAdmitted, notAfter: .terminalBuilt)
        let openWire = open.wireObject()
        let openAdmitted = try #require(openWire.engineAdmittedUs)
        let openFirst = try #require(openWire.firstDeltaUs)
        #expect(openFirst >= openAdmitted)
        #expect(openWire.terminalBuiltUs == nil)
    }

    @Test func budgetRemainingClampsNegativeToZero() {
        // Legacy-path read happens after the submit returned; an expired
        // deadline must not produce a negative `budget_remaining_at_admit_us`
        // (whole profile would be `range`-invalid on the coordinator).
        #expect(RequestProfileBuilder.budgetRemainingUs(.milliseconds(-5)) == 0)
        #expect(RequestProfileBuilder.budgetRemainingUs(.zero) == 0)
        #expect(RequestProfileBuilder.budgetRemainingUs(.milliseconds(28_500)) == 28_500_000)
        let expired = FirstContentDeadline(
            relativeBudgetMilliseconds: 1, receivedAt: ContinuousClock.now - .seconds(1))
        #expect(RequestProfileBuilder.budgetRemainingUs(expired.remainingDuration()) == 0)
    }

    @Test func terminalBuiltFreezesTheOrderChainForLateStamps() async throws {
        // A plain `mark` (no explicit ceiling) of a chain stamp after the
        // terminal exists is pinned to `terminal_built`; non-chain stamps
        // (terminal_sent, cancel_*) are unaffected.
        let builder = RequestProfileBuilder()
        builder.mark(.engineSubmit)
        builder.update { f, now in f.mark(.terminalBuilt, offsetUs: now) }
        try await Task.sleep(for: .milliseconds(3))
        builder.mark(.engineAdmitted)
        builder.mark(.firstDelta)
        builder.update { f, now in f.mark(.lastDelta, offsetUs: now) }
        builder.mark(.terminalSent)
        builder.mark(.cancelAborted)
        let wire = builder.wireObject()
        let terminal = try #require(wire.terminalBuiltUs)
        #expect(wire.engineAdmittedUs == terminal)
        #expect(wire.firstDeltaUs == terminal)
        #expect(wire.lastDeltaUs == terminal)
        #expect(try #require(wire.terminalSentUs) > terminal)
        #expect(try #require(wire.cancelAbortedUs) > terminal)
    }

    @Test func wireObjectSaturatesAtTheCoordinatorRanges() throws {
        let builder = RequestProfileBuilder()
        builder.update { f, _ in
            f.mark(.engineSubmit, offsetUs: 5_000_000_000)      // > 3.6e9 µs
            f.mark(.engineAdmitted, offsetUs: 6_000_000_000)
            f.set(.stepsAtSubmit, 7_000_000_000)                 // lifetime engine counter
            f.set(.stepsAtFinish, 7_000_000_100)
            f.set(.partialPrefillCap, Int64.max)
            f.set(.kvBytesCapacity, 1 << 50)                     // > 2^48
            f.set(.tokensAfterCancel, -3)                        // never negative on the wire
            f.add(.kvReserve, us: 9_000_000_000)
            var engine = EngineProfile()
            engine.finishedNs = 9_000_000_000_000                // > 3.6e12
            engine.decodeSteps = 3_000_000_000
            engine.batchRowsMin = -1
            f.engine = engine
        }
        let wire = builder.wireObject()
        #expect(wire.engineSubmitUs == InferenceProfile.maxWireMicros)
        #expect(wire.engineAdmittedUs == InferenceProfile.maxWireMicros)
        // Order preserved under saturation (min is monotone).
        #expect(try #require(wire.engineSubmitUs) <= #require(wire.engineAdmittedUs))
        #expect(wire.stepsAtSubmit == InferenceProfile.maxWireCount)
        #expect(wire.stepsAtFinish == InferenceProfile.maxWireCount)
        #expect(wire.partialPrefillCap == InferenceProfile.maxWireCount)
        #expect(wire.kvBytesCapacity == InferenceProfile.maxWireBytes)
        #expect(wire.tokensAfterCancel == 0)
        #expect(wire.kvReserveUs == InferenceProfile.maxWireMicros)
        #expect(wire.engine?.finishedNs == InferenceProfile.maxWireNanos)
        #expect(wire.engine?.decodeSteps == InferenceProfile.maxWireCount)
        #expect(wire.engine?.batchRowsMin == 0)
        // A pure-struct saturation is idempotent.
        #expect(wire.saturatedToWireRanges() == wire)
    }

    @Test func totalNeverPrecedesAConcurrentlyPresentStamp() async throws {
        // `total_us` and the field snapshot are taken under one lock: no
        // stamp that appears in a materialization may exceed its `total`.
        // A FRESH builder per round so every round races a real first write
        // (first-write-wins would otherwise make rounds 2…n inert).
        var violations = 0
        for _ in 0..<2_000 {
            let builder = RequestProfileBuilder()
            builder.mark(.dequeued)
            let wire: InferenceProfile = await withTaskGroup(of: InferenceProfile?.self) { group in
                group.addTask {
                    builder.update { f, now in f.mark(.terminalSent, offsetUs: now) }
                    builder.mark(.terminalBuilt)
                    return nil
                }
                group.addTask { builder.wireObject() }
                var captured: InferenceProfile?
                for await result in group {
                    if let result { captured = result }
                }
                return captured ?? builder.wireObject()
            }
            let total = wire.totalUs ?? 0
            for stamp in [wire.dequeuedUs, wire.terminalSentUs, wire.terminalBuiltUs] {
                if let stamp, stamp > total { violations += 1 }
            }
        }
        #expect(violations == 0)
    }

    @Test func firstFrameIsOrderedOnlyAfterFirstDelta() async throws {
        // One-delta response: the engine's last delta precedes the handler's
        // first content frame. `first_frame` is outside the validator chain,
        // so it must be neither clamped to `last_delta` nor frozen by the
        // terminal; only `first_delta ≤ first_frame` holds.
        let builder = RequestProfileBuilder()
        builder.mark(.engineAdmitted)
        let delta = SuspendingClock.now
        builder.mark(.firstDelta, at: delta, notBefore: .engineAdmitted)
        builder.update { f, _ in
            f.mark(.lastDelta, offsetUs: f.clamp(builder.offsetUs(of: delta), notBefore: .firstDelta))
        }
        try await Task.sleep(for: .milliseconds(3))
        builder.mark(.firstFrame)
        builder.update { f, now in f.mark(.terminalBuilt, offsetUs: now) }
        try await Task.sleep(for: .milliseconds(2))
        let wire = builder.wireObject()
        let firstDelta = try #require(wire.firstDeltaUs)
        let lastDelta = try #require(wire.lastDeltaUs)
        let firstFrame = try #require(wire.firstFrameUs)
        let terminal = try #require(wire.terminalBuiltUs)
        #expect(firstDelta <= firstFrame)
        #expect(lastDelta < firstFrame, "a one-delta response has last_delta before first_frame")
        #expect(lastDelta <= terminal)
        #expect(firstFrame <= terminal)
    }

    @Test func installingTerminalBuiltPinsChainStampsThatAlreadyExceedIt() throws {
        // Interleaving the clock-under-lock rule alone cannot see: a chain
        // stamp with a LATER offset won the lock first, then an EARLIER
        // terminal_built is installed. The terminal install must pin it.
        let builder = RequestProfileBuilder()
        builder.update { f, _ in
            f.mark(.engineSubmit, offsetUs: 1_000)
            f.mark(.firstDelta, offsetUs: 4_000)
            f.mark(.lastDelta, offsetUs: 5_000)
        }
        builder.update { f, _ in f.mark(.terminalBuilt, offsetUs: 3_000) }
        let wire = builder.wireObject()
        #expect(wire.engineSubmitUs == 1_000)
        #expect(wire.firstDeltaUs == 3_000)
        #expect(wire.lastDeltaUs == 3_000)
        #expect(wire.terminalBuiltUs == 3_000)
        // Non-chain stamps are left alone.
        let other = RequestProfileBuilder()
        other.update { f, _ in
            f.mark(.firstFrame, offsetUs: 9_000)
            f.mark(.cancelReceived, offsetUs: 9_500)
            f.mark(.terminalBuilt, offsetUs: 3_000)
        }
        let otherWire = other.wireObject()
        #expect(otherWire.firstFrameUs == 9_000)
        #expect(otherWire.cancelReceivedUs == 9_500)
    }

    @Test func recordTokensAfterCancelIfFinishedCountsZeroOnlyForFinishedRows() {
        // Never reached an engine → nothing recorded.
        let unsubmitted = RequestProfileBuilder()
        unsubmitted.recordTokensAfterCancelIfFinished()
        #expect(unsubmitted.wireObject().tokensAfterCancel == nil)
        // Finished before the cancel landed → explicit 0 (not omitted).
        let finished = RequestProfileBuilder()
        finished.set(.stepsAtFinish, 42)
        finished.recordTokensAfterCancelIfFinished()
        #expect(finished.wireObject().tokensAfterCancel == 0)
        // Already computed by the bridge → untouched.
        let counted = RequestProfileBuilder()
        counted.set(.stepsAtFinish, 42)
        counted.set(.tokensAfterCancel, 5)
        counted.recordTokensAfterCancelIfFinished()
        #expect(counted.wireObject().tokensAfterCancel == 5)
    }

    @Test func durationsSaturateInsteadOfWrapping() {
        let builder = RequestProfileBuilder()
        builder.update { f, _ in
            f.add(.kvReserve, us: .max)
            f.add(.kvReserve, us: 1)
            f.add(.ssdStage, us: .max - 5)
            f.add(.ssdStage, us: 10)
        }
        let wire = builder.wireObject()
        // Pinned at the accumulator's ceiling, then at the wire range — never
        // wrapped negative (which would have clamped to 0).
        #expect(wire.kvReserveUs == InferenceProfile.maxWireMicros)
        #expect(wire.ssdStageUs == InferenceProfile.maxWireMicros)
        // The Duration → µs conversion saturates the same way.
        let huge = Duration.seconds(9_223_372_036_854) + .microseconds(999_999)
        #expect(RequestProfileBuilder.microseconds(huge) == .max)
    }

    @Test func durationsAccumulateAndMicrosecondConversionIsExact() {
        #expect(RequestProfileBuilder.microseconds(.seconds(1) + .microseconds(5)) == 1_000_005)
        #expect(RequestProfileBuilder.microseconds(.nanoseconds(999)) == 0)
        #expect(RequestProfileBuilder.microseconds(.milliseconds(-3)) == -3_000)

        let builder = RequestProfileBuilder()
        let start = SuspendingClock.now
        builder.markDuration(.kvReserve, start: start, end: start + .microseconds(300))
        builder.markDuration(.kvReserve, start: start, end: start + .microseconds(200))
        #expect(builder.wireObject().kvReserveUs == 500)
        // Negative windows clamp to zero rather than subtracting.
        builder.markDuration(.flush, start: start + .microseconds(10), end: start)
        #expect(builder.wireObject().flushUs == 0)
    }
}

@Suite("EngineProfile from CBv2RequestTiming")
struct EngineProfileMappingTests {
    @Test func mapsTimingFieldsAndFoldsFinishReason() {
        var t = CBv2RequestTiming()
        t.admittedNanos = 1_000
        t.firstTokenNanos = 5_000
        t.finishedNanos = 9_000
        t.prefillChunks = 2
        t.decodeSteps = 7
        t.batchRowsSum = 14
        t.batchRowsMin = 1
        t.batchRowsMax = 3
        t.mtpProposed = 4
        t.mtpAccepted = 2
        let p = EngineProfile(timing: t, finishReason: .error("secret prompt text"))
        #expect(p.admittedNs == 1_000)
        #expect(p.kvAllocatedNs == nil, "zero stamps stay nil")
        #expect(p.firstTokenNs == 5_000)
        #expect(p.finishedNs == 9_000)
        #expect(p.prefillChunks == 2 && p.decodeSteps == 7)
        #expect(p.batchRowsSum == 14 && p.batchRowsMin == 1 && p.batchRowsMax == 3)
        #expect(p.mtpProposed == 4 && p.mtpAccepted == 2)
        #expect(p.finishReason == .error, "error text must fold to the bare enum")
        #expect(EngineFinishReason(reason: .stop) == .stop)
        #expect(EngineFinishReason(reason: .length) == .length)
        #expect(EngineFinishReason(reason: .cancelled) == .cancelled)
    }

    @Test func builderEmitsEngineSubObjectOnceSet() throws {
        let b = RequestProfileBuilder()
        #expect(b.wireObject().engine == nil)
        var t = CBv2RequestTiming()
        t.firstTokenNanos = 42
        b.update { f, _ in f.engine = EngineProfile(timing: t, finishReason: .stop) }
        let wire = b.wireObject()
        #expect(wire.engine?.firstTokenNs == 42)
        #expect(wire.engine?.finishReason == .stop)
        let data = try JSONEncoder().encode(wire)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"engine\""))
        #expect(json.contains("\"first_token_ns\":42"))
    }
}
