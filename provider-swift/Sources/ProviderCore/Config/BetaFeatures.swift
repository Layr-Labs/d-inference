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
/// Adding a beta toggle = adding one ``BetaFeature`` entry here (and its backing
/// `ProviderConfig` field). The `darkbloom beta` command and `darkbloom status`
/// are driven entirely off this list, so they need no per-feature code.
public enum BetaFeatures {
    public static let all: [BetaFeature] = [
        BetaFeature(
            id: "kv-quant",
            title: "KV-cache quantization",
            summary: "8-bit KV cache for ~1.9x more concurrent context on supported models.",
            details: """
            Stores attention keys/values in 8-bit for the validated model \
            families (GPT-OSS and Gemma 4), roughly doubling the tokens a \
            provider can admit at once. Other model families are unaffected and \
            keep fp16. After enabling and restarting, confirm it engaged with \
            `darkbloom logs` (look for the `kv-quant` logger).
            """,
            requiresRestart: true,
            read: { $0.backend.kvQuant },
            write: { enabled, config in config.backend.kvQuant = enabled }
        )
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
