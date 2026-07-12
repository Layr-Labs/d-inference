import Foundation

/// A user-facing opt-in *beta* feature.
///
/// Beta features are intentionally **config-backed**, not environment-variable
/// backed: the launchd daemon started by `darkbloom start` only inherits a tiny
/// allowlist of `DARKBLOOM_*` variables (`LaunchAgent.passthroughEnvKeys`), so an
/// env-var toggle would silently no-op for the normal daemon. A field in the TOML
/// config is always read by every serve path (daemon, `--foreground`, `--local`).
///
/// Each feature maps to one `Bool` field of ``ProviderConfig``. The getter/setter
/// are stored as `@Sendable` closures so the registry is a concurrency-safe
/// `static let` under Swift 6 strict concurrency.
public struct BetaFeature: Sendable, Identifiable {
    /// Stable CLI identifier, e.g. `kv-quant`. Lowercase, hyphenated.
    public let id: String
    /// Short human-readable name.
    public let title: String
    /// One-line description shown by `darkbloom beta list`.
    public let summary: String
    /// Longer guidance shown when toggling and by `darkbloom beta status <id>`.
    public let details: String
    /// Whether `darkbloom restart` is required for a change to take effect.
    public let requiresRestart: Bool

    private let read: @Sendable (ProviderConfig) -> Bool
    private let write: @Sendable (Bool, inout ProviderConfig) -> Void

    public init(
        id: String,
        title: String,
        summary: String,
        details: String,
        requiresRestart: Bool,
        read: @escaping @Sendable (ProviderConfig) -> Bool,
        write: @escaping @Sendable (Bool, inout ProviderConfig) -> Void
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.details = details
        self.requiresRestart = requiresRestart
        self.read = read
        self.write = write
    }

    /// Whether the feature is currently enabled in `config`.
    public func isEnabled(in config: ProviderConfig) -> Bool {
        read(config)
    }

    /// Set the feature's enabled state on `config` in place.
    public func apply(_ enabled: Bool, to config: inout ProviderConfig) {
        write(enabled, &config)
    }
}

/// The registry of opt-in beta features.
///
/// These are local experimental overrides, not release-cohort gates. A beta
/// release must ship its intended behavior in the build itself; joining the
/// beta release channel must never require enabling every entry here by hand.
///
/// Adding a beta toggle = adding one ``BetaFeature`` entry here (and its backing
/// `ProviderConfig` field). The `darkbloom beta` command and `darkbloom status`
/// are driven entirely off this list, so they need no per-feature code.
public enum BetaFeatures {
    public static let all: [BetaFeature] = [
        BetaFeature(
            id: "kv-quant",
            title: "KV-cache quantization",
            summary: "CURRENTLY REJECTED (v0.7.5 serves fp16-only KV; CBv2 fast-follow planned).",
            details: """
            The legacy engine's 8-bit KV schemes died with the one-engine \
            release: v0.7.5 serves fp16-only KV caches, and a kv_quant = true \
            is REJECTED with a startup WARN rather than silently ignored. A \
            ContinuousBatchingV2-native KV-quant is a planned fast-follow; \
            leaving this enabled opts you in when it ships.
            """,
            requiresRestart: true,
            read: { $0.backend.kvQuant },
            write: { enabled, config in config.backend.kvQuant = enabled }
        )
        // (adaptive-prefill was retired with the legacy engine, v0.7.5 —
        // CBv2 chunks prefill engine-internally.)
    ]

    /// Look up a feature by its CLI id (case-insensitive).
    public static func feature(id: String) -> BetaFeature? {
        let needle = id.lowercased()
        return all.first { $0.id.lowercased() == needle }
    }

    /// The ids of all features currently enabled in `config`.
    public static func enabledIDs(in config: ProviderConfig) -> [String] {
        all.filter { $0.isEnabled(in: config) }.map(\.id)
    }
}
