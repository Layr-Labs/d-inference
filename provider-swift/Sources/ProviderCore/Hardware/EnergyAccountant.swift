import Foundation

/// Cumulative activity counters read once per tick. The accountant diffs the
/// token totals internally to get per-tick deltas, so the caller only needs to
/// expose monotonic totals plus the live flags. `decodeTokensTotal` MUST be a
/// live streaming counter (incremented as tokens are emitted), not an
/// end-of-request total, or attribution degenerates.
public struct EnergyActivityCounters: Sendable, Equatable {
    public var decodeTokensTotal: UInt64
    public var prefillTokensTotal: UInt64
    public var inferenceActive: Bool
    public var modelResident: Bool
    public var loading: Bool

    public init(decodeTokensTotal: UInt64, prefillTokensTotal: UInt64, inferenceActive: Bool, modelResident: Bool, loading: Bool) {
        self.decodeTokensTotal = decodeTokensTotal
        self.prefillTokensTotal = prefillTokensTotal
        self.inferenceActive = inferenceActive
        self.modelResident = modelResident
        self.loading = loading
    }
}

/// Owns the energy sampler + ledger and drives the periodic accounting loop.
///
/// The loop reads the latest cumulative activity counters (via a Sendable
/// closure supplied by the provider runtime), samples IOReport, and folds one
/// tick into the ledger. `snapshot()` is read by the heartbeat builder. When
/// IOReport is unavailable the accountant is inert and `snapshot()` returns an
/// empty ledger — the coordinator then falls back to the static estimate.
public actor EnergyAccountant {
    public typealias CountersProvider = @Sendable () async -> EnergyActivityCounters

    private let sampler: IOReportSampler
    private var ledger = EnergyLedger()
    private var prevDecode: UInt64 = 0
    private var prevPrefill: UInt64 = 0
    private var wasLoading = false
    private var loopTask: Task<Void, Never>?

    public init(sampler: IOReportSampler = IOReportSampler()) {
        self.sampler = sampler
    }

    public func available() async -> Bool { await sampler.available }

    /// Start the background accounting loop. Idempotent. Call this when the
    /// session starts (not on the first heartbeat) so the first interval after
    /// registration — coordinator preload, cold model load, early inference — is
    /// sampled rather than skipped.
    public func start(intervalMs: UInt64 = 500, counters: @escaping CountersProvider) {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            let ns = intervalMs * 1_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: ns)
                guard let self else { return }
                let c = await counters()
                await self.tick(c)
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Fold a single tick. Exposed (not just internal to the loop) so unit tests
    /// and one-shot CLI flows can drive it deterministically.
    public func tick(_ counters: EnergyActivityCounters) async {
        guard let sample = await sampler.sample() else { return }
        let dDecode = counters.decodeTokensTotal >= prevDecode ? counters.decodeTokensTotal - prevDecode : 0
        let dPrefill = counters.prefillTokensTotal >= prevPrefill ? counters.prefillTokensTotal - prevPrefill : 0
        prevDecode = counters.decodeTokensTotal
        prevPrefill = counters.prefillTokensTotal

        // Count a model load on the rising edge of `loading`.
        if counters.loading && !wasLoading { ledger.noteModelLoad() }
        wasLoading = counters.loading

        ledger.record(sample, activity: EnergyActivity(
            prefillTokens: Double(dPrefill),
            decodeTokens: Double(dDecode),
            inferenceActive: counters.inferenceActive,
            modelResident: counters.modelResident,
            loading: counters.loading))
    }

    public func snapshot() -> EnergyLedgerSnapshot { ledger.snapshot() }
}
