import Foundation
import ProviderAppAttest

/// The other half of the service's environment allowlist: every `DARKBLOOM_*`
/// key the provider sources read that `passthroughEnvKeys` does not carry,
/// with the reason it stays out of the service plist.
///
/// launchd does not inherit the installing shell, so a key in neither list
/// works in a foreground run and is silently unset in an installed service.
/// `ServiceEnvironmentReachTests` scans the sources and fails on such a key,
/// on a key declared twice and on an entry no other source spells any more.
/// The same plist environment reaches the cluster service job
/// (`ClusterServiceAgent.job`). The watchdog job has its own short list
/// (`WatchdogAgent.passthroughEnvKeys`).
extension LaunchAgent {
    /// Why a key is not written into the service plist. Each reason is a
    /// claim about where the key is read; an entry is classified by reading
    /// its reader, not its name.
    enum UnforwardedReason: String, CaseIterable, Sendable {
        /// Read only by a command a person runs in a terminal. The service
        /// never runs that code.
        case cliOnly
        /// Compiled or honoured only in a debug build (`#if DEBUG`, a
        /// `debugBuild` gate). A release service cannot read it.
        case debugOnly
        /// Read only by a benchmark, test harness or qualification
        /// diagnostic, which is a foreground process.
        case harness
        /// Moves a state file, socket or directory so tests and development
        /// stay off the live install. A release build ignores the
        /// `LocationOverride` ones.
        case pathOverride
        /// The service takes the value from `provider.toml`: the process sets
        /// or replaces the variable itself.
        case configBacked
        /// Written by a `darkbloom` process into the environment of a process
        /// it starts (a worker, a rank, a supervised child). Never the
        /// operator's value to carry.
        case processHandoff
        /// A candidate, tuning, diagnosis or hardware-test control on code the
        /// service also runs, read in every build. It stays out of the service
        /// so an installed provider runs the release's defaults; it applies to
        /// foreground and local runs.
        ///
        /// Not a place for a variable only a developer's build should honour:
        /// every build reads these. Such a variable is `debugOnly`, or a
        /// `pathOverride`, and is gated where it is read.
        case engineeringControl
        /// Retired: recognised only so startup can warn that it does nothing.
        case retired
        /// Open decision. Code or operator documentation presents the key as
        /// an operator's limit, kill switch, rollback or start setting, the
        /// service's own code reads it in a release build, and it does not
        /// reach the service. Forwarding one changes what an installed service
        /// does, so each move to `passthroughEnvKeys` is a maintainer's
        /// decision. Never add to this case: a new key is forwarded or given
        /// one of the reasons above.
        case undecided
    }

    /// Keys `passthroughEnvironment` writes under a value rule of its own
    /// instead of the allowlist loop (only exact `1` is persisted).
    static let valueConditionalPassthroughEnvKeys = [
        AppAttestWorkerSelection.qualificationEnvironment,
    ]

    /// Every `DARKBLOOM_*` key that can reach the service plist.
    static let forwardedEnvKeys = Set(passthroughEnvKeys + valueConditionalPassthroughEnvKeys)

    /// A key family the sources build from a prefix, declared whole. A key
    /// under a prefix here is not listed in `unforwardedEnvKeyGroups`.
    static let unforwardedEnvKeyPrefixes: [String: UnforwardedReason] = [
        // The rank's wire for its prefix SSD tier: the owner resolves the
        // product's cache settings into these and writes them into the rank's
        // environment (`DistributedInstalledPrefixSSD.environment`,
        // `ClusterPrefixCacheSettings.rankSwitches`). In the owner's own
        // environment they are diagnosis overrides.
        "DARKBLOOM_CLUSTER_PREFIX_SSD_": .processHandoff,
    ]

    /// The declarations, one group a reason. A key appears once.
    static let unforwardedEnvKeyGroups: [(reason: UnforwardedReason, keys: [String])] = [
        (.undecided, [
            // Request media limits, read once per process by the request
            // path (`MediaIngest`). Their sibling
            // `DARKBLOOM_MAX_IMAGES_PER_REQUEST` is forwarded.
            "DARKBLOOM_MAX_IMAGE_MEGAPIXELS",
            "DARKBLOOM_MAX_REQUEST_IMAGE_MEGAPIXELS",
            "DARKBLOOM_MAX_MEDIA_MIB",
            "DARKBLOOM_MAX_VIDEO_SECONDS",
            "DARKBLOOM_MAX_VIDEOS_PER_REQUEST",
            "DARKBLOOM_MAX_REQUEST_VIDEO_FRAME_MEGAPIXELS",
            // Memory safeguards (`UnifiedMemoryCap`), whose semantics are
            // coordinated with platform admission.
            "DARKBLOOM_MEM_CAP_FRACTION",
            "DARKBLOOM_ACTIVATION_RESERVE_GB",
            // The lower-only operator ceiling on vision tower patches
            // (`VisionTowerBudget.operatorPatchCeiling`).
            "DARKBLOOM_VISION_MAX_TOWER_PATCHES",
            // The service's own update loop reads it
            // (`ProviderLoop.startAutoUpdateMonitor`), yet only the watchdog
            // job receives it (`WatchdogAgent.passthroughEnvKeys`).
            "DARKBLOOM_NO_UPDATE_CHECK",
            // "Emergency rollback" to one request-lifetime deadline
            // (`EngineV2Factory.legacyRequestTimeoutEnabled`).
            "DARKBLOOM_CBV2_LEGACY_REQUEST_TIMEOUT",
            // The load-time parity gate's kill switch
            // (`EngineV2VLMTextExtraction.parityCheckFlag`).
            "DARKBLOOM_ENGINE_V2_VLM_PARITY_CHECK",
            // The local API's start setting for Transformers' tool JSON, and
            // the rendering's kill switch (`TemplateJSONOrder`,
            // `HFTemplateFilters.legacyRequested`).
            "DARKBLOOM_TEMPLATE_JSON",
            "DARKBLOOM_TEMPLATE_JSON_LEGACY",
            // The rollback to the original weight-hashing reader and serial
            // order (`WeightHasher`).
            "DARKBLOOM_EXPERIMENT_HASH_WORKERS",
            "DARKBLOOM_EXPERIMENT_HASH_STREAM_FIRST",
            // The SSD tier's lower-only entry lifetime
            // (`SSDPrefixCachePolicy.ttlSeconds`). The tier's disk and daily
            // write limits are forwarded.
            "DARKBLOOM_PREFIX_CACHE_SSD_TTL_SECONDS",
            // A pair's warmup kill switch and its local queue depth
            // (`ProviderLoop.clusterWarmupEnabled`,
            // `DistributedRequestQueue.Limits.fromEnvironment`).
            "DARKBLOOM_CLUSTER_WARMUP",
            "DARKBLOOM_CLUSTER_QUEUE_WAITING",
        ]),
        (.cliOnly, [
            // The terminal's motion (`DarkbloomCommandLook`,
            // `ClusterOnboardingTerminal`).
            "DARKBLOOM_NO_ANIMATION",
            // `darkbloom desktop` attaching a review build to an existing
            // install (`Desktop.Serve.run`). The desktop launchd job runs the
            // same command, but its plist carries no environment
            // (`DesktopService`), so only a terminal run can set it.
            "DARKBLOOM_DESKTOP_ATTACH_ONLY",
        ]),
        (.debugOnly, [
            "DARKBLOOM_ADDON_DEV_IDENTITY",
            "DARKBLOOM_DEBUG_CACHE_KEY_FILE",
            "DARKBLOOM_DEBUG_CLUSTER_SOLO_GRACE_SECONDS",
            "DARKBLOOM_DEBUG_COORDINATOR_CERT_SHA256",
            "DARKBLOOM_DEBUG_OWNER_EXECUTABLE",
            "DARKBLOOM_DEBUG_ROSTER_UNPAIRED",
            "DARKBLOOM_DEBUG_SE_KEY_FILE",
            "DARKBLOOM_KEYCHAIN_ACCESS_GROUP",
            // Planner overrides a release build refuses to plan under.
            "DARKBLOOM_CLUSTER_FORCE_MODE",
            "DARKBLOOM_DEV_BENCH_CHIP",
            "DARKBLOOM_DEV_BENCH_PLANNER_CAP_GIB",
        ]),
        (.harness, [
            // `ProviderBenchmark` inputs.
            "DARKBLOOM_ARRIVAL_TOLERANCE_MS",
            "DARKBLOOM_MTP_VERIFICATION_MODE",
            "DARKBLOOM_QWEN_FCFS_EXPECTED_MODEL_HASH",
            "DARKBLOOM_QWEN_FCFS_ITERATIONS",
            "DARKBLOOM_QWEN_FCFS_KV_BACKEND",
            "DARKBLOOM_QWEN_FCFS_LIVE",
            "DARKBLOOM_QWEN_FCFS_MODEL_ID",
            "DARKBLOOM_QWEN_FCFS_MODEL_PATH",
            "DARKBLOOM_QWEN_FCFS_OUTPUT",
            "DARKBLOOM_QWEN_FCFS_SOURCE_SHA",
            // The benchmark session's acceptance rule; serving reads
            // `[backend] mtp_acceptance` (`MTPAcceptancePolicy.benchmarkOverride`).
            "DARKBLOOM_MTP_ACCEPTANCE",
            // The benchmark route probe, and the SDK switches it only records
            // (`DiffusionBenchmarkRouteProbe`).
            "DARKBLOOM_DIFFUSION_DESCRIPTOR_PROBE",
            "DARKBLOOM_DIFFUSION_COMPILED_SAMPLER",
            "DARKBLOOM_DIFFUSION_EXPERT_UNSORT",
            "DARKBLOOM_DIFFUSION_SOFT_EMBEDDING",
            // The restart benchmark's persistent key. The serving path
            // reads it in every build, but only inside a test root
            // (`SSDPrefixCacheFactory.forceEphemeralKey`), which a service
            // never has.
            "DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY",
            // Opt-ins of the physical qualification entries, which load no
            // launch agent (`NativeServeQualification`,
            // `AppAttestQualificationCommand`).
            "DARKBLOOM_NATIVE_APPKIT_QUALIFICATION",
            "DARKBLOOM_NATIVE_APP_ATTEST_QUALIFICATION",
            "DARKBLOOM_NATIVE_SERVE_QUALIFICATION",
            "DARKBLOOM_NATIVE_WORKER_SERVE_QUALIFICATION",
        ]),
        (.pathOverride, [
            // `LocationOverride`: read by a debug build only. The watchdog
            // job does receive the state file and its own state path.
            "DARKBLOOM_AUTH_TOKEN_PATH",
            "DARKBLOOM_LOADED_MODELS_FILE",
            "DARKBLOOM_LOCAL_DIR",
            "DARKBLOOM_PID_FILE",
            "DARKBLOOM_STATE_FILE",
            "DARKBLOOM_VERIFIED_WEIGHTS_FILE",
            "DARKBLOOM_WATCHDOG_STATE",
            // Test locations every build reads.
            "DARKBLOOM_ADDON_SOCKET",
            "DARKBLOOM_CLUSTER_SUPERVISOR_STATE",
            "DARKBLOOM_DESKTOP_DIR",
            "DARKBLOOM_PREFIX_CACHE_TEST_ROOT",
            "DARKBLOOM_SANDBOX_ROOT",
        ]),
        (.configBacked, [
            // Projected from `provider.toml` at process start
            // (`GemmaOptimizationEnvironment.apply`).
            "DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL",
            // The managed Super slot replaces both from `backend.mtp_mode` and
            // `backend.engine_v2_max_concurrent`
            // (`NemotronSuperServingPolicy.loadPlan`).
            "DARKBLOOM_NEMOTRON_SUPER_MAX_CONCURRENT",
            "DARKBLOOM_NEMOTRON_SUPER_MTP",
        ]),
        (.processHandoff, [
            // The marker a `darkbloom` process leaves for its children
            // (`SDKFeatureDefaults.injectedMarkerKey`).
            "DARKBLOOM_SDK_DEFAULTS_INJECTED",
            // Where a supervisor tells its child to write its heartbeat.
            "DARKBLOOM_CLUSTER_MEMBER_HEALTH_FILE",
            // What an owner writes into a rank's environment
            // (`DistributedInstalledPlan.nativeEnvironment`); in the owner's
            // own environment the cluster switches are diagnosis overrides.
            "DARKBLOOM_BF16_WEIGHTS",
            "DARKBLOOM_BONSAI_F16_CONSTANT_CACHE",
            "DARKBLOOM_BONSAI_PREFILL_CARRY_ASYNC",
            "DARKBLOOM_CLUSTER_BATCH_LANES",
            "DARKBLOOM_CLUSTER_PREFIX_CACHE",
            "DARKBLOOM_CLUSTER_PREFIX_SSD",
            // The identities a calibration launch binds into its ranks'
            // environment (`GLM5NextCalibrationLaunch.requireEnvironment`).
            "DARKBLOOM_GLM_CALIBRATION_APP_SHA256",
            "DARKBLOOM_GLM_CALIBRATION_PEER_SHA256",
        ]),
        (.engineeringControl, [
            // Scheduler and backend tuning and measurement.
            "DARKBLOOM_CBV2_ATTN_QUERY_BLOCK",
            "DARKBLOOM_CBV2_MIXED_PREFILL_CAP",
            "DARKBLOOM_CBV2_MIXED_PREFILL_CAP_BY_MODEL",
            "DARKBLOOM_CBV2_PAGED_KV_DTYPE",
            "DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE",
            // The opted-in resident checkpoint bank, documented as foreground
            // and local only.
            "DARKBLOOM_CBV2_HYBRID_PREFIX_BYTES",
            "DARKBLOOM_CBV2_HYBRID_PREFIX_CACHE",
            // Candidate and local qualification controls: installed processes
            // keep the source defaults.
            "DARKBLOOM_EXPERIMENTAL_GLM5_NEXT",
            "DARKBLOOM_MIMO_NATIVE_PAGED_TARGET",
            "DARKBLOOM_QWEN4_BATCHED_QSA",
            "DARKBLOOM_QWEN4_LISTING_CONTEXT",
            "DARKBLOOM_QWEN4_MODEL_PATH",
            // The Super qualification hook's runtime policy keys, kept when
            // set in the provider process.
            "DARKBLOOM_NEMOTRON_SUPER_KV_BACKEND",
            "DARKBLOOM_NEMOTRON_SUPER_MTP_DEPTH",
            "DARKBLOOM_NEMOTRON_SUPER_MTP_VERIFICATION",
            "DARKBLOOM_NEMOTRON_SUPER_PREFILL_CHUNK",
            "DARKBLOOM_NEMOTRON_SUPER_VIDEO_PRUNING",
            // SSD tier tuning, and the unsigned build's in-memory key.
            "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL",
            "DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MB",
            "DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MS",
            "DARKBLOOM_PREFIX_CACHE_SSD_MIN_EFFECTIVE_TOKENS",
            "DARKBLOOM_PREFIX_CACHE_SSD_STRICT_FSYNC",
            "DARKBLOOM_PREFIX_CACHE_SSD_WINDOW_SIDECAR",
            "DARKBLOOM_PREFIX_CACHE_STATS_INTERVAL_SECS",
            // The local API's error text on stderr. Not gated on a debug
            // build, despite its name.
            "DARKBLOOM_DEBUG_LOCAL_ERRORS",
            // Cluster diagnosis and engineering opt-ins the setup never offers.
            // A production build ignores the SSH harness.
            "DARKBLOOM_CLUSTER_DEVELOPER_SSH",
            "DARKBLOOM_CLUSTER_HANDOFF_MODES",
            "DARKBLOOM_CLUSTER_LOAD_DIGESTS",
            "DARKBLOOM_CLUSTER_LOAD_PATH",
            // Supervisor timers that hardware tests shorten.
            "DARKBLOOM_CLUSTER_GUARD_DOWN_SECONDS",
            "DARKBLOOM_CLUSTER_GUARD_INTERVAL_SECONDS",
            "DARKBLOOM_CLUSTER_GUARD_START_GRACE_SECONDS",
            "DARKBLOOM_CLUSTER_RESTART_BACKOFF_INITIAL_SECONDS",
            "DARKBLOOM_CLUSTER_RESTART_BACKOFF_MAX_SECONDS",
            "DARKBLOOM_CLUSTER_RESTART_MAX_GUARD_TEARDOWNS",
            "DARKBLOOM_CLUSTER_RESTART_MAX_QUICK_FAILURES",
            "DARKBLOOM_CLUSTER_RESTART_WINDOW_SECONDS",
        ]),
        (.retired, [
            // `EngineV2Config.retiredEnvironmentKeys`.
            "DARKBLOOM_ADAPTIVE_PREFILL_ALLOW_8192",
            "DARKBLOOM_B1_GREEDY_FAST_PATH",
            "DARKBLOOM_COMPILED_DECODE",
            "DARKBLOOM_ENGINE_V2",
            "DARKBLOOM_ENGINE_V2_MODELS",
            "DARKBLOOM_GEMMA_B1_FAST_PATH",
            "DARKBLOOM_KV_CAPTURE_MAX_INFLIGHT",
            "DARKBLOOM_KV_GPTOSS_KERNEL",
            "DARKBLOOM_PREFIX_CACHE_MIN_PERSIST_TOKENS",
        ]),
    ]

    /// Each declared key's reason. A key listed twice keeps its first reason;
    /// the test refuses the duplicate.
    static let unforwardedEnvKeys: [String: UnforwardedReason] = unforwardedEnvKeyGroups.reduce(into: [:]) { out, group in
        for key in group.keys where out[key] == nil { out[key] = group.reason }
    }

    /// The reason `key` does not reach the service, from its own entry or its
    /// family's prefix; nil for a forwarded or undeclared key.
    static func unforwardedReason(for key: String) -> UnforwardedReason? {
        unforwardedEnvKeys[key]
            ?? unforwardedEnvKeyPrefixes.first { key.hasPrefix($0.key) }?.value
    }
}
