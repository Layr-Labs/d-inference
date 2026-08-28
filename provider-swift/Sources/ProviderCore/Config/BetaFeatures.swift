import Foundation

/// User-facing posture for a beta setting. Most features are boolean, while
/// MTP's automatic posture is model-aware and must not be rendered as off.
public enum BetaFeatureState: String, Sendable, Equatable, Codable {
    case auto
    case on
    case off

    /// Boolean compatibility projection. Automatic has no honest global
    /// boolean value because it is on for eligible models and off for others.
    public var enabled: Bool? {
        switch self {
        case .auto: return nil
        case .on: return true
        case .off: return false
        }
    }

    public var displayValue: String {
        self == .auto ? "auto (model-aware)" : rawValue
    }

    public var statusLabel: String {
        switch self {
        case .auto: return "AUTOMATIC (model-aware)"
        case .on: return "ENABLED"
        case .off: return "disabled"
        }
    }
}

/// A user-facing configurable *beta* feature.
///
/// Beta features are intentionally **config-backed**, not environment-variable
/// backed: the launchd daemon started by `darkbloom start` only inherits a tiny
/// allowlist of `DARKBLOOM_*` variables (`LaunchAgent.passthroughEnvKeys`), so an
/// env-var toggle would silently no-op for the normal daemon. A field in the TOML
/// config is always read by every serve path (daemon, `--foreground`, `--local`).
///
/// Each feature maps a boolean CLI projection onto ``ProviderConfig``. Most
/// projections are stored booleans; MTP maps enable/disable to `.on`/`.off`
/// while preserving `.auto` until an operator explicitly toggles it.
/// Getter/setter closures keep the registry concurrency-safe under Swift 6.
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
    /// Where the backing field lives in `provider.toml`
    /// (`[section]` + `key =`), so the CLI can tell "already at the requested
    /// value AND pinned in the file" apart from "same value via decode
    /// default". An absent key must be WRITTEN on an explicit toggle: the
    /// operator asked for the value durably, not for today's decode default
    /// (a future default flip would otherwise silently move their provider).
    public let configAddress: (section: String, key: String)?

    private let read: @Sendable (ProviderConfig) -> Bool
    private let readState: @Sendable (ProviderConfig) -> BetaFeatureState
    private let readPinnedValue: @Sendable (ProviderConfig) -> Bool?
    private let write: @Sendable (Bool, inout ProviderConfig) -> Void

    public init(
        id: String,
        title: String,
        summary: String,
        details: String,
        requiresRestart: Bool,
        configAddress: (section: String, key: String)? = nil,
        read: @escaping @Sendable (ProviderConfig) -> Bool,
        stateRead: (@Sendable (ProviderConfig) -> BetaFeatureState)? = nil,
        pinnedRead: (@Sendable (ProviderConfig) -> Bool?)? = nil,
        write: @escaping @Sendable (Bool, inout ProviderConfig) -> Void
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.details = details
        self.requiresRestart = requiresRestart
        self.configAddress = configAddress
        self.read = read
        self.readState = stateRead ?? { read($0) ? .on : .off }
        self.readPinnedValue = pinnedRead ?? { Optional(read($0)) }
        self.write = write
    }

    /// Whether the feature can currently be active in `config`. For automatic
    /// settings this is true when eligible models may use the feature; use
    /// ``state(in:)`` when the distinction between on and auto matters.
    public func isEnabled(in config: ProviderConfig) -> Bool {
        read(config)
    }

    /// Tri-state posture shown by CLI status surfaces.
    public func state(in config: ProviderConfig) -> BetaFeatureState {
        readState(config)
    }

    /// Whether config explicitly pins the requested boolean override.
    ///
    /// This differs from `isEnabled` for tri-state settings: MTP automatic
    /// mode is neither explicitly on nor explicitly off, so either beta toggle
    /// must materialize the operator's requested override.
    public func isPinned(_ enabled: Bool, in config: ProviderConfig) -> Bool {
        readPinnedValue(config) == enabled
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
            id: "mtp",
            title: "Multi-token prediction (speculative decoding)",
            summary: "Force MTP on for supported CBv2 targets; the exact Qwen3.8 production target defaults on automatically.",
            details: """
            Automatic mode enables the separate MTP artifact only for \
            EigenLabs/Qwen3.8-27B-4bit after immutable artifact validation; \
            every other model remains off when config is absent. Enabling this \
            beta writes an explicit on override for supported targets; disabling \
            it writes the explicit off rollback. DARKBLOOM_CBV2_MTP=0 remains \
            the final process-wide kill switch. Resolution and load are \
            fail-open to target-only decode. Catalog assistants come from the \
            target's spec_dec pointer, or set mtp_drafter_path under [backend] \
            to an immutable local assistant directory.
            """,
            requiresRestart: true,
            configAddress: (section: "backend", key: "mtp_mode"),
            read: { $0.backend.mtpMode != .off },
            stateRead: { config in
                switch config.backend.mtpMode {
                case .auto: return .auto
                case .on: return .on
                case .off: return .off
                }
            },
            pinnedRead: { config in
                switch config.backend.mtpMode {
                case .auto: return nil
                case .on: return true
                case .off: return false
                }
            },
            write: { enabled, config in config.backend.mtpMode = enabled ? .on : .off }
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

    /// The ids of features that are on or automatic for eligible models.
    public static func enabledIDs(in config: ProviderConfig) -> [String] {
        all.filter { $0.isEnabled(in: config) }.map(\.id)
    }
}
