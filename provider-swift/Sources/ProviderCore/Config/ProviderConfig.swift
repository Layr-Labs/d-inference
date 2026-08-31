/// Provider configuration management.
///
/// Configuration is stored in TOML format at `~/.config/darkbloom/provider.toml`.
/// For backward compatibility with existing installations, the loader also
/// reads from `~/.config/eigeninference/provider.toml` and the legacy
/// `~/Library/Application Support/{darkbloom,eigeninference}/provider.toml`
/// paths. New installs always write to the canonical `~/.config/darkbloom/`
/// path. The config includes:
///   - Provider identity (name, memory reserve)
///   - Backend settings (port, model, continuous batching, idle timeout)
///   - Coordinator connection settings (URL, heartbeat interval)
///   - Scheduling windows
///   - Config-backed Gemma optimization controls
///
/// A default config is generated based on detected hardware when the provider
/// is first initialized. CLI flags can override config values at runtime.

import Foundation
import TOMLKit

// MARK: - Config structs

public struct ProviderSettings: Sendable, Equatable, Codable {
    public var name: String
    public var memoryReserveGB: UInt64
    /// Legacy compatibility setting. Process-evidence-v1 rollout is always
    /// coordinator-authorized and does not consult this local toggle.
    public var autoUpdate: Bool
    /// When true (default), the watchdog relaunches the provider ~5 min after a
    /// crash. `false` opts out while keeping the provider installed.
    public var autoRestart: Bool
    /// Legacy compatibility setting for pre-v1 provider binaries. The v1
    /// coordinator controls rollout stage/pause and sends exact generations;
    /// the current provider never applies local release jitter.
    public var updateJitterSeconds: UInt64

    public init(
        name: String,
        memoryReserveGB: UInt64 = 4,
        autoUpdate: Bool = true,
        autoRestart: Bool = true,
        updateJitterSeconds: UInt64 = 300
    ) {
        self.name = name
        self.memoryReserveGB = memoryReserveGB
        self.autoUpdate = autoUpdate
        self.autoRestart = autoRestart
        self.updateJitterSeconds = updateJitterSeconds
    }

    enum CodingKeys: String, CodingKey {
        case name
        case memoryReserveGB = "memory_reserve_gb"
        case autoUpdate = "auto_update"
        case autoRestart = "auto_restart"
        case updateJitterSeconds = "update_jitter_seconds"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "darkbloom"
        self.memoryReserveGB = try container.decodeIfPresent(UInt64.self, forKey: .memoryReserveGB) ?? 4
        self.autoUpdate = try container.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? true
        self.autoRestart = try container.decodeIfPresent(Bool.self, forKey: .autoRestart) ?? true
        self.updateJitterSeconds = try container.decodeIfPresent(UInt64.self, forKey: .updateJitterSeconds) ?? 300
    }
}
/// Operator policy for multi-token prediction.
///
/// `auto` preserves the distinction between an absent setting and an explicit
/// rollback. It defaults MTP on only for the exact production Qwen3.8 target;
/// every other model retains the historical absent-config default of off.
/// Artifact validation and the process-wide kill switch remain enforced by
/// `SpecDecArtifactFunnel`.
public enum MTPMode: String, Sendable, Equatable, Codable {
    case auto
    case on
    case off

    public static let automaticTargetModelID = "EigenLabs/Qwen3.8-27B-4bit"

    public func enablesMTP(forModelID modelID: String) -> Bool {
        switch self {
        case .on:
            return true
        case .off:
            return false
        case .auto:
            return modelID == Self.automaticTargetModelID
        }
    }
}


public struct BackendSettings: Sendable, Equatable, Codable {
    public var port: UInt16
    public var model: String?
    /// Which models to advertise to the network. If empty, all downloaded models
    /// are advertised. If set, only these models are offered.
    public var enabledModels: [String]
    /// Minutes of inactivity before the backend is shut down to free GPU memory.
    /// 0 = never shut down. Default: 60 (1 hour).
    public var idleTimeoutMins: UInt64
    /// Maximum number of models to keep resident at once. This bounds
    /// coordinator-driven preloads so advertised model count cannot become a
    /// memory-unbounded slot cap.
    public var maxModelSlots: UInt64
    /// Box-wide concurrent-request cap per v2 engine slot
    /// (`engine_v2_max_concurrent` under `[backend]`). Default
    /// ``defaultEngineV2MaxConcurrent`` — 4 as of v0.8.1, reverting v0.8.0's
    /// raise to 8. The two knobs ARE coupled, contrary to what v0.8.0
    /// believed: the raise was justified by paged's batch curve, and v0.8.1
    /// reverts the paged default, so it goes back with it. See
    /// ``ConcurrencyDefaultMigration/v081ConcurrencyRevert`` for the measured
    /// curve and why the knee is at 4.
    ///
    /// Still clamped to [1, 8] at use, and the UPPER bound deliberately stays
    /// 8: the engine's KV byte-ledger admission binds long before count does,
    /// caps past 8 recreate the batch-collapse regime the one-engine release
    /// exists to kill, and 8 remains the right operating point for a box that
    /// asks for paged by name — where B=8 still pays 1.27x over B=4. The
    /// coordinator sees the effective value in heartbeat `max_concurrency`.
    public var engineV2MaxConcurrent: UInt64
    /// Optional per-model override map
    /// (`engine_v2_max_concurrent_by_model` under `[backend]`, TOML table
    /// of model id → cap). Same [1, 8] clamp. Missing ids use
    /// `engineV2MaxConcurrent`.
    public var engineV2MaxConcurrentByModel: [String: UInt64]
    /// CBv2 KV-backend selection (`engine_v2_kv_backend` under
    /// `[backend]`): "auto" (default — resolves CONTIGUOUS as of v0.8.1,
    /// reverting v0.8.0's paged default; see
    /// `EngineV2Factory.prepareProductionBackend`), "paged", or
    /// "contiguous". Setting "paged" explicitly is the ONLY way to put a
    /// box on paged — the `DARKBLOOM_CBV2_PAGED_KV` env var is a
    /// negative-polarity kill switch and cannot turn paged on. Note the
    /// consequence of an explicit "paged" under a contiguous default: a
    /// box that cannot serve paged now REFUSES the load
    /// (`EngineV2ProductionError.pagedUnavailable` ⇒ 503, the coordinator
    /// reroutes) rather than degrading, because refusal is reserved for a
    /// selection someone asked for by name.
    /// VLM slots are NOT forced to contiguous by the veto in
    /// `EngineV2KVBackendPolicy.applySlotVetoes` (`guard isVLM,
    /// !pagedHonorsSpanMasks`): it fires only when the paged cache does
    /// not affirm span masks, and
    /// `PagedLayerCache.honorsSpanMaskContextsByConstruction` — what
    /// `EngineV2SlotFactory` passes — is `true`, so the veto is inert and
    /// an explicit "paged" VLM slot gets paged like any other.
    /// The fleet kill switch `DARKBLOOM_CBV2_PAGED_KV=0` always degrades,
    /// never refuses. A resolved-contiguous slot also gets NO SSD prefix
    /// cache (`PrefixCachePolicy.adoptionIsExact`).
    /// See `EngineV2KVBackendPolicy`.
    public var engineV2KVBackend: String
    /// Optional per-model override map (`engine_v2_kv_backend_by_model`
    /// under `[backend]`, TOML table of model id → "auto" | "paged" |
    /// "contiguous"). Missing ids use `engineV2KVBackend`.
    public var engineV2KVBackendByModel: [String: String]
    /// Startup model preload (default true). On boot the provider loads the
    /// `preload_models` set (or, when that is empty, the models it was serving
    /// before the last restart — see `LoadedModelsStore`) BEFORE registering
    /// with the coordinator, so a release restart never advertises models it
    /// hasn't warmed. `startup_preload = false` restores the old
    /// register-immediately behavior.
    public var startupPreload: Bool
    /// Models to preload at startup, in this order. Empty (default) means
    /// "the models that were loaded before the last restart" (persisted set,
    /// loaded biggest-first). Ids not in the advertised model set are skipped
    /// with a warning. Set `preload_models = ["..."]` under `[backend]`.
    public var preloadModels: [String]
    /// Upper bound (seconds) the provider defers coordinator registration while
    /// the startup preload runs. If the preload finishes sooner, it registers
    /// warm immediately; on timeout it registers anyway (availability beats
    /// perfection — a lone provider for a model must still serve it cold) and
    /// the remaining loads finish in the background. Default 120s covers a
    /// ~26 GB weight load + engine warmup with margin.
    public var startupPreloadTimeoutSecs: UInt64
    /// After each startup preload, run a 1-token greedy decode through the real
    /// serving path through the model's EngineV2 bridge so
    /// Metal JIT, compiled buckets, and the chat-template render are warm
    /// before the first routed request. Default true. Failure is fail-open
    /// (WARN telemetry, model stays advertised) unless
    /// `startup_selftest_fail_closed = true`.
    public var startupSelftest: Bool
    /// When true, a model whose startup self-test decode fails is unloaded and
    /// dropped from the advertised set for this run (fail-closed). Default
    /// false: availability beats perfection — a self-test failure may be
    /// transient and the model can still serve via the lazy-load path.
    public var startupSelftestFailClosed: Bool
    /// MTP (multi-token prediction / speculative decoding) policy
    /// (`mtp_mode` under `[backend]`, default `"auto"` — beta id `mtp`).
    /// Automatic mode activates only the exact production Qwen3.8 target.
    /// The legacy `mtp = true|false` key is accepted only when `mtp_mode` is
    /// absent. Serialization emits only `mtp_mode`.
    ///
    /// Artifact resolution/load remains fail-open to target-only decode, and
    /// `DARKBLOOM_CBV2_MTP=0` remains the final process-wide kill switch.
    public var mtpMode: MTPMode
    /// Source-compatible view of the former boolean setting. Reading is true
    /// only for an explicit `.on`; assigning performs an explicit on/off
    /// override rather than materializing the automatic model decision.
    public var mtp: Bool {
        get { mtpMode == .on }
        set { mtpMode = newValue ? .on : .off }
    }
    /// Explicit provider-side atomic first-token deadline policy. Nil means the
    /// key was absent, so runtime resolution inherits the legacy environment
    /// control and otherwise securely enforces. Optional encoding preserves
    /// that source distinction instead of materializing an explicit default.
    public var prefillDeadlineMode: PrefillDeadlineMode?
    /// Optional local drafter directory override (`mtp_drafter_path` under
    /// `[backend]`) — the canary path: `config.json` + `*.safetensors`, no R2
    /// involved. Takes precedence over the `spec_dec` download when set. nil
    /// (default) = resolve via the catalog's `spec_dec` pointer.
    public var mtpDrafterPath: String?
    /// RETIRED `[backend]` keys found in the decoded provider.toml
    /// (`engine_v2`, `continuous_batching`, `adaptive_prefill`,
    /// `legacy_compiled_decode`, `kv_quant`). The keys parse cleanly — an
    /// old config must never brick a provider — but their values are
    /// IGNORED; startup emits one WARN per entry so operators notice the
    /// knob no longer exists. Not encoded back out.
    public internal(set) var retiredKeysPresent: [String] = []

    /// The v0.8.1 box-wide concurrency cap, and the single source for BOTH
    /// the memberwise default and the ``init(from:)`` fallback.
    ///
    /// They are one constant because they drifted apart exactly once and it
    /// was expensive: the memberwise default moved 4 -> 8 while the decode
    /// fallback stayed at 4, so every provider that loaded a `provider.toml`
    /// — which is every provider in the fleet — silently kept B=4 while
    /// the release believed it had moved to 8.
    ///
    /// Moving this constant reaches FRESH INSTALLS ONLY. `TOMLEncoder` emits
    /// every non-optional key, so existing configs carry a literal that does
    /// not track the binary; the fleet moves via
    /// ``ConcurrencyDefaultMigration``, and a test pins that the newest step
    /// lands here so the two cannot separate.
    public static let defaultEngineV2MaxConcurrent: UInt64 = 4

    public init(
        port: UInt16 = 8100,
        model: String? = nil,
        enabledModels: [String] = [],
        idleTimeoutMins: UInt64 = 60,
        maxModelSlots: UInt64 = 3,
        engineV2MaxConcurrent: UInt64 = BackendSettings.defaultEngineV2MaxConcurrent,
        engineV2MaxConcurrentByModel: [String: UInt64] = [:],
        engineV2KVBackend: String = "auto",
        engineV2KVBackendByModel: [String: String] = [:],
        startupPreload: Bool = true,
        preloadModels: [String] = [],
        startupPreloadTimeoutSecs: UInt64 = 120,
        startupSelftest: Bool = true,
        startupSelftestFailClosed: Bool = false,
        mtp: Bool? = nil,
        mtpMode: MTPMode = .auto,
        prefillDeadlineMode: PrefillDeadlineMode? = nil,
        mtpDrafterPath: String? = nil
    ) {
        self.port = port
        self.model = model
        self.enabledModels = enabledModels
        self.idleTimeoutMins = idleTimeoutMins
        self.maxModelSlots = maxModelSlots
        self.engineV2MaxConcurrent = engineV2MaxConcurrent
        self.engineV2MaxConcurrentByModel = engineV2MaxConcurrentByModel
        self.engineV2KVBackend = engineV2KVBackend
        self.engineV2KVBackendByModel = engineV2KVBackendByModel
        self.startupPreload = startupPreload
        self.preloadModels = preloadModels
        self.startupPreloadTimeoutSecs = startupPreloadTimeoutSecs
        self.startupSelftest = startupSelftest
        self.startupSelftestFailClosed = startupSelftestFailClosed
        self.mtpMode = mtp.map { $0 ? .on : .off } ?? mtpMode
        self.prefillDeadlineMode = prefillDeadlineMode
        self.mtpDrafterPath = mtpDrafterPath
    }

    enum CodingKeys: String, CodingKey {
        case port
        case model
        case enabledModels = "enabled_models"
        case idleTimeoutMins = "idle_timeout_mins"
        case maxModelSlots = "max_model_slots"
        case engineV2MaxConcurrent = "engine_v2_max_concurrent"
        case engineV2MaxConcurrentByModel = "engine_v2_max_concurrent_by_model"
        case engineV2KVBackend = "engine_v2_kv_backend"
        case engineV2KVBackendByModel = "engine_v2_kv_backend_by_model"
        case startupPreload = "startup_preload"
        case preloadModels = "preload_models"
        case startupPreloadTimeoutSecs = "startup_preload_timeout_secs"
        case startupSelftest = "startup_selftest"
        case startupSelftestFailClosed = "startup_selftest_fail_closed"
        case legacyMTP = "mtp"
        case mtpMode = "mtp_mode"
        case prefillDeadlineMode = "prefill_deadline_mode"
        case mtpDrafterPath = "mtp_drafter_path"
    }

    /// RETIRED `[backend]` keys: parsed for presence only, values ignored.
    /// See `retiredKeysPresent`. v0.7.5 (one engine) retired the four
    /// selection knobs; v0.8.0 retired `kv_quant` along with the KV
    /// quantization feature itself.
    private enum RetiredCodingKeys: String, CodingKey, CaseIterable {
        case continuousBatching = "continuous_batching"
        case adaptivePrefill = "adaptive_prefill"
        case engineV2 = "engine_v2"
        case legacyCompiledDecode = "legacy_compiled_decode"
        case kvQuant = "kv_quant"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? 8100
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.enabledModels = try container.decodeIfPresent([String].self, forKey: .enabledModels) ?? []
        self.idleTimeoutMins = try container.decodeIfPresent(UInt64.self, forKey: .idleTimeoutMins) ?? 60
        self.maxModelSlots = try container.decodeIfPresent(UInt64.self, forKey: .maxModelSlots) ?? 3
        self.engineV2MaxConcurrent =
            try container.decodeIfPresent(UInt64.self, forKey: .engineV2MaxConcurrent)
            ?? Self.defaultEngineV2MaxConcurrent
        self.engineV2MaxConcurrentByModel =
            try container.decodeIfPresent(
                [String: UInt64].self, forKey: .engineV2MaxConcurrentByModel) ?? [:]
        self.engineV2KVBackend =
            try container.decodeIfPresent(String.self, forKey: .engineV2KVBackend) ?? "auto"
        self.engineV2KVBackendByModel =
            try container.decodeIfPresent(
                [String: String].self, forKey: .engineV2KVBackendByModel) ?? [:]
        self.startupPreload = try container.decodeIfPresent(Bool.self, forKey: .startupPreload) ?? true
        self.preloadModels = try container.decodeIfPresent([String].self, forKey: .preloadModels) ?? []
        self.startupPreloadTimeoutSecs =
            try container.decodeIfPresent(UInt64.self, forKey: .startupPreloadTimeoutSecs) ?? 120
        self.startupSelftest = try container.decodeIfPresent(Bool.self, forKey: .startupSelftest) ?? true
        self.startupSelftestFailClosed =
            try container.decodeIfPresent(Bool.self, forKey: .startupSelftestFailClosed) ?? false
        if container.contains(.mtpMode) {
            self.mtpMode = try container.decode(MTPMode.self, forKey: .mtpMode)
        } else if let legacyMTP = try container.decodeIfPresent(Bool.self, forKey: .legacyMTP) {
            self.mtpMode = legacyMTP ? .on : .off
        } else {
            self.mtpMode = .auto
        }
        self.prefillDeadlineMode =
            try container.decodeIfPresent(
                PrefillDeadlineMode.self,
                forKey: .prefillDeadlineMode)
        self.mtpDrafterPath = try container.decodeIfPresent(String.self, forKey: .mtpDrafterPath)
        // Retired keys: presence-only scan so startup can WARN (values are
        // ignored; an old provider.toml must keep loading cleanly).
        let retired = try decoder.container(keyedBy: RetiredCodingKeys.self)
        self.retiredKeysPresent = RetiredCodingKeys.allCases
            .filter { retired.contains($0) }
            .map(\.rawValue)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(port, forKey: .port)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(enabledModels, forKey: .enabledModels)
        try container.encode(idleTimeoutMins, forKey: .idleTimeoutMins)
        try container.encode(maxModelSlots, forKey: .maxModelSlots)
        try container.encode(engineV2MaxConcurrent, forKey: .engineV2MaxConcurrent)
        try container.encode(engineV2MaxConcurrentByModel, forKey: .engineV2MaxConcurrentByModel)
        try container.encode(engineV2KVBackend, forKey: .engineV2KVBackend)
        try container.encode(engineV2KVBackendByModel, forKey: .engineV2KVBackendByModel)
        try container.encode(startupPreload, forKey: .startupPreload)
        try container.encode(preloadModels, forKey: .preloadModels)
        try container.encode(startupPreloadTimeoutSecs, forKey: .startupPreloadTimeoutSecs)
        try container.encode(startupSelftest, forKey: .startupSelftest)
        try container.encode(startupSelftestFailClosed, forKey: .startupSelftestFailClosed)
        try container.encode(mtpMode, forKey: .mtpMode)
        try container.encodeIfPresent(prefillDeadlineMode, forKey: .prefillDeadlineMode)
        try container.encodeIfPresent(mtpDrafterPath, forKey: .mtpDrafterPath)
    }
}

public struct CoordinatorSettings: Sendable, Equatable, Codable {
    public var url: String
    public var heartbeatIntervalSecs: UInt64
    /// When true, register this machine as private-only: the coordinator serves
    /// it exclusively to the owner's own ("My Machine") requests, never the
    /// public fleet. Set `private_only = true` under `[coordinator]` in config.
    public var privateOnly: Bool

    public init(url: String = "wss://api.darkbloom.dev/ws/provider", heartbeatIntervalSecs: UInt64 = 5, privateOnly: Bool = false) {
        self.url = url
        self.heartbeatIntervalSecs = heartbeatIntervalSecs
        self.privateOnly = privateOnly
    }

    enum CodingKeys: String, CodingKey {
        case url
        case heartbeatIntervalSecs = "heartbeat_interval_secs"
        case privateOnly = "private_only"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.url = try container.decodeIfPresent(String.self, forKey: .url) ?? "wss://api.darkbloom.dev/ws/provider"
        self.heartbeatIntervalSecs = try container.decodeIfPresent(UInt64.self, forKey: .heartbeatIntervalSecs) ?? 5
        self.privateOnly = try container.decodeIfPresent(Bool.self, forKey: .privateOnly) ?? false
    }
}

public struct ProviderConfig: Sendable, Equatable, Codable {
    public var provider: ProviderSettings
    public var backend: BackendSettings
    public var coordinator: CoordinatorSettings
    public var schedule: ScheduleConfig?
    public var gemmaOptimizations: GemmaOptimizationSettings
    /// Schema version of the `provider.toml` this config came from
    /// (`config_version`, top level, written by the startup stamp in
    /// `migrateConfigIfNeeded`).
    ///
    /// Its job is to date generated values so a schema migration can tell them
    /// apart from an operator's current explicit choices. That evidence is
    /// spent once; after the file carries the new stamp, its values mean what
    /// they say forever.
    ///
    /// Decoding always reports ``currentConfigVersion`` — the field describes
    /// the schema this process speaks. Cap migrations that require an operator
    /// warning are reported through ``appliedMigrations`` instead.
    public var configVersion: Int
    /// Ids of migrations this decode must surface in a startup warning (see
    /// `RetiredKnobWarnings`). Derived, never encoded — the same contract as
    /// ``BackendSettings/retiredKeysPresent``.
    public internal(set) var appliedMigrations: [String] = []

    /// Current `provider.toml` schema version.
    ///
    ///   * absent = pre-v0.8.0
    ///   * 1 = v0.8.0, which raised the concurrency default 4 -> 8
    ///   * 2 = v0.8.1, which reverted it to 4 with contiguous KV
    ///   * 3 = tri-state MTP; generated legacy false migrates to automatic
    ///
    /// Bump only with a versioned migration that consumes the previous value.
    public static let currentConfigVersion = MTPModeDefaultMigration.targetConfigVersion

    public init(
        provider: ProviderSettings,
        backend: BackendSettings = BackendSettings(),
        coordinator: CoordinatorSettings = CoordinatorSettings(),
        schedule: ScheduleConfig? = nil,
        gemmaOptimizations: GemmaOptimizationSettings = GemmaOptimizationSettings(),
        configVersion: Int = ProviderConfig.currentConfigVersion
    ) {
        self.provider = provider
        self.backend = backend
        self.coordinator = coordinator
        self.schedule = schedule
        self.gemmaOptimizations = gemmaOptimizations
        self.configVersion = configVersion
    }

    enum CodingKeys: String, CodingKey {
        case provider
        case backend
        case coordinator
        case schedule
        case gemmaOptimizations = "gemma_optimizations"
        case configVersion = "config_version"
    }

    /// Parent-level probe for fields whose migration depends on the top-level
    /// config stamp. `BackendSettings` cannot see `config_version` while it is
    /// decoding its nested table.
    private struct BackendMTPMigrationProbe: Decodable {
        let legacyMTP: Bool?
        let mtpMode: MTPMode?

        enum CodingKeys: String, CodingKey {
            case legacyMTP = "mtp"
            case mtpMode = "mtp_mode"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.provider = try container.decodeIfPresent(ProviderSettings.self, forKey: .provider) ?? ProviderSettings(name: "darkbloom")
        let mtpProbe = try container.decodeIfPresent(
            BackendMTPMigrationProbe.self, forKey: .backend)
        var backend = try container.decodeIfPresent(BackendSettings.self, forKey: .backend) ?? BackendSettings()
        self.coordinator = try container.decodeIfPresent(CoordinatorSettings.self, forKey: .coordinator) ?? CoordinatorSettings()
        self.schedule = try container.decodeIfPresent(ScheduleConfig.self, forKey: .schedule)
        self.gemmaOptimizations = try container.decodeIfPresent(
            GemmaOptimizationSettings.self, forKey: .gemmaOptimizations
        ) ?? GemmaOptimizationSettings()

        // Generated-value migrations selected by the stamp the file carries.
        // MTP false from a pre-tri-state schema becomes automatic unless the
        // authoritative `mtp_mode` key is present. Legacy true remains on.
        //
        // Deliberately narrow: a step fires only on the exact cap the release
        // generated, so an operator who picked any other value in range is
        // never rewritten. The unavoidable casualty is a deliberate
        // cap that happens to equal the one being migrated away from — see
        // `ConcurrencyDefaultMigration.v081ConcurrencyRevert`, which is honest
        // about the fact that v0.8.1's 8 -> 4 step cannot tell a generated 8
        // from a chosen one. Explicit paged is the exception: its backend
        // selection is distinguishable and its measured optimum remains B=8,
        // so the migration preserves it. Any migrated cap runs once, is
        // announced by `RetiredKnobWarnings`, and sticks when re-set.
        //
        // The predicate is shared with the on-disk rewrite so this in-memory
        // change and the durable text surgery cannot disagree.
        let onDiskVersion = try container.decodeIfPresent(Int.self, forKey: .configVersion)
        backend.mtpMode = MTPModeDefaultMigration.resolvedMode(
            onDiskVersion: onDiskVersion,
            explicitMode: mtpProbe?.mtpMode,
            legacyValue: mtpProbe?.legacyMTP)
        let migrated = ConcurrencyDefaultMigration.resolvedCap(
            onDiskVersion: onDiskVersion,
            cap: backend.engineV2MaxConcurrent,
            kvBackend: backend.engineV2KVBackend)
        backend.engineV2MaxConcurrent = migrated.cap
        self.appliedMigrations = migrated.applied.map(\.id)
        self.backend = backend
        self.configVersion = Self.currentConfigVersion
    }

    /// Generate a default config based on detected hardware.
    ///
    /// The provider name is derived from the machine model identifier
    /// (e.g. "Mac16,1" -> "darkbloom-mac16-1").
    public static func defaultForHardware(_ hw: HardwareInfo) -> ProviderConfig {
        let name = "darkbloom-" + hw.machineModel
            .replacingOccurrences(of: ",", with: "-")
            .lowercased()

        return ProviderConfig(
            provider: ProviderSettings(
                name: name,
                memoryReserveGB: 4,
                autoUpdate: true
            ),
            backend: BackendSettings(
                port: 8100,
                model: nil,
                enabledModels: [],
                idleTimeoutMins: 60,
                maxModelSlots: 3
            ),
            coordinator: CoordinatorSettings(
                url: "wss://api.darkbloom.dev/ws/provider",
                heartbeatIntervalSecs: 5
            ),
            schedule: nil
        )
    }
}

// MARK: - File I/O

public enum ConfigError: Error, CustomStringConvertible {
    case cannotDetermineConfigDirectory
    case readFailed(path: String, underlying: Error)
    case writeFailed(path: String, underlying: Error)
    case parseFailed(detail: String)

    public var description: String {
        switch self {
        case .cannotDetermineConfigDirectory:
            return "could not determine config directory"
        case .readFailed(let path, let err):
            return "failed to read config from \(path): \(err)"
        case .writeFailed(let path, let err):
            return "failed to write config to \(path): \(err)"
        case .parseFailed(let detail):
            return "failed to parse config: \(detail)"
        }
    }
}

public enum ConfigManager: Sendable {

    /// Default config file path. Resolution order, first hit wins:
    ///
    /// 1. `~/.config/darkbloom/provider.toml`  (canonical, new installs)
    /// 2. `~/Library/Application Support/darkbloom/provider.toml`
    /// 3. `~/.config/eigeninference/provider.toml`  (legacy install path)
    /// 4. `~/Library/Application Support/eigeninference/provider.toml`
    ///
    /// If none of those files exist yet, we return path #1 so first-time
    /// `save()` writes to the canonical location.
    public static func defaultConfigPath() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first

        let xdgNew = home
            .appendingPathComponent(".config")
            .appendingPathComponent("darkbloom")
            .appendingPathComponent("provider.toml")
        let xdgLegacy = home
            .appendingPathComponent(".config")
            .appendingPathComponent("eigeninference")
            .appendingPathComponent("provider.toml")

        let appNew = appSupport?
            .appendingPathComponent("darkbloom")
            .appendingPathComponent("provider.toml")
        let appLegacy = appSupport?
            .appendingPathComponent("eigeninference")
            .appendingPathComponent("provider.toml")

        let candidates = [xdgNew, appNew, xdgLegacy, appLegacy].compactMap { $0 }
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return xdgNew
    }

    /// Load config from a file path.
    ///
    /// This is the production file-loading boundary: a file that EXISTS but
    /// cannot decode throws `ConfigError.parseFailed` (see
    /// ``parseValidating(_:)``) instead of silently falling back to defaults.
    /// Callers that want missing-file leniency check `fileExists` first; only
    /// a NONEXISTENT path defaults (`readFailed` is thrown here, and the
    /// snapshot/`loadDefault` layers substitute defaults in that case).
    public static func load(from path: URL) throws -> ProviderConfig {
        let content: String
        do {
            content = try String(contentsOf: path, encoding: .utf8)
        } catch {
            throw ConfigError.readFailed(path: path.path, underlying: error)
        }
        return try parseValidating(content)
    }

    /// Load config from the default path. Returns default config if file doesn't exist.
    public static func loadDefault() -> ProviderConfig {
        guard let path = try? defaultConfigPath(),
              FileManager.default.fileExists(atPath: path.path),
              let config = try? load(from: path)
        else {
            // Return a minimal default if we can't load
            return ProviderConfig(
                provider: ProviderSettings(name: "darkbloom"),
                backend: BackendSettings(),
                coordinator: CoordinatorSettings()
            )
        }
        return config
    }

    /// Save config to a file path, creating parent directories as needed.
    public static func save(_ config: ProviderConfig, to path: URL) throws {
        let dir = path.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
        } catch {
            throw ConfigError.writeFailed(path: dir.path, underlying: error)
        }

        let toml = serialize(config)
        do {
            try toml.write(to: path, atomically: true, encoding: .utf8)
        } catch {
            throw ConfigError.writeFailed(path: path.path, underlying: error)
        }
    }

    /// Read-modify-write: load config, apply a transform, save it back.
    public static func update(at path: URL, _ transform: (inout ProviderConfig) -> Void) throws {
        var config = try load(from: path)
        transform(&config)
        try save(config, to: path)
    }

    // MARK: - TOML parsing

    /// Parse a TOML string into a ProviderConfig.
    ///
    /// LENIENT, test-facing entry point: ANY decode failure falls back to a
    /// whole-config default, exactly matching historical behavior. Production
    /// file loads must NOT use this — a malformed `[gemma_optimizations]`
    /// entry (e.g. `weighted_r1 = 0` as an integer) would otherwise silently
    /// re-enable the whole default-on optimization stack with zero log. Use
    /// ``parseValidating(_:)`` (via ``load(from:)``) on that path.
    public static func parse(_ content: String) -> ProviderConfig {
        do {
            return try TOMLDecoder().decode(ProviderConfig.self, from: content)
        } catch {
            // Fall back to defaults on malformed TOML (matches previous behavior)
            return ProviderConfig(
                provider: ProviderSettings(name: "darkbloom"),
                backend: BackendSettings(),
                coordinator: CoordinatorSettings()
            )
        }
    }

    /// Parse a TOML string into a ProviderConfig, failing loudly.
    ///
    /// Unlike ``parse(_:)``, any decode failure throws
    /// `ConfigError.parseFailed` carrying the decoder's description, so an
    /// operator who fat-fingers `provider.toml` is told at startup instead of
    /// unknowingly serving on whole-config defaults. Missing / partial content
    /// still decodes with per-key defaults (default-on Gemma stack) — only an
    /// undecodable FILE is rejected.
    public static func parseValidating(_ content: String) throws -> ProviderConfig {
        do {
            return try TOMLDecoder().decode(ProviderConfig.self, from: content)
        } catch {
            throw ConfigError.parseFailed(detail: "\(error)")
        }
    }

    /// Serialize a ProviderConfig to the provider's TOML config format.
    public static func serialize(_ config: ProviderConfig) -> String {
        do {
            return try TOMLEncoder().encode(config)
        } catch {
            // Should never happen with our well-defined types, but return empty
            // string rather than crashing (matches previous graceful behavior).
            return ""
        }
    }
}
