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

    @Test func dropsEmptyAndMissingVars() {
        #expect(LaunchAgent.passthroughEnvironment(from: [:]).isEmpty)
        #expect(LaunchAgent.passthroughEnvironment(from: ["DARKBLOOM_PREFIX_CACHE": ""]).isEmpty)
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

    @Test func forwardsQwenDirectReductionRollbackToDaemon() {
        let out = LaunchAgent.passthroughEnvironment(from: [
            GemmaOptimizationEnvironment.qwenDirectExpertReductionKey: "0",
            "PATH": "/usr/bin",
        ])
        #expect(out == [GemmaOptimizationEnvironment.qwenDirectExpertReductionKey: "0"])
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
}

@Suite("LaunchAgent service plist")
struct LaunchAgentServicePlistTests {
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
