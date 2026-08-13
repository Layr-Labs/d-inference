import Foundation
import ProviderCore
#if canImport(Darwin)
import Darwin
#endif

/// Process-start seam shared by every serving/benchmarking entry point
/// (`start` daemon/foreground/local, `benchmark`): the authoritative
/// `[gemma_optimizations]` TOML projection must be applied to the low-level
/// process environment BEFORE the first MLX device access (`requireMetal`),
/// because those controls are process-start latches in MLX/MLX-LM.
///
/// Ordering contract: config projection strictly precedes the first MLX
/// touch. A rejected projection throws before `requireMetal()`, so a
/// half-applied weighted-unsort/safe-R1 pair can never reach engine
/// construction.
enum ServeRuntimePreparer {

    /// Apply `settings` to the process environment, then probe Metal.
    ///
    /// The default closures are the production path; tests replace only the
    /// apply/Metal probes so they can assert ordering without constructing an
    /// MLX device.
    internal static func prepareRuntime(
        settings: GemmaOptimizationSettings,
        apply: (GemmaOptimizationSettings) throws -> Void = {
            try GemmaOptimizationEnvironment.apply($0)
        },
        requireMetal: () throws -> Void = {
            _ = try GPUEnforcement.requireMetal()
        }
    ) throws {
        try apply(settings)
        try requireMetal()
    }

    /// One pre-set low-level environment key that CONFLICTS with the config
    /// projection a command is about to apply.
    struct EnvironmentConflict: Equatable {
        /// The low-level environment key (e.g. `MLX_GATHER_QMM_EXPERT_SLICES`).
        let key: String
        /// The value the operator's shell exported.
        let shellValue: String
        /// The value `provider.toml` projects (and would overwrite with).
        let configValue: String
    }

    /// Returns the first pre-existing low-level key whose value DISAGREES with
    /// the config projection; nil when every key is unset or already matches.
    ///
    /// `apply(_:)` overwrites unconditionally (config is authoritative), which
    /// is correct for serving — but a benchmark run whose artifact metadata
    /// records `os.environ` (scripts/gemma_contbatch/runner.py) would then
    /// disagree with what was actually measured. Benchmark-style callers check
    /// this first and refuse to run on a conflict instead of silently
    /// rewriting the operator's shell. Sorted scan keeps the reported key
    /// stable across runs.
    internal static func conflictingEnvironmentOverride(
        settings: GemmaOptimizationSettings,
        getenv: (String) -> String? = {
            $0.withCString { Darwin.getenv($0) }.map { String(cString: $0) }
        }
    ) -> EnvironmentConflict? {
        let projection = GemmaOptimizationEnvironment.projection(
            for: settings, getenv: getenv)
        for key in [
            GemmaOptimizationEnvironment.prefillLayer18Key,
            GemmaOptimizationEnvironment.weightedUnsortKey,
            GemmaOptimizationEnvironment.safeR1Key,
        ].sorted() {
            guard let shellValue = getenv(key),
                  shellValue != projection[key] else { continue }
            return EnvironmentConflict(
                key: key,
                shellValue: shellValue,
                configValue: projection[key] ?? ""
            )
        }
        return nil
    }
}
