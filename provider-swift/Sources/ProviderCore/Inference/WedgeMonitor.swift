// Copyright © 2026 Eigen Labs.
//
// WedgeMonitor — pure, low-cardinality engine-health accounting for the
// first-token "wedge" documented in
// docs/reports/2026-06-22-cancel-root-cause-and-fix.md (§C):
//
//   On ~10% of powerful boxes the MLX/Metal first-token path wedges: the
//   provider emits the CPU-only preamble (~104ms) then the first blocking
//   `eval` under the single process-global evalLock never returns, so token
//   production freezes while accept/preamble/heartbeats keep running and
//   `num_running` stays 0 (the wedged request never registers as running).
//
// This type makes that wedge VISIBLE by counting cheap operational signals:
//   • admits          — requests handed to the engine (the preamble path)
//   • firstTokens     — requests that produced a first content token
//   • engine steps    — sampled from EngineCore.stepsExecuted (loop progress)
// The wedge signature is "admits climbing while firstTokens stay flat and the
// engine step counter flatlines."
//
// MEASUREMENT ONLY. Pure value type, no locks, no GPU/eval access, no I/O — it
// never changes inference behavior and never triggers an action. The self-heal
// watchdog that would ACT on `wedgeSuspected(now:)` is intentionally out of
// scope (follow-up PR); this PR only confirms/observes the wedge.
//
// PRIVACY: every field is an operational counter or timestamp. No prompt or
// response content ever flows through here.

import Foundation

struct WedgeMonitor {
    /// Consecutive admits (each emits the CPU-only preamble) producing zero
    /// first tokens before the streak is flagged. The wedge is "born broken"
    /// right after load, so a small N catches it within the first few requests.
    static let suspectConsecutiveAdmits = 3

    /// Minimum duration (seconds) of a zero-first-token admit streak before it
    /// counts as a suspected wedge. Tracks the OpenRouter ~10s TTFT SLA: a
    /// streak this long with no first token is the wedge signature, not a normal
    /// slow prefill (idle prefill p90 only crosses 10s at ~20–32k tokens).
    static let suspectStallSeconds: Double = 10

    // MARK: - Cumulative counters (per load epoch; reset on (re)load)

    /// Requests handed to the engine — i.e. that reach the streaming bridge and
    /// will emit the lock-free preamble. Incremented once per request.
    private(set) var admits: Int = 0
    /// Requests that produced their first content token. Incremented once per
    /// request. `admits > firstTokens` growing without bound ⇒ wedge.
    private(set) var firstTokens: Int = 0

    /// FIFO of admit timestamps for requests CURRENTLY hanging (admitted, no
    /// first token yet, not terminated). The front is the oldest still-hanging
    /// admit, so the dry-streak is measured from it — never from an admit that has
    /// already ended (the bug this replaces, where a mix of old+new admits could
    /// report a wedge before the newer admits had actually stalled). Appended on
    /// admit; the front is removed on a no-first-token terminal; cleared entirely
    /// on a first token (engine proven alive ⇒ nothing is wedged).
    private var hangingAdmitsSince: [ContinuousClock.Instant] = []

    /// Number of admits currently hanging (no first token, not terminated).
    /// Derived from the FIFO so it can never disagree with the streak anchor.
    var consecutiveAdmitsWithoutFirstToken: Int { hangingAdmitsSince.count }

    // MARK: - Wall-clock anchors (ContinuousClock; monotonic, skew-free)

    private(set) var lastAdmitAt: ContinuousClock.Instant?
    private(set) var lastFirstTokenAt: ContinuousClock.Instant?

    // MARK: - Engine-step sampling

    /// Last sampled value of EngineCore.stepsExecuted and when it last advanced.
    /// The engine only increments `stepsExecuted` while it has work, so a
    /// flatline under demand (admits without first tokens) is the loop-frozen
    /// signal that distinguishes a wedge from a genuinely idle box.
    private(set) var lastStepsSample: Int = 0
    private var sawStepSample = false
    private(set) var lastStepAdvanceAt: ContinuousClock.Instant?

    // MARK: - Recording (called from the bridge lifecycle)

    /// A request was handed to the engine (preamble path). Call once per request.
    mutating func recordAdmit(now: ContinuousClock.Instant) {
        admits += 1
        hangingAdmitsSince.append(now)
        lastAdmitAt = now
    }

    /// A request produced its first content token. Call once per request. A
    /// single first token proves the engine + global eval lock are alive, so it
    /// fully clears the wedge suspicion (the whole hanging set).
    mutating func recordFirstToken(now: ContinuousClock.Instant) {
        firstTokens += 1
        hangingAdmitsSince.removeAll()
        lastFirstTokenAt = now
    }

    /// An admitted request terminated WITHOUT ever producing a first token — a
    /// pre-first-token cancel/abort/error or a zero-token finish. It is no longer
    /// hanging, so drop it from the currently-hanging streak (floored at 0) and
    /// clear the streak anchor once nothing is left hanging. This keeps
    /// `consecutiveAdmitsWithoutFirstToken` tracking admits that are STILL
    /// hanging, not historical no-token requests: `client_gone` cancels (which
    /// end before the first token) are common here and would otherwise pollute
    /// the streak into a false wedge on a healthy box. Do NOT call for a request
    /// that produced a first token (that path uses `recordFirstToken`).
    mutating func recordTerminalWithoutFirstToken() {
        // One hanging admit ended without a first token. Drop the OLDEST hanging
        // timestamp so the streak re-anchors to the next-oldest STILL-hanging
        // admit — never to one that has already ended. On a real wedge no first
        // tokens occur and requests cancel in admit order, so the front tracks the
        // true oldest hanging admit; in mixed traffic this is conservative (may
        // under-count), and the step-flatline gate in `wedgeSuspected` is the
        // backstop against false positives.
        if !hangingAdmitsSince.isEmpty {
            hangingAdmitsSince.removeFirst()
        }
    }

    /// Sample the engine's cumulative step counter; stamp the advance time when
    /// it moves so `secondsSinceLastStep(now:)` can report a flatline. Idempotent
    /// — safe to call from both the heartbeat and the liveness tick.
    mutating func sampleSteps(_ steps: Int, now: ContinuousClock.Instant) {
        if !sawStepSample || steps > lastStepsSample {
            lastStepAdvanceAt = now
        }
        lastStepsSample = steps
        sawStepSample = true
    }

    /// Reset on (re)load: a fresh engine starts at `stepsExecuted == 0` and a
    /// reload clears any wedge, so the per-load counters start clean.
    mutating func reset() { self = WedgeMonitor() }

    // MARK: - Derived signals (read on the heartbeat / telemetry path)

    /// Seconds since the engine step counter last advanced; 0 if never sampled.
    /// Only meaningful under demand — an idle engine also flatlines (it does not
    /// step), so the coordinator pairs this with `admits`/`numRunning`.
    func secondsSinceLastStep(now: ContinuousClock.Instant) -> Double {
        guard let at = lastStepAdvanceAt else { return 0 }
        return Self.seconds(now - at)
    }

    /// Seconds since the last first content token; 0 if none yet this load.
    func secondsSinceLastFirstToken(now: ContinuousClock.Instant) -> Double {
        guard let at = lastFirstTokenAt else { return 0 }
        return Self.seconds(now - at)
    }

    /// Duration (s) the OLDEST still-hanging admit has waited with no first token;
    /// 0 if nothing is hanging. Climbs on a "born broken" box that never produced
    /// a first token.
    func dryStreakSeconds(now: ContinuousClock.Instant) -> Double {
        guard let oldest = hangingAdmitsSince.first else { return 0 }
        return Self.seconds(now - oldest)
    }

    /// The Part C primitive — the full three-part wedge signature:
    ///   1. ≥ N consecutive admits are hanging (emitted preamble, 0 first token),
    ///   2. that streak has lasted ≥ T seconds, AND
    ///   3. the engine step counter has been frozen for ≥ T seconds.
    /// All three are required. The step-frozen term (3) is what separates a real
    /// wedge from a legitimately slow prefill — e.g. three big-prompt requests
    /// that each take >10 s but whose `stepsExecuted` keeps advancing are NOT a
    /// wedge and must not trip. A never-sampled monitor reports
    /// `secondsSinceLastStep == 0`, so it conservatively does not trip until
    /// steps have actually been observed frozen. MEASUREMENT ONLY (heartbeat +
    /// telemetry event); no restart/derouting action is taken in this PR.
    func wedgeSuspected(now: ContinuousClock.Instant) -> Bool {
        consecutiveAdmitsWithoutFirstToken >= Self.suspectConsecutiveAdmits
            && dryStreakSeconds(now: now) >= Self.suspectStallSeconds
            && secondsSinceLastStep(now: now) >= Self.suspectStallSeconds
    }

    /// `ContinuousClock.Duration` → seconds (Double).
    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }
}
