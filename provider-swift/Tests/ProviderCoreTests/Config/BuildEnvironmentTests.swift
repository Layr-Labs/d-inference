import Foundation
import Testing

@testable import ProviderCore

@Suite("Build environment defaults")
struct BuildEnvironmentTests {
    private let devCoordinator = "wss://api.dev.darkbloom.dev/ws/provider"

    @Test func devBranchBuildsDefaultToDevNet() {
        let hardware = HardwareInfo(
            machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
            memoryGb: 64, memoryAvailableGb: 64,
            cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546)
        #expect(BuildEnvironment.current == .dev)
        #expect(CoordinatorSettings().url == devCoordinator)
        #expect(ConfigManager.parse("").coordinator.url == devCoordinator)
        #expect(ConfigManager.parse("[coordinator]\nheartbeat_interval_secs = 5\n").coordinator.url
            == devCoordinator)
        #expect(ProviderConfig.defaultForHardware(hardware).coordinator.url == devCoordinator)
        #expect(ModelDownloader.defaultR2CDNURL == "https://models.darkbloom.ai")
    }

    @Test func devValuesPointAtDevNet() {
        #expect(BuildEnvironment.dev.coordinatorWebSocketURL == "wss://api.dev.darkbloom.dev/ws/provider")
        #expect(BuildEnvironment.dev.coordinatorHTTPURL == "https://api.dev.darkbloom.dev")
        #expect(BuildEnvironment.dev.modelCDNURL == "https://models.darkbloom.ai")
    }

    @Test func productionIdentityIsUnchanged() {
        let prod = BuildEnvironment.prod
        #expect(prod.cliName == "darkbloom")
        #expect(prod.enclaveName == "darkbloom-enclave")
        #expect(prod.appBundleName == "Darkbloom.app")
        #expect(prod.appDisplayName == "Darkbloom")
        #expect(prod.installDirectoryName == ".darkbloom")
        #expect(prod.configDirectoryName == ".config/darkbloom")
        #expect(prod.legacyConfigDirectoryNames == [".config/eigeninference"])
        #expect(prod.launchAgentLabel == "io.darkbloom.provider")
        #expect(prod.watchdogAgentLabel == "io.darkbloom.watchdog")
        #expect(prod.logSubsystem == "com.darkbloom.provider")
        #expect(prod.serviceLogSubsystem == "dev.darkbloom.provider")
        #expect(prod.defaultLocalPort == 8000)
        #expect(prod.encryptedCacheNamespace == "darkbloom")
        #expect(prod.modelRevisionRef == "main")
        #expect(prod.keychainServicePrefix == "io.darkbloom")
        #expect(BackendSettings().port == 8100)
        #expect(ConfigManager.parse("").backend.port == 8100)
        #expect(prod.installDirectory(home: URL(fileURLWithPath: "/Users/op")).path == "/Users/op/.darkbloom")
    }

    /// Keys, agent labels and the config path follow the build's environment: production's on master, DevNet's on
    /// the dev branch, where a plain build is a dev build.
    @Test func installDefaultsFollowTheBuildEnvironment() {
        let current = BuildEnvironment.current
        #expect(KeychainWrappedKEKStorage.defaultService == "\(current.keychainServicePrefix).kv.kek.v1")
        #expect(PersistentEnclaveKey.defaultLabel == "\(current.keychainServicePrefix).provider.attestation-signing.v2")
        #expect(LaunchAgent.label == current.launchAgentLabel)
        #expect(WatchdogAgent.label == current.watchdogAgentLabel)
        let home = URL(fileURLWithPath: "/Users/op")
        #expect(ConfigManager.defaultConfigPath(home: home).path == "/Users/op/\(current.configDirectoryName)/provider.toml")
    }

    @Test func devIdentityIsSuffixed() {
        let dev = BuildEnvironment.dev
        #expect(dev.cliName == "darkbloom-dev")
        #expect(dev.enclaveName == "darkbloom-enclave-dev")
        #expect(dev.appBundleName == "Darkbloom Dev.app")
        #expect(dev.appDisplayName == "Darkbloom Dev")
        #expect(dev.installDirectoryName == ".darkbloom-dev")
        #expect(dev.configDirectoryName == ".config/darkbloom-dev")
        #expect(dev.legacyConfigDirectoryNames == [])
        #expect(dev.launchAgentLabel == "io.darkbloom.provider.dev")
        #expect(dev.watchdogAgentLabel == "io.darkbloom.watchdog.dev")
        #expect(dev.logSubsystem == "com.darkbloom.provider.dev")
        #expect(dev.serviceLogSubsystem == "dev.darkbloom.provider.dev")
        #expect(dev.defaultLocalPort == 8001)
        #expect(dev.encryptedCacheNamespace == "darkbloom-dev")
        #expect(dev.modelRevisionRef == "darkbloom-dev")
        #expect(dev.keychainServicePrefix == "io.darkbloom.dev")
        #expect(dev.installDirectory(home: URL(fileURLWithPath: "/Users/op")).path == "/Users/op/.darkbloom-dev")
    }

    @Test func stagingValuesPointAtStagingDevNet() {
        #expect(BuildEnvironment.staging.coordinatorWebSocketURL == "wss://api.staging.darkbloom.dev/ws/provider")
        #expect(BuildEnvironment.staging.coordinatorHTTPURL == "https://api.staging.darkbloom.dev")
        #expect(BuildEnvironment.staging.modelCDNURL == "https://models.darkbloom.ai")
    }

    @Test func stagingIdentityIsSuffixed() {
        let staging = BuildEnvironment.staging
        #expect(staging.cliName == "darkbloom-staging")
        #expect(staging.enclaveName == "darkbloom-enclave-staging")
        #expect(staging.appBundleName == "Darkbloom Staging.app")
        #expect(staging.appDisplayName == "Darkbloom Staging")
        #expect(staging.installDirectoryName == ".darkbloom-staging")
        #expect(staging.configDirectoryName == ".config/darkbloom-staging")
        #expect(staging.legacyConfigDirectoryNames == [])
        #expect(staging.launchAgentLabel == "io.darkbloom.provider.staging")
        #expect(staging.watchdogAgentLabel == "io.darkbloom.watchdog.staging")
        #expect(staging.logSubsystem == "com.darkbloom.provider.staging")
        #expect(staging.serviceLogSubsystem == "dev.darkbloom.provider.staging")
        #expect(staging.defaultLocalPort == 8002)
        #expect(staging.encryptedCacheNamespace == "darkbloom-staging")
        #expect(staging.modelRevisionRef == "darkbloom-staging")
        #expect(staging.keychainServicePrefix == "io.darkbloom.staging")
        #expect(staging.installDirectory(home: URL(fileURLWithPath: "/Users/op")).path == "/Users/op/.darkbloom-staging")
    }

    @Test func environmentsShareNoPathPortOrLabel() {
        func identity(_ environment: BuildEnvironment) -> [String] {
            [environment.cliName, environment.enclaveName, environment.appBundleName,
             environment.installDirectoryName, environment.configDirectoryName,
             environment.launchAgentLabel, environment.watchdogAgentLabel,
             environment.logSubsystem, environment.serviceLogSubsystem,
             environment.keychainServicePrefix, environment.encryptedCacheNamespace,
             environment.modelRevisionRef,
             String(environment.defaultLocalPort)]
        }
        let allIdentities = BuildEnvironment.allCases.map(identity)
        for i in allIdentities.indices {
            for j in allIdentities.indices where j > i {
                for (left, right) in zip(allIdentities[i], allIdentities[j]) {
                    #expect(left != right)
                }
            }
        }
        let paths = BuildEnvironment.allCases.flatMap {
            [$0.installDirectoryName, $0.configDirectoryName] + $0.legacyConfigDirectoryNames
        }
        #expect(Set(paths).count == paths.count)
    }

    @Test func webSocketAndHTTPFormsAgree() {
        for environment in BuildEnvironment.allCases {
            #expect(coordinatorHTTPBase(environment.coordinatorWebSocketURL) == environment.coordinatorHTTPURL)
        }
    }

    @Test func cdnResolutionOrder() {
        #expect(ModelDownloader.resolveCDNURL(
            explicit: "https://a.test/", environment: ["DARKBLOOM_R2_CDN_URL": "https://b.test"]) == "https://a.test")
        #expect(ModelDownloader.resolveCDNURL(environment: ["DARKBLOOM_R2_CDN_URL": "https://b.test/"]) == "https://b.test")
        #expect(ModelDownloader.resolveCDNURL(environment: ["DARKBLOOM_R2_CDN_URL": ""]) == ModelDownloader.defaultR2CDNURL)
        #expect(ModelDownloader.resolveCDNURL(environment: [:]) == ModelDownloader.defaultR2CDNURL)
    }
}
