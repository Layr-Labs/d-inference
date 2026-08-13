import Darwin

/// Projects the config-backed Gemma controls into the low-level environment
/// consumed while MLX and MLX-LM initialize process-wide optimization state.
public enum GemmaOptimizationEnvironment {
    public static let prefillLayer18Key = "DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL"
    public static let weightedUnsortKey = "MLX_GEMMA4_FUSED_WEIGHTED_UNSORT"
    public static let safeR1Key = "MLX_GATHER_QMM_EXPERT_SLICES"
    /// The one operator refinement of `safeR1Key` that survives the config
    /// projection: route ON, descriptor-retract readback skipped (no mid-eval
    /// stream drain). Every other operator value is overwritten by config.
    public static let trustedSafeR1Value = "trust"

    /// Who is consuming a projection. The operator `trust` refinement is only
    /// legal where the projected environment feeds a live serving or benchmark
    /// process; validation contexts must be hermetic so an ambient override in
    /// the launching process can neither fail nor skew them.
    public enum Context: Sendable {
        /// A process about to serve or benchmark: honor an operator-exported
        /// `trust` refinement of the expert-slice route.
        case serving
        /// Retained-config validation (`runtime-smoke`, artifact
        /// verification): the ambient environment is never consulted, so the
        /// projection is a pure function of the retained config.
        case retainedValidation
    }

    /// Return the complete production projection for `settings`.
    ///
    /// Weighted unsort and safe R1 always receive the same value: production
    /// never exposes either half of the benchmark-selected pair independently.
    ///
    /// One operator refinement survives a `.serving` projection: when the
    /// expert-slice route is ON and the shell exported
    /// `MLX_GATHER_QMM_EXPERT_SLICES=trust`, the projection keeps `trust`
    /// (route ON, descriptor-retract readback skipped — no mid-eval stream
    /// drain) instead of collapsing it to `1`. `trust` never overrides a
    /// config-OFF: the config stays authoritative for whether the route runs
    /// at all. A `.retainedValidation` projection never reads the ambient
    /// environment at all.
    public static func projection(
        for settings: GemmaOptimizationSettings,
        context: Context = .serving,
        getenv: (String) -> String? = {
            $0.withCString { Darwin.getenv($0) }.map { String(cString: $0) }
        }
    ) -> [String: String] {
        let weightedR1 = settings.weightedR1 ? "1" : "0"
        var safeR1 = weightedR1
        if context == .serving, settings.weightedR1,
           getenv(safeR1Key) == trustedSafeR1Value {
            safeR1 = trustedSafeR1Value
        }
        return [
            prefillLayer18Key: settings.prefillLayer18 ? "18" : "0",
            weightedUnsortKey: weightedR1,
            safeR1Key: safeR1,
        ]
    }

    /// The `EnvironmentVariables` entries the launchd service plist must carry
    /// so the daemon child sees the same operator refinement as the installing
    /// shell. launchd does not inherit the installer's environment, so without
    /// this the background `darkbloom start` would silently collapse an
    /// exported `trust` back to `1`.
    ///
    /// Only the exact `trust` value is persisted: config-backed `0`/`1` (and
    /// any other operator value) stay excluded from the daemon environment,
    /// keeping `provider.toml` authoritative for whether the route runs.
    public static func daemonTrustPassthrough(
        from environment: [String: String]
    ) -> [String: String] {
        environment[safeR1Key] == trustedSafeR1Value
            ? [safeR1Key: trustedSafeR1Value]
            : [:]
    }

    /// Raised when the process refuses one or more projected controls.
    ///
    /// Weighted unsort and safe R1 are process-start latches, so a projection
    /// that only partially applied leaves the coupled pair in a state no
    /// benchmark ever measured. Callers must abort startup instead of
    /// continuing on the surviving half.
    public struct ApplicationFailure: Error, Equatable, CustomStringConvertible {
        /// Rejected keys, sorted, so the message is stable across runs.
        public let keys: [String]
        /// `errno` reported by the first rejected key.
        public let code: Int32

        public init(keys: [String], code: Int32) {
            self.keys = keys
            self.code = code
        }

        public var description: String {
            let reason = strerror(code).map { String(cString: $0) }
                ?? "errno \(code)"
            return """
                failed to apply Gemma optimization controls \
                [\(keys.joined(separator: ", "))]: \(reason)
                """
        }
    }

    /// Apply the complete projection to the current process.
    ///
    /// Config is authoritative, so every key is overwritten even when the
    /// launching shell supplied a conflicting low-level value. Throws
    /// `ApplicationFailure` if the environment rejects any key.
    public static func apply(_ settings: GemmaOptimizationSettings) throws {
        try apply(settings) { name, value, overwrite in
            errno = 0
            guard setenv(name, value, overwrite) == 0 else {
                return errno == 0 ? EINVAL : errno
            }
            return 0
        }
    }

    /// Apply every projected key, then report all rejections at once.
    ///
    /// - Parameter set: applies one key and returns `0` on success or the
    ///   failing `errno` otherwise.
    static func apply(
        _ settings: GemmaOptimizationSettings,
        set: (_ name: String, _ value: String, _ overwrite: Int32) -> Int32
    ) throws {
        var rejected: [String] = []
        var code: Int32 = 0
        // Sorted so a failure reports the same keys regardless of the
        // dictionary's per-process hash ordering.
        for (name, value) in projection(for: settings).sorted(by: { $0.key < $1.key }) {
            let status = set(name, value, 1)
            guard status != 0 else { continue }
            rejected.append(name)
            if code == 0 { code = status }
        }
        guard rejected.isEmpty else {
            throw ApplicationFailure(keys: rejected, code: code)
        }
    }
}
