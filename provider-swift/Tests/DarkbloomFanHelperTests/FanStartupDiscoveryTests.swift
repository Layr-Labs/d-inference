import DarkbloomFanCore
import DarkbloomFanProtocol
import DarkbloomFanService
import Foundation
import Testing

@testable import DarkbloomFanHelper

@Suite("Fan helper startup discovery")
struct FanStartupDiscoveryTests {
    @Test("startup discovery reflects available plausible sensors", arguments: [-4.0, 35.0])
    func startupDiscoveryReflectsSensorAvailability(temperature: Double) async throws {
        let harness = try makeFanDaemonHarness(startupTemperature: temperature)
        defer { try? FileManager.default.removeItem(at: harness.root) }

        await harness.daemon.tick()
        let status = await harness.daemon.status()
        if temperature < FanHardwareReader.plausibleTemperatureRange.lowerBound {
            #expect(status.mode == .unsupported)
            #expect(status.gpuSensorKeys.isEmpty)
            #expect(status.gpuTemperatureC == nil)
            #expect(status.fans.isEmpty)
        } else {
            #expect(status.mode != .unsupported)
            #expect(status.gpuSensorKeys == ["Tg1U"])
            #expect(status.gpuTemperatureC == temperature)
            #expect(status.fans.count == 1)
        }
        #expect(harness.backend.writeCount == 0)
        #expect(!FileManager.default.fileExists(atPath: harness.paths.sessionJournal.path))
    }

    @Test("daemon rediscovers sensors after a transient startup discovery failure")
    func recoversInventoryAfterTransientDiscoveryFailure() async throws {
        let harness = try makeFanDaemonHarness(startupTemperature: -4)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        await harness.daemon.tick()
        #expect((await harness.daemon.status()).mode == .unsupported)

        // Real discovery now succeeds against the same in-memory backend.
        // No helper executable, SMC connection, or launchd service is started.
        harness.backend.setNumber("Tg1U", to: 35)
        let freshInventory = try FanHardwareReader(backend: harness.backend)
            .discover(brandString: "Apple M4 Max")
        #expect(freshInventory.gpuTemperatureKeys == ["Tg1U"])
        #expect(freshInventory.fans.count == 1)

        let session = UUID()
        for _ in 0..<3 {
            harness.clock.advance(by: 60)
            let reply = await harness.daemon.renewLease(
                sessionID: session,
                protocolVersion: FanIPC.protocolVersion,
                providerVersion: "discovery-reproduction"
            )
            #expect(reply.ok)
            await harness.daemon.tick()
        }
        let recovered = await harness.daemon.status()
        let encoded = try JSONEncoder().encode(recovered)
        print("DISCOVERY_RECOVERY_OBSERVED \(String(decoding: encoded, as: UTF8.self))")
        #expect(recovered.providerActive)
        #expect(recovered.gpuSensorKeys == ["Tg1U"])
        #expect(recovered.gpuTemperatureC == 35)
        #expect(recovered.fans.count == 1)
        #expect(recovered.mode != .unsupported)
        #expect(harness.backend.writeCount == 0)
        #expect(harness.backend.byte("F0Md") == 0)
        #expect(harness.backend.byte("Ftst") == 0)
        #expect(!FileManager.default.fileExists(atPath: harness.paths.sessionJournal.path))
    }

    @Test("an empty startup fan inventory recovers with a fresh controller and lease")
    func recoversInitiallyMissingFans() async throws {
        let harness = try makeFanDaemonHarness(startupTemperature: 50, startupFanCount: 0)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let session = UUID()
        #expect((await harness.daemon.renewLease(
            sessionID: session, protocolVersion: FanIPC.protocolVersion, providerVersion: "test"
        )).ok)
        await harness.daemon.tick()
        let unavailable = await harness.daemon.status()
        #expect(unavailable.mode == .unsupported)
        #expect(unavailable.gpuSensorKeys == ["Tg1U"])
        #expect(unavailable.fans.isEmpty)
        #expect(harness.backend.readCount("FNum") == 2)
        #expect(harness.backend.writeCount == 0)

        harness.backend.setByte("FNum", to: 1)
        harness.clock.advance(by: 30)
        #expect((await harness.daemon.renewLease(
            sessionID: session, protocolVersion: FanIPC.protocolVersion, providerVersion: "test"
        )).ok)
        await harness.daemon.tick()
        let recovered = await harness.daemon.status()
        #expect(recovered.mode == .waitingForProvider)
        #expect(!recovered.providerActive)
        #expect(harness.backend.readCount("FNum") == 3)
        await harness.daemon.tick()
        #expect((await harness.daemon.status()).fans.count == 1)
        #expect(harness.backend.writeCount == 0)
        #expect(!FileManager.default.fileExists(atPath: harness.paths.sessionJournal.path))

        // The original controller had no fans. Engagement after a fresh renewal
        // therefore also verifies that recovery replaced the controller.
        #expect((await harness.daemon.renewLease(
            sessionID: session, protocolVersion: FanIPC.protocolVersion, providerVersion: "test"
        )).ok)
        await harness.daemon.tick()
        #expect((await harness.daemon.status()).mode == .manual)
        #expect(harness.backend.byte("F0Md") == 1)
        #expect(harness.backend.journalExistedBeforeFirstManualWrite)
        await harness.daemon.sessionInvalidated(session)
        #expect(harness.backend.byte("F0Md") == 0)
        #expect(!FileManager.default.fileExists(atPath: harness.paths.sessionJournal.path))
    }

    @Test("discovery tries immediately, respects exact deadlines and does not exhaust retries")
    func discoveryRetryBoundaries() async throws {
        let harness = try makeFanDaemonHarness(startupTemperature: -4)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        #expect(harness.backend.readCount("FNum") == 1)
        await harness.daemon.tick()
        #expect(harness.backend.readCount("FNum") == 2)

        for expectedAttempts in 3...7 {
            harness.clock.advance(by: 29)
            await harness.daemon.tick()
            #expect(harness.backend.readCount("FNum") == expectedAttempts - 1)
            harness.clock.advance(by: 1)
            await harness.daemon.tick()
            #expect(harness.backend.readCount("FNum") == expectedAttempts)
            await harness.daemon.tick()
            #expect(harness.backend.readCount("FNum") == expectedAttempts)
        }
        #expect((await harness.daemon.status()).mode == .unsupported)
        #expect((await harness.daemon.status()).lastError != nil)
        #expect(harness.backend.writeCount == 0)
    }

    @Test("throwing rediscovery is diagnosed and retried on the same deadline")
    func throwingDiscoveryRetries() async throws {
        let harness = try makeFanDaemonHarness(startupTemperature: -4)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        harness.backend.failReads("FNum", enabled: true)
        await harness.daemon.tick()
        #expect((await harness.daemon.status()).lastError?.contains("discovery failed") == true)
        #expect(harness.backend.readCount("FNum") == 2)
        harness.backend.failReads("FNum", enabled: false)
        harness.backend.setNumber("Tg1U", to: 35)
        harness.clock.advance(by: 29)
        await harness.daemon.tick()
        #expect(harness.backend.readCount("FNum") == 2)
        harness.clock.advance(by: 1)
        await harness.daemon.tick()
        #expect(harness.backend.readCount("FNum") == 3)
        #expect((await harness.daemon.status()).gpuSensorKeys == ["Tg1U"])
        #expect((await harness.daemon.status()).lastError == nil)
        #expect(harness.backend.writeCount == 0)
    }

    @Test("hot recovery revokes all old leases and requires a new renewal")
    func hotRecoveryRequiresFreshLease() async throws {
        let harness = try makeFanDaemonHarness(startupTemperature: -4)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let oldSession = UUID()
        _ = await harness.daemon.renewLease(
            sessionID: oldSession, protocolVersion: FanIPC.protocolVersion, providerVersion: "test"
        )
        harness.backend.setNumber("Tg1U", to: 50)
        await harness.daemon.tick()
        let ready = await harness.daemon.status()
        #expect(ready.gpuSensorKeys == ["Tg1U"])
        #expect(ready.mode == .waitingForProvider)
        #expect(!ready.providerActive)
        await harness.daemon.tick()
        #expect(harness.backend.writeCount == 0)

        let freshSession = UUID()
        #expect((await harness.daemon.renewLease(
            sessionID: freshSession, protocolVersion: FanIPC.protocolVersion, providerVersion: "test"
        )).ok)
        await harness.daemon.tick()
        #expect((await harness.daemon.status()).mode == .manual)
        #expect(harness.backend.journalExistedBeforeFirstManualWrite)
        await harness.daemon.sessionInvalidated(oldSession)
        #expect((await harness.daemon.status()).providerActive)
        harness.clock.advance(by: FanIPC.leaseDurationSeconds)
        await harness.daemon.tick()
        #expect(!(await harness.daemon.status()).providerActive)
        #expect(harness.backend.byte("F0Md") == 0)
        #expect(!FileManager.default.fileExists(atPath: harness.paths.sessionJournal.path))
    }

    @Test("failed Auto restoration retains the journal and blocks discovery")
    func restorationMustFinishBeforeDiscovery() async throws {
        let harness = try makeFanDaemonHarness(startupTemperature: -4)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        harness.backend.setNumber("Tg1U", to: 35)
        harness.backend.setByte("F0Md", to: 1)
        try recordFanOwnership(at: harness.paths.sessionJournal)(
            FanControlOwnership(fanIndices: [0], ownsFtst: false)
        )
        harness.backend.failNextAutomaticRestore()
        await harness.daemon.tick()
        #expect((await harness.daemon.status()).mode == .error)
        #expect((await harness.daemon.status()).gpuSensorKeys.isEmpty)
        #expect(harness.backend.readCount("FNum") == 1)
        #expect(harness.backend.byte("F0Md") == 1)
        let unresolved = try FanDurableFile.readJSON(
            FanSessionJournal.self, from: harness.paths.sessionJournal, requireRootOwnership: false
        )
        #expect(unresolved.fanIndices == [0])
        await harness.daemon.tick()
        #expect(harness.backend.byte("F0Md") == 0)
        #expect(!FileManager.default.fileExists(atPath: harness.paths.sessionJournal.path))
        #expect((await harness.daemon.status()).mode == .waitingForProvider)
        #expect((await harness.daemon.status()).gpuSensorKeys == ["Tg1U"])
    }

    @Test("sleep prevents discovery and wake preserves the retry deadline", arguments: [10.0, 60.0])
    func wakePreservesDiscoveryDeadline(sleepDuration: Double) async throws {
        let harness = try makeFanDaemonHarness(startupTemperature: -4)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        await harness.daemon.tick()
        await harness.daemon.prepareForSleep()
        harness.backend.setNumber("Tg1U", to: 35)
        harness.clock.advance(by: sleepDuration)
        await harness.daemon.tick()
        #expect(harness.backend.readCount("FNum") == 2)
        await harness.daemon.didWake()
        await harness.daemon.tick()
        if sleepDuration < 30 {
            #expect(harness.backend.readCount("FNum") == 2)
            harness.clock.advance(by: 30 - sleepDuration)
            await harness.daemon.tick()
        }
        #expect(harness.backend.readCount("FNum") == 3)
        #expect((await harness.daemon.status()).mode == .waitingForProvider)
        #expect(!(await harness.daemon.status()).providerActive)
        #expect(harness.backend.writeCount == 0)
    }

    @Test("disabled configuration never starts discovery")
    func disabledConfigurationStaysInert() async throws {
        let harness = try makeFanDaemonHarness(startupTemperature: -4, enabled: false)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        harness.backend.setNumber("Tg1U", to: 50)
        await harness.daemon.tick()
        harness.clock.advance(by: 300)
        await harness.daemon.tick()
        #expect(harness.backend.readCount("FNum") == 1)
        #expect((await harness.daemon.status()).mode == .disabled)
        #expect(harness.backend.writeCount == 0)
    }

    @Test("recovered hardware retains the macOS thermal override", arguments: [
        ProcessInfo.ThermalState.serious, .critical,
    ])
    func recoveredHardwarePreservesThermalOverride(pressure: ProcessInfo.ThermalState) async throws {
        let harness = try makeFanDaemonHarness(startupTemperature: -4, thermalState: pressure)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        harness.backend.setNumber("Tg1U", to: 50)
        await harness.daemon.tick()
        _ = await harness.daemon.renewLease(
            sessionID: UUID(), protocolVersion: FanIPC.protocolVersion, providerVersion: "test"
        )
        await harness.daemon.tick()
        #expect((await harness.daemon.status()).mode == .safetyOverride)
        #expect(harness.backend.writeCount == 0)
    }

    @Test("recovered controller refuses foreign ownership", arguments: [false, true])
    func recoveredControllerRefusesForeignOwnership(ftst: Bool) async throws {
        let harness = try makeFanDaemonHarness(startupTemperature: -4)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        harness.backend.setNumber("Tg1U", to: 50)
        await harness.daemon.tick()
        let ownedKey: SMCKey = ftst ? "Ftst" : "F0Md"
        harness.backend.setByte(ownedKey, to: 1)
        _ = await harness.daemon.renewLease(
            sessionID: UUID(), protocolVersion: FanIPC.protocolVersion, providerVersion: "test"
        )
        await harness.daemon.tick()
        #expect((await harness.daemon.status()).mode == .error)
        #expect(harness.backend.byte(ownedKey) == 1)
        #expect(harness.backend.writeCount == 0)
        #expect(!FileManager.default.fileExists(atPath: harness.paths.sessionJournal.path))
    }

    @Test("recovered controller preserves the takeover RPM floor and durable journal")
    func recoveredControllerPreservesRPMFloor() async throws {
        let harness = try makeFanDaemonHarness(startupTemperature: -4)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        harness.backend.setNumber("Tg1U", to: 50)
        harness.backend.setNumber("F0Ac", to: 4_500)
        await harness.daemon.tick()
        let session = UUID()
        _ = await harness.daemon.renewLease(
            sessionID: session, protocolVersion: FanIPC.protocolVersion, providerVersion: "test"
        )
        await harness.daemon.tick()
        #expect((await harness.daemon.status()).mode == .manual)
        #expect(harness.backend.number("F0Tg") == 4_500)
        #expect(harness.backend.journalExistedBeforeFirstManualWrite)
        await harness.daemon.sessionInvalidated(session)
        #expect(harness.backend.byte("F0Md") == 0)
        #expect(!FileManager.default.fileExists(atPath: harness.paths.sessionJournal.path))
    }

    @Test("overlapping ticks cannot overlap recovery or preserve an in-flight renewal")
    func recoveryDoesNotOverlap() async throws {
        let harness = try makeFanDaemonHarness(startupTemperature: -4)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        harness.backend.setNumber("Tg1U", to: 35)
        let gate = FanBackendReadGate()
        defer { gate.release() }
        harness.backend.blockNextRead("F0Ac", with: gate)
        let controllerWork = Task {
            try await harness.controller.engage(
                speedPercent: 80,
                recordOwnership: recordFanOwnership(at: harness.paths.sessionJournal)
            )
        }
        await gate.waitUntilEntered()
        let recovery = Task { await harness.daemon.tick() }
        #expect(await waitForFanCondition { (await harness.daemon.status()).mode == .unsupported })
        await harness.daemon.tick()
        #expect(harness.backend.readCount("FNum") == 1)
        #expect((await harness.daemon.renewLease(
            sessionID: UUID(), protocolVersion: FanIPC.protocolVersion, providerVersion: "test"
        )).ok)
        gate.release()
        _ = try await controllerWork.value
        await recovery.value
        #expect(harness.backend.readCount("FNum") == 2)
        #expect(!(await harness.controller.isControlling))
        #expect(!(await harness.daemon.status()).providerActive)
        #expect((await harness.daemon.status()).mode == .waitingForProvider)
        #expect(harness.backend.byte("F0Md") == 0)
        #expect(!FileManager.default.fileExists(atPath: harness.paths.sessionJournal.path))
    }

    @Test("lifecycle changes fence a suspended recovery", arguments: FanRecoveryInterruption.allCases)
    func lifecycleFencesSuspendedRecovery(interruption: FanRecoveryInterruption) async throws {
        let harness = try makeFanDaemonHarness(startupTemperature: -4)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        harness.backend.setNumber("Tg1U", to: 35)
        _ = await harness.daemon.renewLease(
            sessionID: UUID(), protocolVersion: FanIPC.protocolVersion, providerVersion: "test"
        )
        let gate = FanBackendReadGate()
        defer { gate.release() }
        harness.backend.blockNextRead("F0Ac", with: gate)
        let controllerWork = Task {
            try await harness.controller.engage(
                speedPercent: 80,
                recordOwnership: recordFanOwnership(at: harness.paths.sessionJournal)
            )
        }
        await gate.waitUntilEntered()
        let recovery = Task { await harness.daemon.tick() }
        #expect(await waitForFanCondition { (await harness.daemon.status()).mode == .unsupported })
        let transition = Task {
            switch interruption {
            case .sleep, .sleepAndWake: await harness.daemon.prepareForSleep()
            case .disable: _ = await harness.daemon.emergencyRestore()
            case .shutdown: await harness.daemon.shutdown()
            }
        }
        #expect(await waitForFanCondition { !(await harness.daemon.status()).providerActive })
        if interruption == .sleepAndWake {
            await harness.daemon.didWake()
        }
        gate.release()
        _ = try await controllerWork.value
        await recovery.value
        await transition.value
        #expect((await harness.daemon.status()).gpuSensorKeys.isEmpty)
        #expect(harness.backend.readCount("FNum") == 1)
        #expect(!(await harness.controller.isControlling))
        #expect(harness.backend.byte("F0Md") == 0)
        #expect(!FileManager.default.fileExists(atPath: harness.paths.sessionJournal.path))

        harness.clock.advance(by: 60)
        await harness.daemon.tick()
        if interruption == .sleepAndWake {
            #expect(harness.backend.readCount("FNum") == 2)
            #expect((await harness.daemon.status()).gpuSensorKeys == ["Tg1U"])
        } else {
            #expect(harness.backend.readCount("FNum") == 1)
            #expect((await harness.daemon.status()).gpuSensorKeys.isEmpty)
        }
    }
}

enum FanRecoveryInterruption: CaseIterable, Sendable {
    case sleep, sleepAndWake, disable, shutdown
}
