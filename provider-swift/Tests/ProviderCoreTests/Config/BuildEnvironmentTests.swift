import Foundation
import Testing

@testable import ProviderCore

@Suite("Build environment defaults")
struct BuildEnvironmentTests {
    private let prodCoordinator = "wss://api.darkbloom.dev/ws/provider"

    @Test func testBuildsKeepProductionDefaults() {
        let hardware = HardwareInfo(
            machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
            memoryGb: 64, memoryAvailableGb: 64,
            cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546)
        #expect(BuildEnvironment.current == .prod)
        #expect(CoordinatorSettings().url == prodCoordinator)
        #expect(ConfigManager.parse("").coordinator.url == prodCoordinator)
        #expect(ConfigManager.parse("[coordinator]\nheartbeat_interval_secs = 5\n").coordinator.url
            == prodCoordinator)
        #expect(ProviderConfig.defaultForHardware(hardware).coordinator.url == prodCoordinator)
        #expect(ModelDownloader.defaultR2CDNURL == "https://models.darkbloom.ai")
    }

    @Test func devValuesPointAtDevNet() {
        #expect(BuildEnvironment.dev.coordinatorWebSocketURL == "wss://api.dev.darkbloom.dev/ws/provider")
        #expect(BuildEnvironment.dev.coordinatorHTTPURL == "https://api.dev.darkbloom.dev")
        #expect(BuildEnvironment.dev.modelCDNURL == "https://models.darkbloom.ai")
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
