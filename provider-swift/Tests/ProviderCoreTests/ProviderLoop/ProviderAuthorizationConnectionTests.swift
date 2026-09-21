import Foundation
import Testing
@testable import ProviderCore

@Suite struct ProviderAuthorizationConnectionTests {
    @Test func reconnectAndMissingServerCapabilityClearRemovalReadiness() async throws {
        let config = ProviderLoopConfig(
            coordinatorURL: "wss://api.darkbloom.dev/ws/provider",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                memoryGb: 128, memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546),
            models: [], config: ProviderConfig(
                provider: ProviderSettings(name: "authorization-test"),
                backend: BackendSettings(), coordinator: CoordinatorSettings()))
        let loop = try ProviderLoop(config: config, purgeLegacyFiles: false, attestationSigner: nil)
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stateURL) }
        await loop.installAuthorizationStateFileForTesting(stateURL)
        let authorization = ProviderAuthorizationStatus(
            appAttestAvailable: true, path: "app_attest",
            expiresAt: Date().timeIntervalSince1970 + 30, mdmRemovalReady: true,
            sessionID: "session-one", machineID: "machine")
        await loop.handleTrustStatus(trustLevel: "self_signed", status: "online", reason: "qualified",
                                     authorization: authorization)
        #expect(DaemonStateFile.read(from: stateURL)?.trust?.authorization == authorization)

        // Both connected and disconnected events invoke this synchronous
        // invalidation before serving-loop work can publish another snapshot.
        await loop.clearConnectionAuthorization()
        #expect(DaemonStateFile.read(from: stateURL)?.trust == nil)

        // An older coordinator's subsequent status must never retain the
        // previous coordinator's optional authorization object.
        await loop.handleTrustStatus(trustLevel: "hardware", status: "online", reason: "MDM verification passed")
        #expect(DaemonStateFile.read(from: stateURL)?.trust?.authorization == nil)
    }
}

private extension ProviderLoop {
    func installAuthorizationStateFileForTesting(_ url: URL) {
        daemonStateFileOverride = url
    }
}
