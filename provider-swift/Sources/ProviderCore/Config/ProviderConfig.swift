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
    public var continuousBatching: Bool
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
    /// Opt-in KV-cache quantization for the validated model families
    /// (GPT-OSS and Gemma 4). Default false serves fp16. When true, those
    /// families store K/V quantized for ~1.9x more admitted tokens; any other
    /// model is unaffected and keeps fp16. Enable per provider by setting
    /// `kv_quant = true` under `[backend]` in provider.toml.
    public var kvQuant: Bool
    /// Opt-in dynamic cold-prefill chunk sizing. Default false preserves the
    /// fixed 512-token production path. Enable with `adaptive_prefill = true`
    /// under `[backend]` in provider.toml.
    public var adaptivePrefill: Bool
    /// RETIRED (v0.7.5): the v2 engine is unconditional — there is no
    /// legacy engine left to select. The key is still parsed so old
    /// provider.toml files load cleanly, and startup WARNs when an operator
    /// set `engine_v2 = false` (the value is otherwise ignored). Full key
    /// removal happens in a later cleanup pass.
    public var engineV2: Bool
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
    /// Opt-in compiled decode for the LEGACY engine (default false). The
    /// mlx-swift-lm library defaults its `DARKBLOOM_COMPILED_DECODE` env
    /// gate ON; the provider forces it OFF at startup unless this is true
    /// or the operator set the env var explicitly (which always wins —
    /// see `LegacyCompiledDecodeGate`). Off keeps release behavior
    /// identical to prod v0.6.30 (the compiled-decode rollback):
    /// no compile-on-first-dispatch cold start, no B=1 window-straddle
    /// divergence. Single-stream speedups ship via the v2 engine instead.
    public var legacyCompiledDecode: Bool
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
    /// serving path (v2 bridge when flagged, else the legacy scheduler) so
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

    public init(
        port: UInt16 = 8100,
        model: String? = nil,
        continuousBatching: Bool = true,
        enabledModels: [String] = [],
        idleTimeoutMins: UInt64 = 60,
        maxModelSlots: UInt64 = 3,
        kvQuant: Bool = false,
        adaptivePrefill: Bool = false,
        engineV2: Bool = true,
        engineV2MaxConcurrent: UInt64 = 4,
        engineV2MaxConcurrentByModel: [String: UInt64] = [:],
        legacyCompiledDecode: Bool = false,
        startupPreload: Bool = true,
        preloadModels: [String] = [],
        startupPreloadTimeoutSecs: UInt64 = 120,
        startupSelftest: Bool = true,
        startupSelftestFailClosed: Bool = false
    ) {
        self.port = port
        self.model = model
        self.continuousBatching = continuousBatching
        self.enabledModels = enabledModels
        self.idleTimeoutMins = idleTimeoutMins
        self.maxModelSlots = maxModelSlots
        self.kvQuant = kvQuant
        self.adaptivePrefill = adaptivePrefill
        self.engineV2 = engineV2
        self.engineV2MaxConcurrent = engineV2MaxConcurrent
        self.engineV2MaxConcurrentByModel = engineV2MaxConcurrentByModel
        self.legacyCompiledDecode = legacyCompiledDecode
        self.startupPreload = startupPreload
        self.preloadModels = preloadModels
        self.startupPreloadTimeoutSecs = startupPreloadTimeoutSecs
        self.startupSelftest = startupSelftest
        self.startupSelftestFailClosed = startupSelftestFailClosed
    }

    enum CodingKeys: String, CodingKey {
        case port
        case model
        case continuousBatching = "continuous_batching"
        case enabledModels = "enabled_models"
        case idleTimeoutMins = "idle_timeout_mins"
        case maxModelSlots = "max_model_slots"
        case kvQuant = "kv_quant"
        case adaptivePrefill = "adaptive_prefill"
        case engineV2 = "engine_v2"
        case engineV2MaxConcurrent = "engine_v2_max_concurrent"
        case engineV2MaxConcurrentByModel = "engine_v2_max_concurrent_by_model"
        case legacyCompiledDecode = "legacy_compiled_decode"
        case startupPreload = "startup_preload"
        case preloadModels = "preload_models"
        case startupPreloadTimeoutSecs = "startup_preload_timeout_secs"
        case startupSelftest = "startup_selftest"
        case startupSelftestFailClosed = "startup_selftest_fail_closed"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? 8100
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.continuousBatching = try container.decodeIfPresent(Bool.self, forKey: .continuousBatching) ?? true
        self.enabledModels = try container.decodeIfPresent([String].self, forKey: .enabledModels) ?? []
        self.idleTimeoutMins = try container.decodeIfPresent(UInt64.self, forKey: .idleTimeoutMins) ?? 60
        self.maxModelSlots = try container.decodeIfPresent(UInt64.self, forKey: .maxModelSlots) ?? 3
        self.kvQuant = try container.decodeIfPresent(Bool.self, forKey: .kvQuant) ?? false
        self.adaptivePrefill = try container.decodeIfPresent(Bool.self, forKey: .adaptivePrefill) ?? false
        self.engineV2 = try container.decodeIfPresent(Bool.self, forKey: .engineV2) ?? true
        self.engineV2MaxConcurrent =
            try container.decodeIfPresent(UInt64.self, forKey: .engineV2MaxConcurrent) ?? 4
        self.engineV2MaxConcurrentByModel =
            try container.decodeIfPresent(
                [String: UInt64].self, forKey: .engineV2MaxConcurrentByModel) ?? [:]
        self.legacyCompiledDecode =
            try container.decodeIfPresent(Bool.self, forKey: .legacyCompiledDecode) ?? false
        self.startupPreload = try container.decodeIfPresent(Bool.self, forKey: .startupPreload) ?? true
        self.preloadModels = try container.decodeIfPresent([String].self, forKey: .preloadModels) ?? []
        self.startupPreloadTimeoutSecs =
            try container.decodeIfPresent(UInt64.self, forKey: .startupPreloadTimeoutSecs) ?? 120
        self.startupSelftest = try container.decodeIfPresent(Bool.self, forKey: .startupSelftest) ?? true
        self.startupSelftestFailClosed =
            try container.decodeIfPresent(Bool.self, forKey: .startupSelftestFailClosed) ?? false
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

    public init(
        provider: ProviderSettings,
        backend: BackendSettings = BackendSettings(),
        coordinator: CoordinatorSettings = CoordinatorSettings(),
        schedule: ScheduleConfig? = nil
    ) {
        self.provider = provider
        self.backend = backend
        self.coordinator = coordinator
        self.schedule = schedule
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.provider = try container.decodeIfPresent(ProviderSettings.self, forKey: .provider) ?? ProviderSettings(name: "darkbloom")
        self.backend = try container.decodeIfPresent(BackendSettings.self, forKey: .backend) ?? BackendSettings()
        self.coordinator = try container.decodeIfPresent(CoordinatorSettings.self, forKey: .coordinator) ?? CoordinatorSettings()
        self.schedule = try container.decodeIfPresent(ScheduleConfig.self, forKey: .schedule)
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
                continuousBatching: true,
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
    public static func load(from path: URL) throws -> ProviderConfig {
        let content: String
        do {
            content = try String(contentsOf: path, encoding: .utf8)
        } catch {
            throw ConfigError.readFailed(path: path.path, underlying: error)
        }
        return parse(content)
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
