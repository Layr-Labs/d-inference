// Per-request profile accumulator for the system profiler (slice 2).
//
// One instance per coordinator inference request, created at WebSocket frame
// receipt (`CoordinatorClient.handleIncomingFrame`) and threaded through the
// request path exactly like `FirstContentDeadline` / `EngineV2RequestUsageSignal`.
// At the terminal it is materialized into the `InferenceProfile` wire object.
//
// CLOCKS (plan v2 P3). The anchor and every stamp are on `SuspendingClock`
// (mach_absolute_time — the engine's `DispatchTime` domain, so slice 3's
// engine offsets join this chain without a cross-clock subtraction). The
// `ContinuousClock` `receivedAt` that drives deadlines is untouched; it is
// only read here to derive `slept_us` = continuous Δ − suspending Δ.
//
// HOT PATH (plan v2 P4). ≤ 30 lock acquisitions per request BY CONSTRUCTION:
// every stamp site is a single `mark`/`update`, multi-field sites batch
// their writes into one `update`, and NOTHING here is called per token — the
// bridge pump keeps a local `lastDeltaAt` and writes it once at finish.
// `lockAcquisitions` is counted inside the lock so a test can assert the
// budget over a scripted full lifecycle.
//
// CLOSED. Setters accept integers, bools, durations, instants and the closed
// enums only. There is no `String` parameter on this type.

import Foundation

public final class RequestProfileBuilder: @unchecked Sendable {

    // MARK: - Field vocabularies

    /// Offsets (µs from the anchor). First write wins; the stored value is
    /// clamped to ≥ 1 so "present" is never confused with "at t0".
    public enum Stamp: Int, CaseIterable, Sendable {
        case dequeued
        case decrypted
        case parsed
        case admission
        case acceptedSent
        case loadWaitStart
        case loadWaitEnd
        case taskSpawned
        case promptPrepStart
        case promptPrepEnd
        case engineSubmit
        case engineAdmitted
        case firstDelta
        case firstFrame
        case lastDelta
        case terminalBuilt
        case terminalSent
        case cancelReceived
        case cancelAborted
    }

    /// Durations (µs). Accumulate: a second write ADDS (e.g. the shared-KV
    /// reserve that retries after abandoning an SSD staging).
    public enum DurationField: Int, CaseIterable, Sendable {
        case toolConstraint
        case visionPrep
        case ssdStage
        case kvReserve
        case flush
        case seSign
    }

    /// Counts / bytes. Last write wins.
    public enum CountField: Int, CaseIterable, Sendable {
        case promptTokens
        case framesEmitted
        case bytesEmitted
        case runningAtAdmit
        case waitingAtAdmit
        case queuedPrefillTokensAtAdmit
        case kvBytesInUseAtAdmit
        case kvBytesCapacity
        case stepsAtSubmit
        case stepsAtFinish
        case projectedPrefillTokens
        case projectedDecodeTokens
        case projectedServiceUs
        case budgetRemainingAtAdmitUs
        case partialPrefillCap
        case mlxActiveBytesAtFinish
        case mlxPeakBytes
        case tokensAfterCancel
        /// Bridge-internal: completion tokens observed when the cancel reached
        /// the engine bridge. Not on the wire; `tokensAfterCancel` is derived
        /// from it at finish.
        case tokensAtCancel
    }

    public enum FlagField: Int, CaseIterable, Sendable {
        case usageRecovered
        case loadCold
        case loadParked
        case mtpActive
        case lowPowerMode
    }

    /// Mutable view handed to `update` so a multi-field site pays ONE lock.
    public struct Fields {
        fileprivate var stamps: [Int64?]
        fileprivate var durations: [Int64?]
        fileprivate var counts: [Int64?]
        fileprivate var flags: [Bool?]
        public var deadlineMode: DeadlineMode?
        public var thermalState: ProfileThermalState?
        public var cancelStage: CancelStage?
        /// Engine sub-object copied once at finish from `CBv2Usage.timing`.
        public var engine: EngineProfile?
        /// Cumulative-counter hook fired by the bridge when `tokens_after_cancel`
        /// is computed at finish. Installed at handler entry (same lock as the
        /// `dequeued` stamp) so the heartbeat counter lands even when the
        /// cancelled terminal already went out before the engine finished.
        public var onTokensAfterCancel: (@Sendable (Int64) -> Void)?

        fileprivate init() {
            stamps = Array(repeating: nil, count: Stamp.allCases.count)
            durations = Array(repeating: nil, count: DurationField.allCases.count)
            counts = Array(repeating: nil, count: CountField.allCases.count)
            flags = Array(repeating: nil, count: FlagField.allCases.count)
        }

        /// Clamp an offset into the window of two already-present stamps so a
        /// late or cross-clock write cannot violate the coordinator's order
        /// chain. The ceiling wins over the floor (a stamp that arrives after
        /// the terminal was built is pinned to the terminal, never past it).
        public func clamp(
            _ offsetUs: Int64, notBefore floor: Stamp? = nil, notAfter ceiling: Stamp? = nil
        ) -> Int64 {
            var value = offsetUs
            if let floor, let floorOffset = offset(floor) { value = max(value, floorOffset) }
            if let ceiling, let ceilingOffset = offset(ceiling) { value = min(value, ceilingOffset) }
            return value
        }

        /// Stamps the coordinator validates as a chain ending at
        /// `terminal_built` (`dequeued ≤ decrypted ≤ parsed ≤ admission ≤
        /// engine_submit ≤ engine_admitted ≤ first_delta ≤ last_delta ≤
        /// terminal_built ≤ terminal_sent ≤ total`). `first_frame` is NOT in
        /// the chain: the coordinator's validator does not order `first_frame`
        /// at all. `first_delta ≤ first_frame` is a PROVIDER-SIDE invariant
        /// only (the frames loop cannot see a content frame before the pump
        /// saw its delta); a one-delta response legitimately has
        /// `last_delta < first_frame`, so nothing here clamps `first_frame`
        /// against `last_delta` or against the terminal.
        /// Once the terminal is built the builder is FROZEN for the chain: a
        /// later write (an engine `.delta`/`.finished` that lands after the
        /// handler's cancelled or encryption-error terminal, whose upstream
        /// cancel is only scheduled asynchronously) is pinned to
        /// `terminal_built`, never past it — and installing `terminal_built`
        /// itself pins any chain stamp that already exceeds it (defensive
        /// against every interleaving, not just the clock-under-lock rule).
        private static let terminalChain: Set<Int> = [
            Stamp.dequeued, .decrypted, .parsed, .admission, .engineSubmit,
            .engineAdmitted, .firstDelta, .lastDelta,
        ].reduce(into: []) { $0.insert($1.rawValue) }

        /// First-write-wins stamp at `offsetUs` (clamped ≥ 1, and to
        /// `terminal_built` for chain stamps once the terminal exists).
        public mutating func mark(_ stamp: Stamp, offsetUs: Int64) {
            guard stamps[stamp.rawValue] == nil else { return }
            var value = max(1, offsetUs)
            if Self.terminalChain.contains(stamp.rawValue),
                let terminal = stamps[Stamp.terminalBuilt.rawValue]
            {
                value = min(value, terminal)
            }
            stamps[stamp.rawValue] = value
            if stamp == .terminalBuilt {
                for raw in Self.terminalChain where (stamps[raw] ?? 0) > value {
                    stamps[raw] = value
                }
            }
        }

        public func offset(_ stamp: Stamp) -> Int64? {
            stamps[stamp.rawValue]
        }

        /// Saturating accumulation: an overflow pins at `.max` (the wire
        /// boundary then reports the range ceiling), never wraps negative.
        public mutating func add(_ field: DurationField, us: Int64) {
            let clamped = max(0, us)
            let (sum, overflow) = (durations[field.rawValue] ?? 0).addingReportingOverflow(clamped)
            durations[field.rawValue] = overflow ? .max : sum
        }

        public mutating func set(_ field: CountField, _ value: Int64) {
            counts[field.rawValue] = value
        }

        public func count(_ field: CountField) -> Int64? {
            counts[field.rawValue]
        }

        public mutating func set(_ field: FlagField, _ value: Bool) {
            flags[field.rawValue] = value
        }
    }

    // MARK: - State

    private let lock = NSLock()
    private var fields = Fields()
    private var lockAcquisitions = 0

    /// Anchor `t0p`: the WebSocket frame receipt instant.
    public let suspendingAnchor: SuspendingClock.Instant
    /// The same instant on the deadline clock, read ONLY for `slept_us`.
    public let continuousAnchor: ContinuousClock.Instant
    /// Untrusted wall anchor (epoch ms) captured once at construction.
    public let wallMs: Int64

    public init(
        suspendingAnchor: SuspendingClock.Instant = .now,
        continuousAnchor: ContinuousClock.Instant = .now,
        wallMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.suspendingAnchor = suspendingAnchor
        self.continuousAnchor = continuousAnchor
        self.wallMs = wallMs
    }

    // MARK: - Time helpers

    @inline(__always)
    static func microseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        let (scaled, overflow) = components.seconds.multipliedReportingOverflow(by: 1_000_000)
        if overflow { return components.seconds < 0 ? .min : .max }
        let fraction = components.attoseconds / 1_000_000_000_000
        let (sum, sumOverflow) = scaled.addingReportingOverflow(fraction)
        return sumOverflow ? (scaled < 0 ? .min : .max) : sum
    }

    /// Offset (µs) of an instant from the anchor. Lock-free.
    @inline(__always)
    public func offsetUs(of instant: SuspendingClock.Instant) -> Int64 {
        Self.microseconds(instant - suspendingAnchor)
    }

    /// Convert an engine-supplied `ContinuousClock` instant into this
    /// builder's suspending domain. Only valid when no sleep can have occurred
    /// between `instant` and now (µs-scale windows); callers clamp ordering.
    @inline(__always)
    public func suspendingInstant(
        fromContinuous instant: ContinuousClock.Instant
    ) -> SuspendingClock.Instant {
        let sinceThen = ContinuousClock.now - instant
        return SuspendingClock.now - sinceThen
    }

    // MARK: - Writers (one lock each)

    @inline(__always)
    private func withLock<R>(_ body: (inout Fields) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        lockAcquisitions += 1
        return body(&fields)
    }

    /// Stamp `now`. First write wins. The clock is read INSIDE the lock so
    /// two writers cannot install stamps in the opposite order of their
    /// instants (an engine stamp winning the lock ahead of an earlier
    /// `terminal_built` would otherwise invert the chain).
    public func mark(_ stamp: Stamp) {
        withLock { f in f.mark(stamp, offsetUs: offsetUs(of: .now)) }
    }

    /// Stamp a specific instant (e.g. the engine's admission instant). First
    /// write wins; never earlier than `notBefore` and never later than
    /// `notAfter` when those stamps are present, so a cross-clock conversion
    /// or a late engine event (a `.delta` delivered after the handler already
    /// built a cancelled terminal) can't violate a wire ordering invariant.
    public func mark(
        _ stamp: Stamp,
        at instant: SuspendingClock.Instant,
        notBefore floor: Stamp? = nil,
        notAfter ceiling: Stamp? = nil
    ) {
        let offset = offsetUs(of: instant)
        withLock { f in
            f.mark(stamp, offsetUs: f.clamp(offset, notBefore: floor, notAfter: ceiling))
        }
    }

    /// `budget_remaining_at_admit_us`: the deadline's remaining window at the
    /// admission instant, clamped at zero — the wire range is [0, 3.6e9] and a
    /// deadline that expired between the last check and this read would
    /// otherwise invalidate the whole profile as `range`.
    @inline(__always)
    public static func budgetRemainingUs(_ remaining: Duration) -> Int64 {
        max(0, microseconds(remaining))
    }

    /// Record a duration measured between two suspending instants.
    public func markDuration(
        _ field: DurationField,
        start: SuspendingClock.Instant,
        end: SuspendingClock.Instant = .now
    ) {
        let us = Self.microseconds(end - start)
        withLock { $0.add(field, us: us) }
    }

    public func set(_ field: CountField, _ value: Int64) {
        withLock { $0.set(field, value) }
    }

    public func set(_ field: CountField, _ value: Int) {
        set(field, Int64(value))
    }

    public func set(_ field: FlagField, _ value: Bool) {
        withLock { $0.set(field, value) }
    }

    public func set(deadlineMode: DeadlineMode) {
        withLock { $0.deadlineMode = deadlineMode }
    }

    /// Batch several writes under ONE lock acquisition. `nowUs` is the
    /// current offset, read INSIDE the lock (see `mark`), so stamps inside
    /// the batch cost no extra clock read and are ordered with every other
    /// lock holder's instant.
    public func update(_ body: (inout Fields, _ nowUs: Int64) -> Void) {
        withLock { f in body(&f, offsetUs(of: .now)) }
    }

    // MARK: - Cancellation

    /// Stamp cancel receipt and derive the lifecycle stage from the stamps
    /// present at that instant. One lock. Returns the stage so the caller can
    /// bump the matching cumulative counter; `nil` when a cancel was already
    /// recorded (first one wins).
    ///
    /// CLOCK NOTE: `cancel_received_us` is the instant `handleCancellation`
    /// PROCESSES the cancel on the provider's serial event loop, not the
    /// WebSocket frame's receipt. A cancel queues behind whatever inference
    /// request the loop is currently admitting (`ProviderLoop+Serve` awaits
    /// each event in turn), so this stamp is an upper bound on receipt.
    @discardableResult
    public func markCancelReceived() -> CancelStage? {
        return withLock { f in
            guard f.offset(.cancelReceived) == nil else { return nil }
            f.mark(.cancelReceived, offsetUs: offsetUs(of: .now))
            let stage: CancelStage
            if f.offset(.terminalBuilt) != nil {
                stage = .postTerminal
            } else if f.offset(.firstDelta) != nil {
                stage = .decode
            } else if f.offset(.engineSubmit) != nil {
                stage = .prefill
            } else if f.offset(.acceptedSent) != nil {
                stage = .preEngine
            } else {
                stage = .preAccept
            }
            f.cancelStage = stage
            return stage
        }
    }

    /// Cancel landed after the engine already finished this request (the
    /// bridge's row scan — serialized against `recordFinish` on its actor —
    /// missed, and `steps_at_finish` proves the row existed): record
    /// `tokens_after_cancel = 0` rather than omitting it. No-op when the
    /// request never reached an engine or the field is already set. One lock.
    public func recordTokensAfterCancelIfFinished() {
        withLock { f in
            guard f.count(.tokensAfterCancel) == nil, f.count(.stepsAtFinish) != nil else { return }
            f.set(.tokensAfterCancel, 0)
        }
    }

    /// Cancel outcome for the cumulative heartbeat counters. One lock.
    /// `abortNs` is nil until both cancel stamps exist.
    public func cancelSummary() -> (tokensAfterCancel: Int64?, abortNs: Int64?) {
        withLock { f in
            var abortNs: Int64?
            if let received = f.offset(.cancelReceived), let aborted = f.offset(.cancelAborted) {
                abortNs = max(0, aborted - received) &* 1_000
            }
            return (f.count(.tokensAfterCancel), abortNs)
        }
    }

    // MARK: - Materialization

    /// Build the wire object. `total_us` is the offset at THIS call (the
    /// codec calls it at encode time, so it includes outbound-queue latency);
    /// `slept_us` is the continuous-vs-suspending drift over the same window.
    public func wireObject() -> InferenceProfile {
        // `total_us` and the field snapshot are taken under ONE lock
        // acquisition so no stamp written concurrently (a late engine event
        // racing the codec's encode) can be present yet exceed `total`.
        let (snapshot, totalUs, sleptUs): (Fields, Int64, Int64) = withLock { f in
            let suspendingNow = SuspendingClock.now
            let continuousNow = ContinuousClock.now
            let total = max(1, Self.microseconds(suspendingNow - suspendingAnchor))
            let continuousUs = Self.microseconds(continuousNow - continuousAnchor)
            return (f, total, max(0, continuousUs - total))
        }
        var p = InferenceProfile(schema: InferenceProfile.currentSchema, wallMs: wallMs)
        p.dequeuedUs = snapshot.offset(.dequeued)
        p.decryptedUs = snapshot.offset(.decrypted)
        p.parsedUs = snapshot.offset(.parsed)
        p.admissionUs = snapshot.offset(.admission)
        p.acceptedSentUs = snapshot.offset(.acceptedSent)
        p.loadWaitStartUs = snapshot.offset(.loadWaitStart)
        p.loadWaitEndUs = snapshot.offset(.loadWaitEnd)
        p.taskSpawnedUs = snapshot.offset(.taskSpawned)
        p.promptPrepStartUs = snapshot.offset(.promptPrepStart)
        p.promptPrepEndUs = snapshot.offset(.promptPrepEnd)
        p.engineSubmitUs = snapshot.offset(.engineSubmit)
        p.engineAdmittedUs = snapshot.offset(.engineAdmitted)
        p.firstDeltaUs = snapshot.offset(.firstDelta)
        p.firstFrameUs = snapshot.offset(.firstFrame)
        p.lastDeltaUs = snapshot.offset(.lastDelta)
        p.terminalBuiltUs = snapshot.offset(.terminalBuilt)
        p.terminalSentUs = snapshot.offset(.terminalSent)
        p.cancelReceivedUs = snapshot.offset(.cancelReceived)
        p.cancelAbortedUs = snapshot.offset(.cancelAborted)
        p.totalUs = totalUs

        p.toolConstraintUs = snapshot.durations[DurationField.toolConstraint.rawValue]
        p.visionPrepUs = snapshot.durations[DurationField.visionPrep.rawValue]
        p.ssdStageUs = snapshot.durations[DurationField.ssdStage.rawValue]
        p.kvReserveUs = snapshot.durations[DurationField.kvReserve.rawValue]
        p.flushUs = snapshot.durations[DurationField.flush.rawValue]
        p.seSignUs = snapshot.durations[DurationField.seSign.rawValue]
        p.sleptUs = sleptUs

        p.promptTokens = snapshot.count(.promptTokens)
        p.framesEmitted = snapshot.count(.framesEmitted)
        p.bytesEmitted = snapshot.count(.bytesEmitted)
        p.runningAtAdmit = snapshot.count(.runningAtAdmit)
        p.waitingAtAdmit = snapshot.count(.waitingAtAdmit)
        p.queuedPrefillTokensAtAdmit = snapshot.count(.queuedPrefillTokensAtAdmit)
        p.kvBytesInUseAtAdmit = snapshot.count(.kvBytesInUseAtAdmit)
        p.kvBytesCapacity = snapshot.count(.kvBytesCapacity)
        p.stepsAtSubmit = snapshot.count(.stepsAtSubmit)
        p.stepsAtFinish = snapshot.count(.stepsAtFinish)
        p.projectedPrefillTokens = snapshot.count(.projectedPrefillTokens)
        p.projectedDecodeTokens = snapshot.count(.projectedDecodeTokens)
        p.projectedServiceUs = snapshot.count(.projectedServiceUs)
        p.budgetRemainingAtAdmitUs = snapshot.count(.budgetRemainingAtAdmitUs)
        p.partialPrefillCap = snapshot.count(.partialPrefillCap)
        p.mlxActiveBytesAtFinish = snapshot.count(.mlxActiveBytesAtFinish)
        p.mlxPeakBytes = snapshot.count(.mlxPeakBytes)
        p.tokensAfterCancel = snapshot.count(.tokensAfterCancel)

        p.usageRecovered = snapshot.flags[FlagField.usageRecovered.rawValue]
        p.loadCold = snapshot.flags[FlagField.loadCold.rawValue]
        p.loadParked = snapshot.flags[FlagField.loadParked.rawValue]
        p.mtpActive = snapshot.flags[FlagField.mtpActive.rawValue]
        p.lowPowerMode = snapshot.flags[FlagField.lowPowerMode.rawValue]

        p.deadlineMode = snapshot.deadlineMode
        p.thermalState = snapshot.thermalState
        p.cancelStage = snapshot.cancelStage
        p.engine = snapshot.engine
        // Saturate at the coordinator's accepted ranges: a lifetime engine
        // step counter or a pathological duration must never invalidate the
        // whole record as `range`. `min` is monotone, so the order chain is
        // preserved.
        return p.saturatedToWireRanges()
    }

    // MARK: - Test hooks

    /// Number of lock acquisitions so far (includes this read).
    public var lockAcquisitionCount: Int {
        withLock { _ in lockAcquisitions }
    }
}
