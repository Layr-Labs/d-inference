import Foundation

/// StartupPreloader -- sequential boot-time model preload with memory
/// admission and an optional per-model self-test decode.
///
/// Fixes the fleet-rollover cold-start failure mode: after a release restart
/// the provider used to register (and attract routing) with NOTHING loaded, so
/// first requests paid the full multi-GB weight load + engine build inside a
/// live request — and at a fleet-wide rollover every box was cold at once
/// (first_chunk_timeout storm). This component loads the configured /
/// previously-served model set BEFORE the caller opens the coordinator
/// connection.
///
/// Design rules:
///   * **Sequential.** Loads are serialized (the `ProviderLoop` load gate
///     serializes them anyway); one at a time keeps eviction decisions and
///     memory admission deterministic.
///   * **Preload never evicts.** Each candidate is admitted only if its
///     weights + serve headroom fit what is free RIGHT NOW; otherwise it is
///     skipped with a WARN. Loading a later candidate must never churn out an
///     earlier preloaded model — the lazy-load path remains the fallback for
///     skipped models.
///   * **Failures degrade, never crash.** A failed load or self-test logs,
///     optionally emits telemetry, and moves on. Fail-open is the default: a
///     model whose self-test failed stays advertised (availability beats
///     perfection); `selfTestFailClosed` opts into retiring it.
///
/// All side effects are injected so the sequencing is unit-testable with
/// scripted loaders — no model weights, no network, no MLX.
public struct StartupPreloader: Sendable {

    /// One model to preload: id + the load-gate admission requirement
    /// (weights + serve headroom, same arithmetic as `ModelLoadAdmission`).
    public struct Candidate: Sendable, Equatable {
        public let modelId: String
        public let requiredGb: Double

        public init(modelId: String, requiredGb: Double) {
            self.modelId = modelId
            self.requiredGb = requiredGb
        }
    }

    /// Collaborators the preloader drives. Production wiring lives in
    /// `ProviderLoop+StartupPreload`; tests substitute scripted closures.
    public struct Dependencies: Sendable {
        /// Memory (GB) currently free for a model load (the load-gate view).
        public var freeMemoryGb: @Sendable () async -> Double
        /// Full model load: weights + legacy scheduler + v2 bridge/warmup when
        /// flagged (production: `ensureModelLoaded`).
        public var load: @Sendable (String) async throws -> Void
        /// Optional 1-token decode through the serving path after each load.
        /// nil = self-test disabled. Returns the decode duration.
        public var selfTest: (@Sendable (String) async throws -> Duration)?
        /// When true, a failed self-test retires the model (see `retire`).
        public var selfTestFailClosed: Bool
        /// Retire a model whose self-test failed (fail-closed only):
        /// production unloads it and drops it from the advertised set.
        public var retire: @Sendable (String) async -> Void
        /// Telemetry hook for self-test failures: (modelId, error message).
        public var onSelfTestFailed: @Sendable (String, String) -> Void
        /// Human-readable progress/warning lines.
        public var log: @Sendable (String) -> Void

        public init(
            freeMemoryGb: @escaping @Sendable () async -> Double,
            load: @escaping @Sendable (String) async throws -> Void,
            selfTest: (@Sendable (String) async throws -> Duration)? = nil,
            selfTestFailClosed: Bool = false,
            retire: @escaping @Sendable (String) async -> Void = { _ in },
            onSelfTestFailed: @escaping @Sendable (String, String) -> Void = { _, _ in },
            log: @escaping @Sendable (String) -> Void = { _ in }
        ) {
            self.freeMemoryGb = freeMemoryGb
            self.load = load
            self.selfTest = selfTest
            self.selfTestFailClosed = selfTestFailClosed
            self.retire = retire
            self.onSelfTestFailed = onSelfTestFailed
            self.log = log
        }
    }

    /// What happened, for logging and tests. `loaded` lists models resident
    /// at the end of the run (a retired model is moved out of `loaded`).
    public struct Summary: Sendable, Equatable {
        public var loaded: [String] = []
        public var skippedInsufficientMemory: [String] = []
        public var failed: [String] = []
        public var selfTestFailed: [String] = []
        public var retired: [String] = []

        public init() {}
    }

    private let deps: Dependencies

    public init(deps: Dependencies) {
        self.deps = deps
    }

    /// Run the preload sequentially over `candidates` (caller-defined order:
    /// biggest-first for the persisted default, operator order for
    /// `preload_models`). Honors task cancellation between and inside steps.
    public func run(candidates: [Candidate]) async -> Summary {
        var summary = Summary()
        for candidate in candidates {
            if Task.isCancelled { break }
            let modelId = candidate.modelId

            // Memory admission WITHOUT eviction (see the design rules above).
            let freeGb = await deps.freeMemoryGb()
            guard freeGb >= candidate.requiredGb else {
                deps.log(
                    "WARN: startup preload skipping '\(modelId)': needs "
                        + "\(Self.gb(candidate.requiredGb)) GB, \(Self.gb(freeGb)) GB free — "
                        + "will lazy-load on first request")
                summary.skippedInsufficientMemory.append(modelId)
                continue
            }

            let clock = ContinuousClock()
            let loadStart = clock.now
            do {
                try await deps.load(modelId)
                deps.log("startup preload: loaded '\(modelId)' in \(Self.secs(clock.now - loadStart))")
                summary.loaded.append(modelId)
            } catch is CancellationError {
                break
            } catch {
                deps.log(
                    "WARN: startup preload failed for '\(modelId)': "
                        + "\(error.localizedDescription) — will lazy-load on first request")
                summary.failed.append(modelId)
                continue
            }

            guard let selfTest = deps.selfTest else { continue }
            let selfTestStart = clock.now
            do {
                let decodeTook = try await selfTest(modelId)
                deps.log(
                    "startup self-test: '\(modelId)' decoded 1 token in \(Self.secs(decodeTook)) "
                        + "(end-to-end \(Self.secs(clock.now - selfTestStart)))")
            } catch is CancellationError {
                break
            } catch {
                summary.selfTestFailed.append(modelId)
                deps.onSelfTestFailed(modelId, error.localizedDescription)
                if deps.selfTestFailClosed {
                    await deps.retire(modelId)
                    summary.retired.append(modelId)
                    summary.loaded.removeAll { $0 == modelId }
                    deps.log(
                        "WARN: startup self-test failed for '\(modelId)': "
                            + "\(error.localizedDescription) — retired "
                            + "(startup_selftest_fail_closed=true)")
                } else {
                    deps.log(
                        "WARN: startup self-test failed for '\(modelId)': "
                            + "\(error.localizedDescription) — model stays advertised (fail-open)")
                }
            }
        }
        return summary
    }

    // MARK: - Formatting helpers

    static func secs(_ d: Duration) -> String {
        let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return String(format: "%.1fs", seconds)
    }

    static func gb(_ v: Double) -> String {
        String(format: "%.1f", v)
    }
}
