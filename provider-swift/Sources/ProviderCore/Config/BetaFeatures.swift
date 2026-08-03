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
    /// Stable CLI identifier, e.g. `mtp`. Lowercase, hyphenated.
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
            id: "mtp",
            title: "Multi-token prediction (speculative decoding)",
            summary: "Gemma 4 drafter-assisted decode on CBv2 — faster greedy decode, token-identical output.",
            details: """
            Binds a small drafter model to Gemma 4 slots so greedy \
            (temperature-0) requests decode several tokens per step. Output \
            is token-identical to MTP-off; drafter resolution and load are \
            fail-open (any problem falls back to plain decode). The drafter \
            comes from the catalog's spec_dec pointer, or set \
            mtp_drafter_path under [backend] to a local drafter directory.
            """,
            requiresRestart: true,
            read: { $0.backend.mtp },
            write: { enabled, config in config.backend.mtp = enabled }
        ),
        // (adaptive-prefill was retired with the legacy engine, v0.7.5 —
        // CBv2 chunks prefill engine-internally. kv-quant was retired in
        // v0.8.0 with the KV-quantization feature itself; its `kv_quant`
        // config key is handled by `BackendSettings.RetiredCodingKeys`.)
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
