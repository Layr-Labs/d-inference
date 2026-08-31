import Foundation
import ProviderCore
#if canImport(Darwin)
import Darwin
#endif

/// Process-start seam shared by every serving/benchmarking entry point
/// (`start` daemon/foreground/local, `benchmark`): the authoritative
/// `[gemma_optimizations]` TOML projection must be applied first, then the
/// immutable metallib snapshot must be bound, and only then may MLX be touched
/// by `requireMetal`.
///
/// A rejected projection throws before binding. Binding strictly precedes the
/// first MLX device access, so diagnostics and later model loads cannot select
/// mutable or different metallib bytes.
enum ServeRuntimePreparer {

    /// Apply `settings`, bind the runtime metallib, then probe Metal.
    ///
    /// The returned hash identifies the retained anonymous snapshot. Nil is
    /// preserved for fail-closed capability detection: NAX is never advertised
    /// without a successfully bound hash.
    @discardableResult
    internal static func prepareRuntime(
        settings: GemmaOptimizationSettings,
        apply: (GemmaOptimizationSettings) throws -> Void = {
            try GemmaOptimizationEnvironment.apply($0)
        },
        bindMetallib: () -> String? = {
            bindRuntimeMetallibForMLX(from: nil)
        },
        requireMetal: () throws -> Void = {
            _ = try GPUEnforcement.requireMetal()
        }
    ) throws -> String? {
        try apply(settings)
        let boundMetallibHash = bindMetallib()
        try requireMetal()
        return boundMetallibHash
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
