import Foundation

/// A user-facing configurable *beta* feature.
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
    /// Where the backing field lives in `provider.toml`
    /// (`[section]` + `key =`), so the CLI can tell "already at the requested
    /// value AND pinned in the file" apart from "same value via decode
    /// default". An absent key must be WRITTEN on an explicit toggle: the
    /// operator asked for the value durably, not for today's decode default
    /// (a future default flip would otherwise silently move their provider).
    public let configAddress: (section: String, key: String)?

    private let read: @Sendable (ProviderConfig) -> Bool
    private let write: @Sendable (Bool, inout ProviderConfig) -> Void

    public init(
        id: String,
        title: String,
        summary: String,
        details: String,
        requiresRestart: Bool,
        configAddress: (section: String, key: String)? = nil,
        read: @escaping @Sendable (ProviderConfig) -> Bool,
        write: @escaping @Sendable (Bool, inout ProviderConfig) -> Void
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.details = details
        self.requiresRestart = requiresRestart
        self.configAddress = configAddress
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

/// The registry of configurable beta features.
///
/// Adding a beta toggle = adding one ``BetaFeature`` entry here (and its backing
/// `ProviderConfig` field). Features declare their own defaults; the
/// `darkbloom beta` command and `darkbloom status` are driven entirely off this
/// list, so they need no per-feature code.
public enum BetaFeatures {
    public static let all: [BetaFeature] = [
        BetaFeature(
            id: "gemma-prefill-layer18",
            title: "Gemma layer-18 prefill submission",
            summary: "Default ON. Submit prefill work every 18 layers; disable for legacy submission behavior.",
            details: """
            Default ON for existing and new configs. Writes prefill_layer18 \
            under [gemma_optimizations]; provider config is authoritative over \
            the low-level process environment. Restart after changing it. \
            Disable and restart to restore the legacy one-final-submission \
            prefill behavior.
            """,
            requiresRestart: true,
            configAddress: (section: "gemma_optimizations", key: "prefill_layer18"),
            read: { $0.gemmaOptimizations.prefillLayer18 },
            write: { enabled, config in
                config.gemmaOptimizations.prefillLayer18 = enabled
            }
        ),
        BetaFeature(
            id: "gemma-weighted-r1",
            title: "Gemma weighted unsort + safe R1",
            summary: "Default ON. Coupled weighted-unsort and safe-R1 expert paths with one rollback.",
            details: """
            Default ON for existing and new configs. Writes weighted_r1 under \
            [gemma_optimizations]. This single production control keeps direct \
            weighted expert reduction coupled to the safe exact-shape R1 QMM \
            path; neither half can be selected independently. Provider config \
            is authoritative over the low-level process environment. Disable \
            and restart to restore both legacy paths together.
            """,
            requiresRestart: true,
            configAddress: (section: "gemma_optimizations", key: "weighted_r1"),
            read: { $0.gemmaOptimizations.weightedR1 },
            write: { enabled, config in
                config.gemmaOptimizations.weightedR1 = enabled
            }
        ),
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
            configAddress: (section: "backend", key: "kv_quant"),
            read: { $0.backend.kvQuant },
            write: { enabled, config in config.backend.kvQuant = enabled }
        ),
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
            configAddress: (section: "backend", key: "mtp"),
            read: { $0.backend.mtp },
            write: { enabled, config in config.backend.mtp = enabled }
        ),
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
