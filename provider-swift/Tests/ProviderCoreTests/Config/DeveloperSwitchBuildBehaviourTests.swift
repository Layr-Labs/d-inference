import DarkbloomClusterPlacement
import Foundation
import Testing
@testable import ProviderBuildEnvironment
@_spi(Benchmarking) @testable import ProviderCore

/// What a release build and a debug build do with each developer-only
/// variable, through the functions the product calls and by the variable's
/// literal name. Nothing here names the type that declares the variables, so
/// the same file compiles and passes before and after that type exists: it
/// records the behaviour the declarations must keep.
///
/// Where a function takes its build as a parameter both builds are checked.
/// Where the read sits in an `#if DEBUG` block only this (debug) test build
/// can run it; a release build compiles no such read.
@Suite struct DeveloperSwitchBuildBehaviourTests {
    static let home = URL(fileURLWithPath: "/Users/fixture")

    // MARK: - Debug builds only

    static let locations: [(location: LocationOverride, key: String)] = [
        (.daemonStateFile, "DARKBLOOM_STATE_FILE"), (.loadedModelsFile, "DARKBLOOM_LOADED_MODELS_FILE"),
        (.verifiedWeightsFile, "DARKBLOOM_VERIFIED_WEIGHTS_FILE"), (.pidFile, "DARKBLOOM_PID_FILE"),
        (.watchdogState, "DARKBLOOM_WATCHDOG_STATE"), (.kvBackendGuard, "DARKBLOOM_KV_BACKEND_GUARD"),
        (.authTokenPath, "DARKBLOOM_AUTH_TOKEN_PATH"), (.localDirectory, "DARKBLOOM_LOCAL_DIR"),
        (.modelCDN, "DARKBLOOM_R2_CDN_URL"),
    ]

    @Test func aLocationVariableMovesAFileInADebugBuildOnly() {
        for (location, key) in Self.locations {
            #expect(location.environmentKey == key)
            #expect(location.value(environment: [key: "/elsewhere"], readsEnvironment: true, assigned: [:]) == "/elsewhere")
            #expect(location.value(environment: [key: "/elsewhere"], readsEnvironment: false, assigned: [:]) == nil, "\(key)")
            #expect(location.value(environment: [key: ""], readsEnvironment: true, assigned: [:]) == nil, "\(key)")
        }
        #expect(KVBackendGuardStore.pathEnvKey == "DARKBLOOM_KV_BACKEND_GUARD")
    }

    @Test func theKeychainGroupVariableIsReadByADebugBuildOnly() {
        let environment = ["DARKBLOOM_KEYCHAIN_ACCESS_GROUP": "TEAMID0000.io.example"]
        #expect(KeychainAccessGroup.environmentKey == "DARKBLOOM_KEYCHAIN_ACCESS_GROUP")
        #expect(KeychainAccessGroup.resolved(environment: environment, readsEnvironment: true) == "TEAMID0000.io.example")
        #expect(KeychainAccessGroup.resolved(environment: environment, readsEnvironment: false) == KeychainAccessGroup.signedApp)
        #expect(KeychainAccessGroup.resolved(environment: ["DARKBLOOM_KEYCHAIN_ACCESS_GROUP": ""], readsEnvironment: true)
                == KeychainAccessGroup.signedApp)
    }

    @Test func theBenchChipIsReadByADebugBuildAndRefusedByAReleaseBuild() throws {
        let environment = ["DARKBLOOM_DEV_BENCH_CHIP": "Apple M4 Max"]
        #expect(ClusterBenchChip.environmentName == "DARKBLOOM_DEV_BENCH_CHIP")
        #expect(ClusterBenchChip.chipName(environment: environment, debugBuild: true) == "Apple M4 Max")
        #expect(ClusterBenchChip.chipName(environment: environment, debugBuild: false) == nil)
        #expect(ClusterBenchChip.chipName(environment: ["DARKBLOOM_DEV_BENCH_CHIP": "a toaster"], debugBuild: true) == nil)
        #expect(ClusterChipClass.local(environment: environment, debugBuild: true) == ClusterChipClass(chipName: "Apple M4 Max"))
        #expect(ClusterChipClass.local(environment: environment, debugBuild: false)
                == ClusterChipClass.local(environment: [:], debugBuild: false))
        #expect(try ClusterBenchChip.planningChipName(environment: environment, debugBuild: true) == "Apple M4 Max")
        #expect(throws: ClusterConfigurationError.self) {
            try ClusterBenchChip.planningChipName(environment: environment, debugBuild: false)
        }
        #expect(throws: ClusterConfigurationError.self) {
            try ClusterBenchChip.planningChipName(environment: ["DARKBLOOM_DEV_BENCH_CHIP": "a toaster"], debugBuild: true)
        }
        for debugBuild in [true, false] {
            #expect(try ClusterBenchChip.planningChipName(environment: [:], debugBuild: debugBuild) == nil)
        }
    }

    @Test func theBenchMemoryCapIsReadByADebugBuildAndRefusedByAReleaseBuild() throws {
        let environment = ["DARKBLOOM_DEV_BENCH_PLANNER_CAP_GIB": "64"]
        #expect(ClusterPlannerBenchCap.environmentName == "DARKBLOOM_DEV_BENCH_PLANNER_CAP_GIB")
        #expect(try ClusterPlannerBenchCap.capBytes(environment: environment, debugBuild: true) == 64 * 1_073_741_824)
        #expect(throws: ClusterConfigurationError.self) {
            try ClusterPlannerBenchCap.capBytes(environment: environment, debugBuild: false)
        }
        // Set and empty is still set: a release build refuses it, a debug build refuses the value.
        for debugBuild in [true, false] {
            #expect(throws: ClusterConfigurationError.self) {
                try ClusterPlannerBenchCap.capBytes(environment: ["DARKBLOOM_DEV_BENCH_PLANNER_CAP_GIB": ""], debugBuild: debugBuild)
            }
            #expect(try ClusterPlannerBenchCap.capBytes(environment: [:], debugBuild: debugBuild) == nil)
        }
    }

    @Test func theForcedModeIsReadByADebugBuildAndRefusedByAReleaseBuild() throws {
        let environment = ["DARKBLOOM_CLUSTER_FORCE_MODE": "pipeline_v1"]
        #expect(ClusterForcedModeSetting.environmentName == "DARKBLOOM_CLUSTER_FORCE_MODE")
        #expect(try ClusterForcedModeSetting.mode(environment: environment, debugBuild: true) == .pipeline)
        #expect(throws: ClusterConfigurationError.self) {
            try ClusterForcedModeSetting.mode(environment: environment, debugBuild: false)
        }
        #expect(ClusterForcedModeSetting.notice(environment: environment, debugBuild: true)?.contains("debug build only") == true)
        #expect(ClusterForcedModeSetting.notice(environment: environment, debugBuild: false)?.contains("is set but refused") == true)
        // Set and empty is unset, in both builds.
        for debugBuild in [true, false] {
            #expect(try ClusterForcedModeSetting.mode(environment: ["DARKBLOOM_CLUSTER_FORCE_MODE": ""], debugBuild: debugBuild) == nil)
            #expect(try ClusterForcedModeSetting.mode(environment: [:], debugBuild: debugBuild) == nil)
        }
    }

    @Test func theSoloGraceIsShortenedInADebugBuildOnly() {
        let environment = ["DARKBLOOM_DEBUG_CLUSTER_SOLO_GRACE_SECONDS": "45"]
        #expect(ClusterControlSoloGrace.environmentKey == "DARKBLOOM_DEBUG_CLUSTER_SOLO_GRACE_SECONDS")
        #expect(ClusterControlSoloGrace.seconds(environment: environment, debugBuild: true) == 45)
        #expect(ClusterControlSoloGrace.seconds(environment: environment, debugBuild: false) == 600)
        #expect(ClusterControlSoloGrace.seconds(environment: [:], debugBuild: true) == 600)
    }

    /// The reads that sit in `#if DEBUG` blocks and take their environment as
    /// a parameter. The Secure Enclave key file, the unpaired roster and the
    /// wizard's owner executable read the process environment, which a test
    /// that shares its process must not change; unset, they change nothing.
    @Test func theCompiledOutReadsWorkInThisDebugBuild() throws {
        #if DEBUG
        let identity = "P7373SVQX6:io.darkbloom-test.sandbox"
        let extra = try #require(AddonPeerPolicy.developmentIdentity(identity))
        #expect(AddonPeerPolicy.developmentIdentityVariable == "DARKBLOOM_ADDON_DEV_IDENTITY")
        #expect(AddonPeerPolicy.current(environment: ["DARKBLOOM_ADDON_DEV_IDENTITY": identity]).identities.contains(extra))
        #expect(!AddonPeerPolicy.current(environment: [:]).identities.contains(extra))

        #expect(SSDDebugCacheKeyFile.environmentKey == "DARKBLOOM_DEBUG_CACHE_KEY_FILE")
        #expect(SSDDebugCacheKeyFile.selectedPath(environment: ["DARKBLOOM_DEBUG_CACHE_KEY_FILE": "/keys/cache.key"]) == "/keys/cache.key")
        #expect(SSDDebugCacheKeyFile.selectedPath(environment: ["DARKBLOOM_DEBUG_CACHE_KEY_FILE": ""]) == nil)
        #expect(SSDDebugCacheKeyFile.selectedPath(environment: [:]) == nil)

        let pin = String(repeating: "ab", count: 32)
        #expect(CoordinatorDebugCertificatePin.environmentKey == "DARKBLOOM_DEBUG_COORDINATOR_CERT_SHA256")
        #expect(CoordinatorDebugCertificatePin.tlsOptions(environment: ["DARKBLOOM_DEBUG_COORDINATOR_CERT_SHA256": pin]) != nil)
        #expect(CoordinatorDebugCertificatePin.tlsOptions(environment: [:]) == nil)

        if ProcessInfo.processInfo.environment["DARKBLOOM_DEBUG_ROSTER_UNPAIRED"] == nil {
            #expect(!ClusterMemberPreparation.rosterWithoutPairingAllowed)
        }
        #endif
    }

    // MARK: - Every build but production's

    /// The environment axis alone: this test build is a debug build, and with
    /// production's environment it still ignores the switch and refuses plain
    /// `ws://`; a build for DevNet or staging does neither.
    @Test func productionIgnoresTheDeveloperSSHSwitchAndRefusesPlainCoordinatorURLs() {
        let environment = ["DARKBLOOM_CLUSTER_DEVELOPER_SSH": "1"]
        #expect(DistributedInstalledDeveloperSSH.environmentKey == "DARKBLOOM_CLUSTER_DEVELOPER_SSH")
        for build in BuildEnvironment.allCases {
            #expect(DistributedInstalledDeveloperSSH.enabled(environment, build: build) == (build != .prod), "\(build)")
            #expect(!DistributedInstalledDeveloperSSH.enabled(["DARKBLOOM_CLUSTER_DEVELOPER_SSH": "yes"], build: build))
            #expect(!DistributedInstalledDeveloperSSH.enabled([:], build: build))
            #expect(((try? DistributedInstalledDeveloperSSH.requireSSHRoute(build: build)) != nil) == (build != .prod), "\(build)")
            #expect((CoordinatorTransportPolicy.refusal(forServingURL: "ws://127.0.0.1:1", environment: build) != nil)
                    == (build == .prod), "\(build)")
            #expect(CoordinatorTransportPolicy.refusal(forServingURL: "wss://coordinator.example", environment: build) == nil)
        }
    }

    // MARK: - What this build is

    @Test func thisTestBuildIsADebugBuild() {
        let chip = ["DARKBLOOM_DEV_BENCH_CHIP": "Apple M4 Max"], cap = ["DARKBLOOM_DEV_BENCH_PLANNER_CAP_GIB": "64"]
        #if DEBUG
        #expect(!ServiceLaunchCheck.enforcedInThisBuild)
        #expect(!SignedReleaseIdentity.Dependencies.live.isReleaseBuild())
        #expect(KeychainAccessGroup.readsEnvironmentInThisBuild)
        LocationOverride.$readsEnvironmentForTesting.withValue(nil) { #expect(LocationOverride.readsEnvironmentInThisBuild) }
        #expect(ClusterBenchChip.chipName(environment: chip) == "Apple M4 Max")
        #expect((try? ClusterBenchChip.planningChipName(environment: chip)) == "Apple M4 Max")
        #expect((try? ClusterPlannerBenchCap.capBytes(environment: cap)) == 64 * 1_073_741_824)
        #expect((try? ClusterForcedModeSetting.mode(environment: ["DARKBLOOM_CLUSTER_FORCE_MODE": "pipeline_v1"])) == .pipeline)
        #else
        #expect(ServiceLaunchCheck.enforcedInThisBuild)
        #expect(SignedReleaseIdentity.Dependencies.live.isReleaseBuild())
        #expect(!KeychainAccessGroup.readsEnvironmentInThisBuild)
        LocationOverride.$readsEnvironmentForTesting.withValue(nil) { #expect(!LocationOverride.readsEnvironmentInThisBuild) }
        #expect(ClusterBenchChip.chipName(environment: chip) == nil)
        #expect((try? ClusterBenchChip.planningChipName(environment: chip)) == nil)
        #expect((try? ClusterPlannerBenchCap.capBytes(environment: cap)) == nil)
        #endif
    }

    // MARK: - Every build

    /// Test locations and diagnosis controls that no build gates: a release
    /// build honours each of them today.
    @Test func everyBuildReadsTheseLocationsAndControls() throws {
        #expect(ClusterSupervisionFiles.statePathEnvironmentKey == "DARKBLOOM_CLUSTER_SUPERVISOR_STATE")
        #expect(ClusterSupervisionFiles.statePath(environment: ["DARKBLOOM_CLUSTER_SUPERVISOR_STATE": "/elsewhere/state.json"],
                                                  home: Self.home).path == "/elsewhere/state.json")
        #expect(ClusterSupervisionFiles.statePath(environment: ["DARKBLOOM_CLUSTER_SUPERVISOR_STATE": ""], home: Self.home)
                == ClusterSupervisionFiles.statePath(environment: [:], home: Self.home))

        #expect(AddonHoldPaths.socketOverrideVariable == "DARKBLOOM_ADDON_SOCKET")
        let moved = AddonHoldPaths.production(environment: ["DARKBLOOM_ADDON_SOCKET": "/elsewhere/a.sock"], home: Self.home)
        #expect(moved.socket.path == "/elsewhere/a.sock" && moved.machineLock.path == "/elsewhere/ownership.lock")
        #expect(AddonHoldPaths.production(environment: ["DARKBLOOM_ADDON_SOCKET": ""], home: Self.home)
                == AddonHoldPaths.production(environment: [:], home: Self.home))

        #expect(DistributedInstalledPrefixSSD.directoryName == "DARKBLOOM_CLUSTER_PREFIX_SSD_DIR")
        let settings = ClusterPrefixCacheSettings(root: URL(fileURLWithPath: "/product/root"))
        func rankDirectory(_ owner: [String: String]) -> String? {
            DistributedInstalledPrefixSSD.environment(home: Self.home, deviceDirectory: Self.home, ownerEnvironment: owner,
                                                      prefixCacheOff: false, settings: settings)["DARKBLOOM_CLUSTER_PREFIX_SSD_DIR"]
        }
        #expect(rankDirectory(["DARKBLOOM_CLUSTER_PREFIX_SSD_DIR": "/elsewhere/ssd"]) == "/elsewhere/ssd")
        #expect(rankDirectory(["DARKBLOOM_CLUSTER_PREFIX_SSD_DIR": "relative/ssd"]) == "/product/root")
        #expect(rankDirectory([:]) == "/product/root")
    }

    @Test func everyBuildReadsTheSSDTierTestSwitches() throws {
        let allow = "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL", root = "DARKBLOOM_PREFIX_CACHE_TEST_ROOT"
        let persistent = "DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY"
        #expect(SSDPrefixCacheFactory.testRootEnvironmentKey == root)
        #expect(SSDPrefixCacheFactory.ephemeralAllowed(environment: [allow: "1"]))
        #expect(SSDPrefixCacheFactory.ephemeralAllowed(environment: [allow: " On "]))
        #expect(!SSDPrefixCacheFactory.ephemeralAllowed(environment: [allow: "0"]))
        #expect(!SSDPrefixCacheFactory.ephemeralAllowed(environment: [:]))
        #expect(SSDPrefixCacheFactory.isolatedTestRoot(environment: [allow: "1", root: "/elsewhere/kv"])?.path == "/elsewhere/kv")
        #expect(SSDPrefixCacheFactory.isolatedTestRoot(environment: [root: "/elsewhere/kv"]) == nil)
        #expect(SSDPrefixCacheFactory.isolatedTestRoot(environment: [allow: "1", root: " "]) == nil)
        #expect(SSDPrefixCacheFactory.forceEphemeralKey(environment: [allow: "1", root: "/elsewhere/kv"]))
        #expect(!SSDPrefixCacheFactory.forceEphemeralKey(environment: [allow: "1", root: "/elsewhere/kv", persistent: "1"]))
        #expect(!SSDPrefixCacheFactory.forceEphemeralKey(environment: [persistent: "0"]))
        let namespace = try SSDPersistentTestKeyNamespace(identifier: UUID(), accessGroup: "TEAMID0000.io.example")
        #expect(throws: SSDPersistentTestKeyNamespace.Failure.persistentModeRequired) {
            try namespace.validate(environment: [allow: "1", root: "/elsewhere/kv"])
        }
        #expect(throws: SSDPersistentTestKeyNamespace.Failure.isolatedRootRequired) {
            try namespace.validate(environment: [persistent: "1"])
        }
        #expect(DeadlineQualificationCacheIsolation.isPlumbingKey(allow))
        #expect(DeadlineQualificationCacheIsolation.isPlumbingKey(root))
        #expect(!DeadlineQualificationCacheIsolation.isPlumbingKey(persistent))
    }

    // MARK: - Lists that name the variables

    @Test func theListsThatNameTheVariablesKeepTheirKeys() {
        for key in ["DARKBLOOM_STATE_FILE", "DARKBLOOM_WATCHDOG_STATE", "DARKBLOOM_KV_BACKEND_GUARD"] {
            #expect(WatchdogAgent.passthroughEnvKeys.contains(key), "\(key)")
        }
        #expect(LaunchAgent.passthroughEnvKeys.contains("DARKBLOOM_KV_BACKEND_GUARD"))
        #expect(LaunchAgent.passthroughEnvKeys.contains("DARKBLOOM_R2_CDN_URL"))
        // The deadline qualification's operational keys: each alone leaves a scrubbed environment qualifying.
        for key in ["DARKBLOOM_AUTH_TOKEN_PATH", "DARKBLOOM_KEYCHAIN_ACCESS_GROUP", "DARKBLOOM_LOCAL_DIR",
                    "DARKBLOOM_LOADED_MODELS_FILE", "DARKBLOOM_PID_FILE", "DARKBLOOM_STATE_FILE",
                    "DARKBLOOM_VERIFIED_WEIGHTS_FILE", "DARKBLOOM_WATCHDOG_STATE"] {
            #expect(DeadlineRuntimeEnvironment.permitsQualification([key: "/elsewhere"], injected: []), "\(key)")
        }
        #expect(!DeadlineRuntimeEnvironment.permitsQualification(["DARKBLOOM_KV_BACKEND_GUARD": "/elsewhere"], injected: []))
        #expect(!DeadlineRuntimeEnvironment.permitsQualification(["DARKBLOOM_R2_CDN_URL": "https://mirror.example"], injected: []))
    }
}
