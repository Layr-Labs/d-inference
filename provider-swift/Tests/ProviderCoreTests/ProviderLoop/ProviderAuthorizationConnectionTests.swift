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
        let loop = try ProviderLoop(config: config, attestationSigner: nil)
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

@Suite struct UnauthorizedConnectionSupervisionTests {
    private static let keychainRefusal = ProviderAuthorizationStatus(
        appAttestAvailable: true, path: "none", reason: "app_attest_keychain_error",
        sessionID: "session", machineID: "")

    /// A loop advertising one model, writing its state file to `stateURL`,
    /// with no re-registration jitter.
    private static func makeLoop(stateURL: URL) async throws -> ProviderLoop {
        let config = ProviderLoopConfig(
            coordinatorURL: "wss://api.darkbloom.dev/ws/provider",
            hardware: HardwareInfo(
                machineModel: "Mac16,5", chipName: "Apple M4 Max", chipFamily: .m4, chipTier: .max,
                memoryGb: 128, memoryAvailableGb: 124,
                cpuCores: CpuCores(total: 16, performance: 12, efficiency: 4),
                gpuCores: 40, memoryBandwidthGbs: 546),
            models: [ModelInfo(id: "acme/model", modelType: "gpt_oss", sizeBytes: 1, estimatedMemoryGb: 1)],
            config: ProviderConfig(
                provider: ProviderSettings(name: "supervision-test"),
                backend: BackendSettings(), coordinator: CoordinatorSettings()))
        let loop = try ProviderLoop(config: config, attestationSigner: nil)
        await loop.installAuthorizationStateFileForTesting(stateURL)
        await loop.setUnauthorizedReconnectJitterForTesting(0)
        return loop
    }

    /// A connected provider the coordinator does not authorize looks healthy
    /// but gets no work. The loop records the connection for `status`, starts
    /// the unauthorized clock, re-registers once the threshold passes, and
    /// clears the clock when the coordinator authorizes the connection.
    @Test func unauthorizedConnectionIsReportedAndReregisteredAfterTheThreshold() async throws {
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let loop = try await Self.makeLoop(stateURL: stateURL)

        let t0 = Date().timeIntervalSince1970
        await loop.noteCoordinatorConnection(connected: true, now: t0 - 3_600)
        await loop.handleTrustStatus(
            trustLevel: "self_signed", status: "online", reason: "Provider authorization updated",
            authorization: Self.keychainRefusal)
        let written = try #require(DaemonStateFile.read(from: stateURL))
        #expect(written.coordinatorConnection == .init(connected: true, since: t0 - 3_600, connections: 1))
        guard case .blocked(let advice)? = ServingReadiness.verdict(written, now: t0) else {
            Issue.record("unauthorized connection not reported as blocked")
            return
        }
        #expect(advice.fix?.contains("unlock the login keychain") == true)

        await loop.superviseServingAuthorization(now: t0)
        #expect(await loop.unauthorizedSince == t0)
        await loop.superviseServingAuthorization(now: t0 + UnauthorizedConnectionRecovery.unauthorizedThreshold - 1)
        #expect(await loop.lastUnauthorizedReconnectAt == nil)
        let due = t0 + UnauthorizedConnectionRecovery.unauthorizedThreshold
        await loop.superviseServingAuthorization(now: due)
        #expect(await loop.lastUnauthorizedReconnectAt == due)
        #expect(await loop.unauthorizedReconnectAttempts == 1)
        #expect(await loop.unauthorizedSince == nil)

        await loop.handleTrustStatus(
            trustLevel: "self_signed", status: "online", reason: "Provider authorization updated",
            authorization: ProviderAuthorizationStatus(
                appAttestAvailable: true, path: "app_attest", expiresAt: due + 600,
                reason: "app_attest_verified", sessionID: "session", machineID: "machine"))
        await loop.superviseServingAuthorization(now: due + 5)
        #expect(await loop.unauthorizedSince == nil)
        #expect(await loop.unauthorizedReconnectAttempts == 0)

        await loop.noteCoordinatorConnection(connected: false, now: due + 10)
        let disconnected = try #require(await loop.coordinatorConnection)
        #expect(!disconnected.connected && disconnected.connections == 1)
    }

    /// The client reports a disconnect for every failed reconnect attempt,
    /// up to every 30 s. `status` must still say how long the connection has
    /// been down, not how long ago the last attempt failed.
    @Test func aFailingReconnectKeepsTheTimeTheConnectionWentDown() async throws {
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let loop = try await Self.makeLoop(stateURL: stateURL)

        let t0 = 1_000_000.0
        // The client starts disconnected; its first attempt fails.
        await loop.noteCoordinatorConnection(connected: false, now: t0)
        await loop.noteCoordinatorConnection(connected: false, now: t0 + 1)
        #expect(await loop.coordinatorConnection == .init(connected: false, since: t0, connections: 0))

        await loop.noteCoordinatorConnection(connected: true, now: t0 + 30)
        await loop.noteCoordinatorConnection(connected: false, now: t0 + 600)
        for attempt in 1...120 {
            await loop.noteCoordinatorConnection(connected: false, now: t0 + 600 + Double(attempt) * 30)
        }
        let down = try #require(await loop.coordinatorConnection)
        #expect(down == .init(connected: false, since: t0 + 600, connections: 1))
        var state = DaemonState(pid: 1, version: "test", writtenAt: t0 + 4_200, startedAt: t0)
        state.coordinatorConnection = down
        guard case .blocked(let advice)? = ServingReadiness.verdict(state, now: t0 + 4_200) else {
            Issue.record("a disconnected provider was not reported as blocked")
            return
        }
        #expect(advice.message.hasPrefix("not connected to the coordinator (disconnected 1h ago)"))

        await loop.noteCoordinatorConnection(connected: true, now: t0 + 4_300)
        #expect(await loop.coordinatorConnection == .init(connected: true, since: t0 + 4_300, connections: 2))
    }

    /// Re-registering drains admission, which fails an accepted Autopilot
    /// command partway (after its victims unloaded, before its target loads).
    @Test func reregistrationWaitsForAnAcceptedAutopilotCommand() async throws {
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let loop = try await Self.makeLoop(stateURL: stateURL)

        let t0 = Date().timeIntervalSince1970
        await loop.noteCoordinatorConnection(connected: true, now: t0 - 3_600)
        await loop.handleTrustStatus(
            trustLevel: "self_signed", status: "online", reason: "Provider authorization updated",
            authorization: Self.keychainRefusal)
        await loop.superviseServingAuthorization(now: t0)
        #expect(await loop.unauthorizedSince == t0)

        await loop.setAutopilotCommandForTesting(
            ModelAutopilotCommand(commandId: "accepted", loadModelId: "acme/model", expiresAtMs: 1))
        let due = t0 + UnauthorizedConnectionRecovery.unauthorizedThreshold
        await loop.superviseServingAuthorization(now: due)
        #expect(await loop.lastUnauthorizedReconnectAt == nil)
        #expect(await loop.unauthorizedReconnectAttempts == 0)

        await loop.setAutopilotCommandForTesting(nil)
        await loop.superviseServingAuthorization(now: due + 5)
        #expect(await loop.lastUnauthorizedReconnectAt == due + 5)
        #expect(await loop.unauthorizedReconnectAttempts == 1)
    }
}

private extension ProviderLoop {
    func installAuthorizationStateFileForTesting(_ url: URL) {
        daemonStateFileOverride = url
    }

    func setUnauthorizedReconnectJitterForTesting(_ jitter: Double) {
        unauthorizedReconnectJitter = jitter
    }

    func setAutopilotCommandForTesting(_ command: ModelAutopilotCommand?) {
        autopilotCommand = command
    }
}
