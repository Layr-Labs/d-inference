import Foundation
import Testing
@testable import ProviderCore

/// Tests for the `LaunchAgent` restart error surface. The launchctl
/// kickstart/bootstrap behaviour itself is environment-dependent (it mutates a
/// real launchd domain) and is covered by manual verification; here we pin the
/// pure, deterministic pieces: the new error cases and their messages.
@Suite("LaunchAgent restart errors")
struct LaunchAgentRestartTests {

    @Test("notInstalled explains how to start the provider")
    func notInstalledDescription() {
        let message = LaunchAgentError.notInstalled.description
        #expect(message.contains("not installed"))
        #expect(message.contains("darkbloom start"))
    }

    @Test("kickstartFailed surfaces the underlying detail")
    func kickstartFailedDescription() {
        let message = LaunchAgentError.kickstartFailed("boom").description
        #expect(message.contains("kickstart"))
        #expect(message.contains("boom"))
    }

    // `darkbloom stop` must persistently disable the agent (launchctl disable)
    // in addition to bootout: bootout only affects the current login session,
    // and the plist left on disk (RunAtLoad=true) would otherwise restart the
    // provider at the next reboot/login. If the disable fails, the error must
    // warn the user about exactly that.
    @Test("disableFailed warns the provider may auto-start at next login")
    func disableFailedDescription() {
        let message = LaunchAgentError.disableFailed("boom").description
        #expect(message.contains("disable"))
        #expect(message.contains("auto-start"))
        #expect(message.contains("boom"))
    }

    @Test("watchdog disableFailed warns it may auto-start at next login")
    func watchdogDisableFailedDescription() {
        let message = WatchdogAgentError.disableFailed("boom").description
        #expect(message.contains("disable"))
        #expect(message.contains("auto-start"))
        #expect(message.contains("boom"))
    }
}

@Suite("LaunchAgent environment passthrough")
struct LaunchAgentEnvironmentTests {
    @Test func forwardsAllowlistedNonEmptyVars() {
        let env = ["DARKBLOOM_PREFIX_CACHE": "0", "PATH": "/usr/bin", "HOME": "/Users/x"]
        let out = LaunchAgent.passthroughEnvironment(from: env)
        // Only the allowlisted opt-out is forwarded to the daemon; PATH/HOME are not.
        #expect(out == ["DARKBLOOM_PREFIX_CACHE": "0"])
    }

    @Test func forwardsTheHuggingFaceCacheRootSoTheDaemonScansTheShellsCache() {
        let out = LaunchAgent.passthroughEnvironment(from: [
            "HF_HOME": "/Volumes/models/hf",
            "HF_HUB_CACHE": "/Volumes/models/hf/hub",
            "HOME": "/Users/x",
        ])
        #expect(out == ["HF_HOME": "/Volumes/models/hf", "HF_HUB_CACHE": "/Volumes/models/hf/hub"])
        // The daemon resolves the same cache the installing shell used.
        #expect(
            ModelScanner.resolveCacheDirectory(environment: out).path
                == "/Volumes/models/hf/hub")
    }

    @Test func dropsEmptyAndMissingVars() {
        #expect(LaunchAgent.passthroughEnvironment(from: [:]).isEmpty)
        let out = LaunchAgent.passthroughEnvironment(from: [
            "DARKBLOOM_PREFIX_CACHE": "",
            EngineV2Factory.maxPartialPrefillsKey: "",
            PrefillDeadlineMode.environmentKey: "",
            "UNRELATED_SECRET": "excluded",
        ])
        #expect(out.isEmpty)
        #expect(EngineV2Factory.maxConcurrentPartialPrefills(environment: out) == 1)
        #expect(PrefillDeadlineMode.resolve(environment: out) == .enforce)
    }

    @Test func sourceAwareResolutionMatchesForegroundAndLaunchd() {
        let configuredCases: [(name: String, value: PrefillDeadlineMode?)] = [
            ("absent", nil),
            ("enforce", .enforce),
            ("off", .off),
        ]
        let environmentCases: [(name: String, value: String?)] = [
            ("missing", nil),
            ("off", "off"),
            ("enforce", "enforce"),
            ("malformed", "garbage"),
            ("empty", ""),
        ]
        for configuredCase in configuredCases {
            for environmentCase in environmentCases {
                let foreground = environmentCase.value.map {
                    [PrefillDeadlineMode.environmentKey: $0]
                } ?? [:]
                let launchd = LaunchAgent.passthroughEnvironment(from: foreground)
                let expected: PrefillDeadlineMode =
                    configuredCase.value
                    ?? (environmentCase.value == "off" ? .off : .enforce)
                #expect(
                    PrefillDeadlineMode.resolve(
                        configured: configuredCase.value,
                        environment: foreground) == expected,
                    "foreground configured=\(configuredCase.name), env=\(environmentCase.name)")
                #expect(
                    PrefillDeadlineMode.resolve(
                        configured: configuredCase.value,
                        environment: launchd) == expected,
                    "launchd configured=\(configuredCase.name), env=\(environmentCase.name)")
                if environmentCase.name == "empty" {
                    #expect(launchd[PrefillDeadlineMode.environmentKey] == nil)
                }
            }
        }
    }

    @Test func forwardsPrefillOperationalControlsUnchanged() {
        let out = LaunchAgent.passthroughEnvironment(from: [
            EngineV2Factory.maxPartialPrefillsKey: "0",
            PrefillDeadlineMode.environmentKey: "enforce",
            "UNRELATED_SECRET": "excluded",
        ])
        #expect(out == [
            EngineV2Factory.maxPartialPrefillsKey: "0",
            PrefillDeadlineMode.environmentKey: "enforce",
        ])
        #expect(EngineV2Factory.maxConcurrentPartialPrefills(environment: out) == nil)
        #expect(PrefillDeadlineMode.resolve(environment: out) == .enforce)
    }

    @Test func preservesMalformedNonEmptyControlsForRuntimeSecureDefault() {
        let out = LaunchAgent.passthroughEnvironment(from: [
            EngineV2Factory.maxPartialPrefillsKey: "not-an-integer",
            PrefillDeadlineMode.environmentKey: "invalid",
        ])
        #expect(out == [
            EngineV2Factory.maxPartialPrefillsKey: "not-an-integer",
            PrefillDeadlineMode.environmentKey: "invalid",
        ])
        #expect(EngineV2Factory.maxConcurrentPartialPrefills(environment: out) == nil)
        #expect(PrefillDeadlineMode.resolve(environment: out) == .enforce)
    }

    @Test func forwardsResourceDebugOptOutToDaemon() {
        // The MLX resource telemetry is default-on; its documented opt-out
        // (DARKBLOOM_MLX_RESOURCE_DEBUG=0) only works on the launchd service if it
        // is forwarded into the plist. Without this, the daemon can't be quieted.
        let out = LaunchAgent.passthroughEnvironment(
            from: ["DARKBLOOM_MLX_RESOURCE_DEBUG": "0", "PATH": "/usr/bin"])
        #expect(out == ["DARKBLOOM_MLX_RESOURCE_DEBUG": "0"])
    }

    @Test func forwardsMTPKillSwitchToDaemon() {
        let out = LaunchAgent.passthroughEnvironment(
            from: ["DARKBLOOM_CBV2_MTP": "0", "PATH": "/usr/bin"])
        #expect(out == ["DARKBLOOM_CBV2_MTP": "0"])
    }

    @Test func forwardsMTPRectangularCapOverrideToDaemon() {
        // The tighten-only cap override is the operator's lever to reduce
        // rectangular verification short of disabling MTP; it must survive
        // service install/restart.
        let out = LaunchAgent.passthroughEnvironment(
            from: ["DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS": "4", "PATH": "/usr/bin"])
        #expect(out == ["DARKBLOOM_MTP_MAX_RECTANGULAR_TOKENS": "4"])
    }

    @Test func excludesConfigBackedGemmaControlsFromDaemonEnvironment() {
        let out = LaunchAgent.passthroughEnvironment(from: [
            "DARKBLOOM_PREFIX_CACHE": "0",
            GemmaOptimizationEnvironment.prefillLayer18Key: "poison",
            GemmaOptimizationEnvironment.weightedUnsortKey: "poison",
            GemmaOptimizationEnvironment.safeR1Key: "poison",
        ])
        #expect(out == ["DARKBLOOM_PREFIX_CACHE": "0"])
    }

    @Test func persistsOperatorDrainRefinementIntoDaemonEnvironment() {
        // Serving defaults to trust. launchd does not inherit the installing
        // shell, so the one legal operator refinement (safe R1 = 1, restore
        // the drain) must be persisted into the plist or the background
        // daemon silently collapses it back to trust.
        let out = LaunchAgent.passthroughEnvironment(from: [
            GemmaOptimizationEnvironment.safeR1Key: "1",
            GemmaOptimizationEnvironment.weightedUnsortKey: "1",
            "PATH": "/usr/bin",
        ])
        // Only safe R1 carries the refinement; the coupled weighted-unsort
        // key stays config-backed and excluded.
        #expect(out == [GemmaOptimizationEnvironment.safeR1Key: "1"])
    }

    @Test func excludesConfigExactGemmaValuesEvenWhenSet() {
        // "0"/"trust" are config/default territory: forwarding them would
        // freeze a past decision into the plist and fight later TOML edits
        // or the serving default.
        for value in ["0", "trust"] {
            #expect(LaunchAgent.passthroughEnvironment(
                from: [GemmaOptimizationEnvironment.safeR1Key: value]).isEmpty)
        }
    }

    /// T13-06 (a): the documented, raise-only activation-reserve lever reaches
    /// the launchd daemon; the undocumented cap fraction and the parity
    /// harness's dtype posture stay foreground-only.
    @Test func forwardsActivationReserveButNotCapFractionOrHarnessDtype() {
        let out = LaunchAgent.passthroughEnvironment(from: [
            "DARKBLOOM_ACTIVATION_RESERVE_GB": "8",
            "DARKBLOOM_MEM_CAP_FRACTION": "0.5",
            "DARKBLOOM_CBV2_PAGED_KV_DTYPE": "fp16",
            "PATH": "/usr/bin",
        ])
        #expect(out["DARKBLOOM_ACTIVATION_RESERVE_GB"] == "8")
        #expect(out["DARKBLOOM_MEM_CAP_FRACTION"] == nil)
        #expect(out["DARKBLOOM_CBV2_PAGED_KV_DTYPE"] == nil)
        #expect(out["PATH"] == nil)
        // Empty is dropped like every other allowlisted key.
        #expect(LaunchAgent.passthroughEnvironment(
            from: ["DARKBLOOM_ACTIVATION_RESERVE_GB": ""])["DARKBLOOM_ACTIVATION_RESERVE_GB"] == nil)
        // The watchdog job never runs inference and stays without it.
        #expect(WatchdogAgent.passthroughEnvironment(
            from: ["DARKBLOOM_ACTIVATION_RESERVE_GB": "8"])["DARKBLOOM_ACTIVATION_RESERVE_GB"] == nil)
    }

    @Test func forwardsMLXMemoryGuardKnobsToDaemon() {
        // The MLXMemoryGuard operator knobs only matter in the launchd
        // daemon (the normal `darkbloom start` mode). Without passthrough, a
        // shell export of the cache cap — the advertised recovery lever for
        // the 8 GiB buffer-pool default — would silently no-op there.
        let out = LaunchAgent.passthroughEnvironment(from: [
            "DARKBLOOM_MLX_CACHE_LIMIT_GB": "32",
            "DARKBLOOM_MLX_MEMORY_RESERVE_GB": "12",
            "PATH": "/usr/bin",
        ])
        #expect(out == [
            "DARKBLOOM_MLX_CACHE_LIMIT_GB": "32",
            "DARKBLOOM_MLX_MEMORY_RESERVE_GB": "12",
        ])
    }

    @Test func forwardsKVBackendGuardPathToDaemonAndWatchdog() {
        // The crash-loop guard record has one writer (the launchd watchdog)
        // and several readers (the launchd daemon's engine factory, a
        // shell-invoked status/doctor). A shell-set path override must reach
        // BOTH launchd jobs or the writers and readers split across two
        // files and the guard silently never binds.
        let env = [KVBackendGuardStore.pathEnvKey: "/tmp/guard.json", "PATH": "/usr/bin"]
        #expect(LaunchAgent.passthroughEnvironment(from: env)
            == [KVBackendGuardStore.pathEnvKey: "/tmp/guard.json"])
        #expect(WatchdogAgent.passthroughEnvironment(from: env)
            == [KVBackendGuardStore.pathEnvKey: "/tmp/guard.json"])
    }

    @Test func forwardsEngineReadInferenceKeys() {
        // Every engine-read key parsed at engine/model construction must
        // survive into the daemon plist, or an operator export silently
        // no-ops on the launchd (watchdog/restart) path. Empty values are
        // dropped; unrelated variables never leak in.
        let env = [
            "DARKBLOOM_CBV2_MIXED_PREFILL_CAP": "256",
            "DARKBLOOM_CBV2_PREFILL_NARROWING": "0",
            "CBV2_STEP_PROFILE": "1",
            "MLX_COMPILED_DECODE": "0",
            "MLX_QWEN_DIRECT_EXPERT_REDUCTION": "1",
            "DARKBLOOM_CBV2_PAGED_KV": "",
            "PATH": "/usr/bin",
            "HOME": "/Users/x",
        ]
        let out = LaunchAgent.passthroughEnvironment(from: env)
        #expect(out == [
            "DARKBLOOM_CBV2_MIXED_PREFILL_CAP": "256",
            "DARKBLOOM_CBV2_PREFILL_NARROWING": "0",
            "CBV2_STEP_PROFILE": "1",
            "MLX_COMPILED_DECODE": "0",
            "MLX_QWEN_DIRECT_EXPERT_REDUCTION": "1",
        ])
        // The watchdog job deliberately carries none of the inference keys.
        #expect(WatchdogAgent.passthroughEnvironment(from: env).isEmpty)
    }
}

@Suite("LaunchAgent service plist")
struct LaunchAgentServicePlistTests {
    @Test(
        "installed service plist retains prefill controls for launchd restarts",
        arguments: [PrefillDeadlineMode.off, PrefillDeadlineMode.enforce]
    )
    func prefillControlsSurviveInstallAndRestart(mode: PrefillDeadlineMode) throws {
        let plist = LaunchAgent.makeServicePlist(
            label: "io.darkbloom.provider",
            programArguments: ["/usr/local/bin/darkbloom", "start", "--foreground"],
            logPath: "/tmp/p.log",
            environment: [
                EngineV2Factory.maxPartialPrefillsKey: "0",
                PrefillDeadlineMode.environmentKey: mode.rawValue,
                "UNRELATED_SECRET": "excluded",
            ]
        )

        // Installation serializes this dictionary to disk. Both manual and
        // watchdog restarts kickstart the same provider job, so this persisted
        // EnvironmentVariables map is the environment used after either path.
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        let installed = try #require(
            PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        #expect((installed["EnvironmentVariables"] as? [String: String]) == [
            EngineV2Factory.maxPartialPrefillsKey: "0",
            PrefillDeadlineMode.environmentKey: mode.rawValue,
        ])
    }

    @Test func autoStartsAtLoadAndForwardsAllowlistedEnv() {
        let plist = LaunchAgent.makeServicePlist(
            label: "io.darkbloom.provider",
            programArguments: ["/usr/local/bin/darkbloom", "start", "--foreground"],
            logPath: "/tmp/p.log",
            environment: [
                "DARKBLOOM_PREFIX_CACHE": "0",
                GemmaOptimizationEnvironment.prefillLayer18Key: "poison",
                GemmaOptimizationEnvironment.weightedUnsortKey: "poison",
                GemmaOptimizationEnvironment.safeR1Key: "poison",
                "PATH": "/usr/bin",
            ]
        )
        // RunAtLoad=true so a rebooted / auto-login box restarts (and re-attests via
        // APNs) with no human; KeepAlive stays false to avoid racing the self-updater.
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == false)
        #expect((plist["EnvironmentVariables"] as? [String: String]) == ["DARKBLOOM_PREFIX_CACHE": "0"])
    }

    @Test func persistsDrainRefinementIntoServicePlist() {
        let plist = LaunchAgent.makeServicePlist(
            label: "io.darkbloom.provider",
            programArguments: ["/usr/local/bin/darkbloom", "start", "--foreground"],
            logPath: "/tmp/p.log",
            environment: [
                GemmaOptimizationEnvironment.safeR1Key: "1",
                "PATH": "/usr/bin",
            ]
        )
        #expect((plist["EnvironmentVariables"] as? [String: String])
            == [GemmaOptimizationEnvironment.safeR1Key: "1"])
    }

    /// launchd SIGKILLs a job `ExitTimeOut` seconds after its SIGTERM
    /// (default 20 s). The daemon now drains in-flight requests on SIGTERM
    /// for up to the graceful drain bound, so the plist must give it that
    /// long — otherwise launchd cuts the drain and the coordinator sees the
    /// very 502s the drain exists to prevent.
    @Test func exitTimeOutCoversTheGracefulDrain() {
        let plist = LaunchAgent.makeServicePlist(
            label: "io.darkbloom.provider",
            programArguments: ["darkbloom", "start", "--foreground"],
            logPath: "/tmp/p.log",
            environment: [:]
        )
        let exitTimeOut = plist["ExitTimeOut"] as? Int
        #expect(exitTimeOut == LaunchAgent.exitTimeOutSeconds)
        #expect((exitTimeOut ?? 0) >= Int(ProviderLoop.gracefulDrainTimeout.components.seconds))
        // Still a bounded stop: a wedged daemon is killed, not waited on forever.
        #expect((exitTimeOut ?? 0) <= 600)
    }

    @Test func omitsEnvironmentWhenNoAllowlistedVarsSet() {
        let plist = LaunchAgent.makeServicePlist(
            label: "io.darkbloom.provider",
            programArguments: ["darkbloom", "start", "--foreground"],
            logPath: "/tmp/p.log",
            environment: ["PATH": "/usr/bin"]
        )
        #expect(plist["EnvironmentVariables"] == nil)
        #expect(plist["RunAtLoad"] as? Bool == true)
    }

    @Test func customConfigFlagAndAbsolutePathStayAdjacent() throws {
        let arguments = LaunchAgent.serviceProgramArguments(
            binaryPath: "/usr/local/bin/darkbloom",
            coordinatorURL: "wss://api.darkbloom.dev/ws/provider",
            models: ["org/model"],
            idleTimeout: 15,
            configPath: URL(fileURLWithPath: "/tmp/custom provider.toml")
        )
        let flagIndex = try #require(arguments.firstIndex(of: "--config"))
        #expect(arguments[flagIndex + 1] == "/tmp/custom provider.toml")
    }

    @Test func defaultConfigPathRemainsImplicit() {
        let arguments = LaunchAgent.serviceProgramArguments(
            binaryPath: "/usr/local/bin/darkbloom",
            coordinatorURL: "wss://api.darkbloom.dev/ws/provider",
            models: [],
            idleTimeout: nil,
            configPath: nil
        )
        #expect(!arguments.contains("--config"))
    }
}
