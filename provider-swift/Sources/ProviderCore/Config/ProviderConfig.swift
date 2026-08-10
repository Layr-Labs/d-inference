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
    public var autoUpdate: Bool
    /// When true (default), the watchdog relaunches the provider ~5 min after a
    /// crash. `false` opts out while keeping the provider installed.
    public var autoRestart: Bool
    /// Maximum random delay (seconds) inserted between staging a verified
    /// background auto-update bundle and beginning the drain+restart. Staggers
    /// fleet restarts after a release so every provider is not cold at once (the
    /// first_chunk_timeout storm at rollover). The delay sits strictly AFTER the
    /// download/verify security checks and the provider keeps serving while it
    /// waits. 0 disables jitter. Manual (`darkbloom update`) and startup updates
    /// are never jittered. Set `update_jitter_seconds` under `[provider]`.
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
    /// KV-cache quantization request. v0.7.5 serves fp16-only KV (the
    /// KV-quant schemes died with the legacy engine); a `kv_quant = true`
    /// is REJECTED-with-WARN at startup and per model load — never
    /// silently ignored — because a CBv2-native KV-quant fast-follow is
    /// planned and operators who set this should learn it does not apply
    /// yet, not wonder why memory numbers moved.
    public var kvQuant: Bool
    /// Box-wide concurrent-request cap per v2 engine slot
    /// (`engine_v2_max_concurrent` under `[backend]`). Default 4 — the
    /// CBv2 product target. Clamped to [1, 8] at use: the engine's KV
    /// byte-ledger admission binds long before count does, and caps past 8
    /// recreate the batch-collapse regime the one-engine release exists to
    /// kill. The coordinator sees the effective value in heartbeat
    /// `max_concurrency`.
    public var engineV2MaxConcurrent: UInt64
    /// Optional per-model override map
    /// (`engine_v2_max_concurrent_by_model` under `[backend]`, TOML table
    /// of model id → cap). Same [1, 8] clamp. Missing ids use
    /// `engineV2MaxConcurrent`.
    public var engineV2MaxConcurrentByModel: [String: UInt64]
    /// CBv2 KV-backend selection (`engine_v2_kv_backend` under
    /// `[backend]`): "auto" (default — contiguous for every current and
    /// future model), experimental "paged", or "contiguous". VLM slots and
    /// `kv_quant = true` always force contiguous; kernel-ineligible models
    /// fall back to contiguous with an INFO telemetry event. Fleet kill
    /// switch: `DARKBLOOM_CBV2_PAGED_KV=0`. See `EngineV2KVBackendPolicy`.
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
    /// MTP (multi-token prediction / speculative decoding) opt-in for CBv2
    /// (`mtp` under `[backend]`, default false — beta id `mtp`). When enabled,
    /// slot build resolves a Gemma drafter (`mtp_drafter_path` if set, else the
    /// catalog entry's `spec_dec` download) and binds it to the engine. Drafter
    /// resolution/load is fail-open: any failure means plain decode, never a
    /// slot failure. `DARKBLOOM_CBV2_MTP` remains the engine-side kill switch.
    public var mtp: Bool
    /// Optional local drafter directory override (`mtp_drafter_path` under
    /// `[backend]`) — the canary path: `config.json` + `*.safetensors`, no R2
    /// involved. Takes precedence over the `spec_dec` download when set. nil
    /// (default) = resolve via the catalog's `spec_dec` pointer.
    public var mtpDrafterPath: String?
    /// RETIRED `[backend]` keys found in the decoded provider.toml
    /// (`engine_v2`, `continuous_batching`, `adaptive_prefill`,
    /// `legacy_compiled_decode`). The keys parse cleanly — an old config
    /// must never brick a provider — but their values are IGNORED;
    /// startup emits one WARN per entry so operators notice the knob no
    /// longer exists. Not encoded back out.
    public internal(set) var retiredKeysPresent: [String] = []

    public init(
        port: UInt16 = 8100,
        model: String? = nil,
        enabledModels: [String] = [],
        idleTimeoutMins: UInt64 = 60,
        maxModelSlots: UInt64 = 3,
        kvQuant: Bool = false,
        engineV2MaxConcurrent: UInt64 = 4,
        engineV2MaxConcurrentByModel: [String: UInt64] = [:],
        engineV2KVBackend: String = "auto",
        engineV2KVBackendByModel: [String: String] = [:],
        startupPreload: Bool = true,
        preloadModels: [String] = [],
        startupPreloadTimeoutSecs: UInt64 = 120,
        startupSelftest: Bool = true,
        startupSelftestFailClosed: Bool = false,
        mtp: Bool = false,
        mtpDrafterPath: String? = nil
    ) {
        self.port = port
        self.model = model
        self.enabledModels = enabledModels
        self.idleTimeoutMins = idleTimeoutMins
        self.maxModelSlots = maxModelSlots
        self.kvQuant = kvQuant
        self.engineV2MaxConcurrent = engineV2MaxConcurrent
        self.engineV2MaxConcurrentByModel = engineV2MaxConcurrentByModel
        self.engineV2KVBackend = engineV2KVBackend
        self.engineV2KVBackendByModel = engineV2KVBackendByModel
        self.startupPreload = startupPreload
        self.preloadModels = preloadModels
        self.startupPreloadTimeoutSecs = startupPreloadTimeoutSecs
        self.startupSelftest = startupSelftest
        self.startupSelftestFailClosed = startupSelftestFailClosed
        self.mtp = mtp
        self.mtpDrafterPath = mtpDrafterPath
    }

    enum CodingKeys: String, CodingKey {
        case port
        case model
        case enabledModels = "enabled_models"
        case idleTimeoutMins = "idle_timeout_mins"
        case maxModelSlots = "max_model_slots"
        case kvQuant = "kv_quant"
        case engineV2MaxConcurrent = "engine_v2_max_concurrent"
        case engineV2MaxConcurrentByModel = "engine_v2_max_concurrent_by_model"
        case engineV2KVBackend = "engine_v2_kv_backend"
        case engineV2KVBackendByModel = "engine_v2_kv_backend_by_model"
        case startupPreload = "startup_preload"
        case preloadModels = "preload_models"
        case startupPreloadTimeoutSecs = "startup_preload_timeout_secs"
        case startupSelftest = "startup_selftest"
        case startupSelftestFailClosed = "startup_selftest_fail_closed"
        case mtp
        case mtpDrafterPath = "mtp_drafter_path"
    }

    /// RETIRED `[backend]` keys (v0.7.5 one-engine): parsed for presence
    /// only, values ignored. See `retiredKeysPresent`.
    private enum RetiredCodingKeys: String, CodingKey, CaseIterable {
        case continuousBatching = "continuous_batching"
        case adaptivePrefill = "adaptive_prefill"
        case engineV2 = "engine_v2"
        case legacyCompiledDecode = "legacy_compiled_decode"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? 8100
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.enabledModels = try container.decodeIfPresent([String].self, forKey: .enabledModels) ?? []
        self.idleTimeoutMins = try container.decodeIfPresent(UInt64.self, forKey: .idleTimeoutMins) ?? 60
        self.maxModelSlots = try container.decodeIfPresent(UInt64.self, forKey: .maxModelSlots) ?? 3
        self.kvQuant = try container.decodeIfPresent(Bool.self, forKey: .kvQuant) ?? false
        self.engineV2MaxConcurrent =
            try container.decodeIfPresent(UInt64.self, forKey: .engineV2MaxConcurrent) ?? 4
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
        self.mtp = try container.decodeIfPresent(Bool.self, forKey: .mtp) ?? false
        self.mtpDrafterPath = try container.decodeIfPresent(String.self, forKey: .mtpDrafterPath)
        // Retired keys: presence-only scan so startup can WARN (values are
        // ignored; an old provider.toml must keep loading cleanly).
        let retired = try decoder.container(keyedBy: RetiredCodingKeys.self)
        self.retiredKeysPresent = RetiredCodingKeys.allCases
            .filter { retired.contains($0) }
            .map(\.rawValue)
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

    public init(
        provider: ProviderSettings,
        backend: BackendSettings = BackendSettings(),
        coordinator: CoordinatorSettings = CoordinatorSettings(),
        schedule: ScheduleConfig? = nil,
        gemmaOptimizations: GemmaOptimizationSettings = GemmaOptimizationSettings()
    ) {
        self.provider = provider
        self.backend = backend
        self.coordinator = coordinator
        self.schedule = schedule
        self.gemmaOptimizations = gemmaOptimizations
    }

    enum CodingKeys: String, CodingKey {
        case provider
        case backend
        case coordinator
        case schedule
        case gemmaOptimizations = "gemma_optimizations"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.provider = try container.decodeIfPresent(ProviderSettings.self, forKey: .provider) ?? ProviderSettings(name: "darkbloom")
        self.backend = try container.decodeIfPresent(BackendSettings.self, forKey: .backend) ?? BackendSettings()
        self.coordinator = try container.decodeIfPresent(CoordinatorSettings.self, forKey: .coordinator) ?? CoordinatorSettings()
        self.schedule = try container.decodeIfPresent(ScheduleConfig.self, forKey: .schedule)
        self.gemmaOptimizations = try container.decodeIfPresent(
            GemmaOptimizationSettings.self, forKey: .gemmaOptimizations
        ) ?? GemmaOptimizationSettings()
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
