import Foundation
import ProviderAppAttest
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
    /// What the current coordinator sends at registration, before it records
    /// the first verified challenge that legacy verification needs.
    private static let registrationRefusal = ProviderAuthorizationStatus(
        appAttestAvailable: true, path: "none", reason: "app_attest_qualification_required",
        sessionID: "session", machineID: "")

    /// A loop advertising one model, writing its state file to `stateURL`,
    /// with no re-registration jitter.
    private static func makeLoop(stateURL: URL, logs: PublicLogLines? = nil) async throws -> ProviderLoop {
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
        let sink: ProviderLogger.Sink? = logs.map { lines -> ProviderLogger.Sink in
            { level, visibility, message in lines.append(level, visibility, message) }
        }
        let loop = try ProviderLoop(config: config, attestationSigner: nil, logSinkForTesting: sink)
        await loop.installAuthorizationStateFileForTesting(stateURL)
        await loop.setUnauthorizedReconnectJitterForTesting(0)
        return loop
    }

    /// The coordinator's status refusing the connection, received at `receivedAt`.
    private static func refuse(_ loop: ProviderLoop, at receivedAt: Double,
                               _ refusal: ProviderAuthorizationStatus = keychainRefusal) async {
        await loop.handleTrustStatus(
            trustLevel: "self_signed", status: "online", reason: "Provider authorization updated",
            authorization: refusal, receivedAt: receivedAt)
    }

    /// A connected provider the coordinator does not authorize looks healthy
    /// but gets no work. While the coordinator repeats its refusal (every 5 s,
    /// as it renews a status it maintains), the loop records the connection
    /// for `status`, starts the unauthorized clock, re-registers once the
    /// threshold passes, and clears the clock when the coordinator authorizes
    /// the connection.
    @Test func unauthorizedConnectionIsReportedAndReregisteredAfterTheThreshold() async throws {
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let loop = try await Self.makeLoop(stateURL: stateURL)

        let t0 = Date().timeIntervalSince1970
        await loop.noteCoordinatorConnection(connected: true, now: t0 - 3_600)
        await Self.refuse(loop, at: t0)
        let written = try #require(DaemonStateFile.read(from: stateURL))
        #expect(written.coordinatorConnection == .init(connected: true, since: t0 - 3_600, connections: 1))
        guard case .blocked(let advice)? = ServingReadiness.verdict(written, now: t0) else {
            Issue.record("unauthorized connection not reported as blocked")
            return
        }
        #expect(advice.fix?.contains("unlock the login keychain") == true)

        await loop.superviseServingAuthorization(now: t0)
        #expect(await loop.unauthorizedSince == t0)
        let due = t0 + UnauthorizedConnectionRecovery.unauthorizedThreshold
        for tick in stride(from: t0 + 5, to: due, by: 5) {
            await Self.refuse(loop, at: tick)
            await loop.superviseServingAuthorization(now: tick)
        }
        #expect(await loop.lastUnauthorizedReconnectAt == nil)
        #expect(await loop.unauthorizedSince == t0)
        await Self.refuse(loop, at: due)
        await loop.superviseServingAuthorization(now: due)
        #expect(await loop.lastUnauthorizedReconnectAt == due)
        #expect(await loop.unauthorizedReconnectAttempts == 1)
        #expect(await loop.unauthorizedSince == nil)

        await loop.handleTrustStatus(
            trustLevel: "self_signed", status: "online", reason: "Provider authorization updated",
            authorization: ProviderAuthorizationStatus(
                appAttestAvailable: true, path: "app_attest", expiresAt: due + 600,
                reason: "app_attest_verified", sessionID: "session", machineID: "machine"),
            receivedAt: due + 5)
        await loop.superviseServingAuthorization(now: due + 5)
        #expect(await loop.unauthorizedSince == nil)
        #expect(await loop.unauthorizedReconnectAttempts == 0)

        await loop.noteCoordinatorConnection(connected: false, now: due + 10)
        let disconnected = try #require(await loop.coordinatorConnection)
        #expect(!disconnected.connected && disconnected.connections == 1)
    }

    /// A legacy (MDM-cohort) Mac on the current coordinator: its only status
    /// is the registration refusal, and none follows when legacy verification
    /// authorizes the connection. An idle provider must never re-register it,
    /// log that the coordinator is not routing it, or tell `status` it is
    /// excluded or needs macOS 27.
    @Test func aRegistrationRefusalAloneNeverReregisters() async throws {
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let logs = PublicLogLines()
        let loop = try await Self.makeLoop(stateURL: stateURL, logs: logs)

        let t0 = Date().timeIntervalSince1970
        await loop.noteCoordinatorConnection(connected: true, now: t0)
        await Self.refuse(loop, at: t0 + 1, Self.registrationRefusal)
        // Capacity ticks over a day.
        let offsets: [Double] = [5, 30, 61, 89, 90, 91, 120] + stride(from: 300, through: 86_400, by: 300).map(Double.init)
        for offset in offsets {
            await loop.superviseServingAuthorization(now: t0 + offset)
            #expect(await loop.unauthorizedSince == nil, "t0+\(offset)")
        }
        #expect(await loop.lastUnauthorizedReconnectAt == nil)
        #expect(await loop.unauthorizedReconnectAttempts == 0)
        #expect(!logs.contains(.coordinatorNotRoutingConnection))
        #expect(!logs.contains(.unauthorizedConnectionReregistering))

        var written = try #require(DaemonStateFile.read(from: stateURL))
        written.appAttest = AppAttestLocalStatus(observedAt: t0, launchSession: .unknown, availabilityReason: .osBelow27)
        guard case .pending? = ServingReadiness.verdict(written, now: t0 + 20, macOSMajorVersion: 26) else {
            Issue.record("a refusal right after connecting is not pending")
            return
        }
        guard case .unconfirmed(let detail)? = ServingReadiness.verdict(written, now: t0 + 600, macOSMajorVersion: 26) else {
            Issue.record("a registration refusal still decides the verdict ten minutes later")
            return
        }
        #expect(detail.contains("the last one, 9m ago") && !detail.contains("macOS 27"))
    }

    /// An App Attest lease names its own expiry. Once it passes without a
    /// renewal the connection is refused, however old that status is.
    @Test func anExpiredLeaseIsJudgedWithoutAFreshStatus() async throws {
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let loop = try await Self.makeLoop(stateURL: stateURL)

        let t0 = Date().timeIntervalSince1970
        await loop.noteCoordinatorConnection(connected: true, now: t0 - 3_600)
        await loop.handleTrustStatus(
            trustLevel: "self_signed", status: "online", reason: "Provider authorization updated",
            authorization: ProviderAuthorizationStatus(
                appAttestAvailable: true, path: "app_attest", expiresAt: t0 + 60,
                reason: "app_attest_verified", sessionID: "session", machineID: "machine"),
            receivedAt: t0)
        await loop.superviseServingAuthorization(now: t0 + 30)
        #expect(await loop.unauthorizedSince == nil)
        let lapsed = t0 + 2 * ServingReadiness.refusalMaxAge
        await loop.superviseServingAuthorization(now: lapsed)
        #expect(await loop.unauthorizedSince == lapsed)
        let due = lapsed + UnauthorizedConnectionRecovery.unauthorizedThreshold
        await loop.superviseServingAuthorization(now: due)
        #expect(await loop.lastUnauthorizedReconnectAt == due)
    }

    /// A request the coordinator routes after its latest status shows that it
    /// routes the connection: the clock stops and the backoff resets. A
    /// refusal sent after that request counts again.
    @Test func aRoutedRequestOutweighsAnEarlierRefusal() async throws {
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let logs = PublicLogLines()
        let loop = try await Self.makeLoop(stateURL: stateURL, logs: logs)

        let t0 = Date().timeIntervalSince1970
        await loop.noteCoordinatorConnection(connected: true, now: t0 - 3_600)
        await Self.refuse(loop, at: t0)
        await loop.superviseServingAuthorization(now: t0)
        #expect(await loop.unauthorizedSince == t0)

        await loop.noteCoordinatorRequest(now: t0 + 2)
        await loop.superviseServingAuthorization(now: t0 + 3)
        #expect(await loop.unauthorizedSince == nil)
        #expect(logs.contains(.coordinatorRoutingConnection))
        #expect(ServingReadiness.verdict(await loop.currentDaemonState(), now: t0 + 3)
            == .authorized("received a coordinator request 1s ago"))

        await Self.refuse(loop, at: t0 + 5)
        await loop.superviseServingAuthorization(now: t0 + 5)
        #expect(await loop.unauthorizedSince == t0 + 5)

        // A disconnected provider records no request: the next connection starts clean.
        await loop.noteCoordinatorConnection(connected: false, now: t0 + 10)
        await loop.noteCoordinatorRequest(now: t0 + 11)
        #expect(await loop.coordinatorConnection?.lastRequestAt == nil)
    }

    /// When the coordinator stops repeating a refusal, the provider stops
    /// counting it, and the log says routing is unconfirmed, not resumed.
    @Test func aRefusalTheCoordinatorStopsRepeatingIsLoggedAsUnconfirmed() async throws {
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let logs = PublicLogLines()
        let loop = try await Self.makeLoop(stateURL: stateURL, logs: logs)

        let t0 = Date().timeIntervalSince1970
        await loop.noteCoordinatorConnection(connected: true, now: t0 - 3_600)
        await Self.refuse(loop, at: t0)
        await loop.superviseServingAuthorization(now: t0)
        #expect(await loop.unauthorizedSince == t0)
        #expect(logs.contains(.coordinatorNotRoutingConnection))

        await loop.superviseServingAuthorization(now: t0 + ServingReadiness.refusalMaxAge + 1)
        #expect(await loop.unauthorizedSince == nil)
        #expect(logs.contains(.coordinatorRefusalUnconfirmed))
        #expect(!logs.contains(.coordinatorRoutingConnection))
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
        await Self.refuse(loop, at: t0)
        await loop.superviseServingAuthorization(now: t0)
        #expect(await loop.unauthorizedSince == t0)

        await loop.setAutopilotCommandForTesting(
            ModelAutopilotCommand(commandId: "accepted", loadModelId: "acme/model", expiresAtMs: 1))
        let due = t0 + UnauthorizedConnectionRecovery.unauthorizedThreshold
        await Self.refuse(loop, at: due)
        await loop.superviseServingAuthorization(now: due)
        #expect(await loop.lastUnauthorizedReconnectAt == nil)
        #expect(await loop.unauthorizedReconnectAttempts == 0)

        await loop.setAutopilotCommandForTesting(nil)
        await Self.refuse(loop, at: due + 5)
        await loop.superviseServingAuthorization(now: due + 5)
        #expect(await loop.lastUnauthorizedReconnectAt == due + 5)
        #expect(await loop.unauthorizedReconnectAttempts == 1)
    }
}

/// The public log lines a loop wrote.
private final class PublicLogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ level: ProviderLogLevel, _ visibility: ProviderLogVisibility, _ message: String) {
        guard visibility == .public else { return }
        lock.withLock { lines.append(message) }
    }

    func contains(_ message: ProviderOperationalMessage) -> Bool {
        lock.withLock { lines.contains(message.text) }
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
