import DarkbloomFanCore
import DarkbloomFanProtocol
import DarkbloomFanService
import Foundation
import Testing

@testable import DarkbloomFanHelper

private let m4MaxGPUKeys: [SMCKey] = [
    "Tg0G", "Tg0H", "Tg1U", "Tg1k",
    "Tg0K", "Tg0L", "Tg0d", "Tg0e",
]

@Suite("Fan helper daemon")
struct FanDaemonTests {
    @Test("provider lease is required and disconnect restores Auto")
    func providerLeaseLifecycle() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        await harness.daemon.tick()
        #expect((await harness.daemon.status()).mode == .waitingForProvider)
        #expect(harness.backend.byte("F0Md") == 0)

        let session = UUID()
        let reply = await harness.daemon.renewLease(
            sessionID: session,
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.9"
        )
        #expect(reply.ok)
        await harness.daemon.tick()

        let active = await harness.daemon.status()
        #expect(active.mode == .manual)
        #expect(active.providerActive)
        #expect(harness.backend.byte("F0Md") == 1)
        #expect(harness.backend.journalExistedBeforeFirstManualWrite)
        #expect(FileManager.default.fileExists(atPath: harness.paths.sessionJournal.path))
        let journal = try FanDurableFile.readJSON(
            FanSessionJournal.self,
            from: harness.paths.sessionJournal,
            requireRootOwnership: false
        )
        #expect(!journal.ownsFtst)
        #expect(journal.verifyAllFans)
        #expect(journal.verificationFanIndices == [0])
        #expect(journal.minimumVerificationFanCount == 1)

        await harness.daemon.sessionInvalidated(session)
        #expect(harness.backend.byte("F0Md") == 0)
        #expect(!FileManager.default.fileExists(atPath: harness.paths.sessionJournal.path))
        #expect((await harness.daemon.status()).mode == .waitingForProvider)

        _ = await harness.daemon.renewLease(
            sessionID: UUID(),
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.9"
        )
        await harness.daemon.tick()
        #expect(harness.backend.byte("F0Md") == 1)
    }

    @Test("expired lease restores Auto without a disconnect callback")
    func leaseExpiry() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let session = UUID()
        _ = await harness.daemon.renewLease(
            sessionID: session,
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.9"
        )
        await harness.daemon.tick()
        #expect(harness.backend.byte("F0Md") == 1)

        harness.clock.advance(by: FanIPC.leaseDurationSeconds + 1)
        await harness.daemon.tick()
        #expect(harness.backend.byte("F0Md") == 0)
        #expect(!(await harness.daemon.status()).providerActive)
    }

    @Test("legacy helper protocol never grants a lease")
    func legacyProtocolMismatch() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let reply = await harness.daemon.renewLease(
            sessionID: UUID(),
            protocolVersion: FanIPC.protocolVersion - 1,
            providerVersion: "0.7.9"
        )
        #expect(!reply.ok)
        await harness.daemon.tick()
        #expect(harness.backend.byte("F0Md") == 0)
        #expect((await harness.daemon.status()).mode == .waitingForProvider)
    }

    @Test("sleep restores Auto and requires a fresh provider renewal")
    func sleepRecovery() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        _ = await harness.daemon.renewLease(
            sessionID: UUID(),
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.9"
        )
        await harness.daemon.tick()
        #expect(harness.backend.byte("F0Md") == 1)

        await harness.daemon.prepareForSleep()
        #expect(harness.backend.byte("F0Md") == 0)
        let sleepingRenewal = await harness.daemon.renewLease(
            sessionID: UUID(),
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.9"
        )
        #expect(!sleepingRenewal.ok)
        await harness.daemon.didWake()
        let status = await harness.daemon.status()
        #expect(!status.providerActive)
        #expect(status.mode == .waitingForProvider)
    }

    @Test("transient Auto failure is retried while ownership remains")
    func restoreRetry() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let session = UUID()
        _ = await harness.daemon.renewLease(
            sessionID: session,
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.9"
        )
        await harness.daemon.tick()
        #expect(harness.backend.byte("F0Md") == 1)

        harness.backend.failNextAutomaticRestore()
        await harness.daemon.sessionInvalidated(session)
        #expect(harness.backend.byte("F0Md") == 1)
        #expect(FileManager.default.fileExists(atPath: harness.paths.sessionJournal.path))

        await harness.daemon.tick()
        #expect(harness.backend.byte("F0Md") == 0)
        #expect(!FileManager.default.fileExists(atPath: harness.paths.sessionJournal.path))
    }

    @Test("administrator restore latches leases off until helper restart")
    func administrativeDisableLatch() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        _ = await harness.daemon.renewLease(
            sessionID: UUID(),
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.9"
        )
        await harness.daemon.tick()
        #expect(harness.backend.byte("F0Md") == 1)

        let restored = await harness.daemon.emergencyRestore()
        #expect(restored.ok)
        #expect(harness.backend.byte("F0Md") == 0)
        let renewal = await harness.daemon.renewLease(
            sessionID: UUID(),
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.9"
        )
        #expect(!renewal.ok)
        #expect(!(await harness.daemon.status()).enabled)
    }

    @Test("Ftst ownership is journaled immediately before the first write")
    func ftstIntentPrecedesWrite() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        harness.backend.rejectNextManualWrite()

        _ = await harness.daemon.renewLease(
            sessionID: UUID(),
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.9"
        )
        await harness.daemon.tick()

        #expect(harness.backend.byte("Ftst") == 1)
        #expect(harness.backend.journalClaimedFtstBeforeFirstFtstWrite)
        let journal = try FanDurableFile.readJSON(
            FanSessionJournal.self,
            from: harness.paths.sessionJournal,
            requireRootOwnership: false
        )
        #expect(journal.ownsFtst)
        #expect(journal.verifyAllFans)
        #expect(journal.verificationFanIndices == [0])
        #expect(journal.minimumVerificationFanCount == 1)
    }

    @Test("M4 Max invalid sensor restores Auto, rediscovers, and reacquires lease")
    func m4MaxInvalidSensorRecovery() async throws {
        let harness = try makeHarness(
            inventoryGPUKeys: m4MaxGPUKeys,
            backendGPUKeys: m4MaxGPUKeys
        )
        defer { try? FileManager.default.removeItem(at: harness.root) }
        harness.backend.rejectNextManualWrite()

        let firstLease = await harness.daemon.renewLease(
            sessionID: UUID(),
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.10"
        )
        #expect(firstLease.ok)
        await harness.daemon.tick()
        #expect((await harness.daemon.status()).mode == .manual)
        #expect(harness.backend.byte("Ftst") == 1)

        harness.backend.setNumber("Tg1k", to: -4)
        await harness.daemon.tick()

        let failed = await harness.daemon.status()
        #expect(failed.mode == .error)
        #expect(!failed.providerActive)
        #expect(failed.recoveryPending == true)
        #expect(failed.quarantinedSensorKeys == ["Tg1k"])
        #expect(harness.backend.byte("F0Md") == FanMode.automatic.rawValue)
        #expect(harness.backend.byte("Ftst") == 0)

        harness.clock.advance(by: 5)
        await harness.daemon.tick()
        let recovered = await harness.daemon.status()
        #expect(recovered.hardwareReady == true)
        #expect(recovered.mode == .waitingForProvider)
        #expect(recovered.gpuSensorKeys.count == 7)
        #expect(!recovered.gpuSensorKeys.contains("Tg1k"))

        let renewed = await harness.daemon.renewLease(
            sessionID: UUID(),
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.10"
        )
        #expect(renewed.ok)
        await harness.daemon.tick()
        #expect((await harness.daemon.status()).mode == .manual)
        #expect(harness.backend.byte("F0Md") == FanMode.manual.rawValue)
    }

    @Test("empty startup inventory rejects leases until sensors recover")
    func emptyStartupInventoryRediscovery() async throws {
        let harness = try makeHarness(
            inventoryGPUKeys: [],
            backendGPUKeys: m4MaxGPUKeys,
            initialDiscoveryError: "GPU sensor discovery returned no plausible readings"
        )
        defer { try? FileManager.default.removeItem(at: harness.root) }
        for key in m4MaxGPUKeys {
            harness.backend.setNumber(key, to: -4)
        }

        let rejected = await harness.daemon.renewLease(
            sessionID: UUID(),
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.10"
        )
        #expect(!rejected.ok)
        #expect(rejected.message?.contains("GPU sensor discovery") == true)

        await harness.daemon.tick()
        let unavailable = await harness.daemon.status()
        #expect(unavailable.mode == .unsupported)
        #expect(unavailable.hardwareReady == false)
        #expect(unavailable.recoveryPending == true)
        #expect(unavailable.lastError != nil)
        #expect(FileManager.default.fileExists(atPath: harness.paths.lastFailure.path))

        for key in m4MaxGPUKeys {
            harness.backend.setNumber(key, to: 50)
        }
        harness.clock.advance(by: 5)
        await harness.daemon.tick()

        let recovered = await harness.daemon.status()
        #expect(recovered.hardwareReady == true)
        #expect(recovered.recoveryPending == false)
        #expect(recovered.gpuSensorKeys == m4MaxGPUKeys.map(\.rawValue))
        #expect(recovered.lastError == nil)
        #expect(!FileManager.default.fileExists(atPath: harness.paths.lastFailure.path))

        let accepted = await harness.daemon.renewLease(
            sessionID: UUID(),
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.10"
        )
        #expect(accepted.ok)
        await harness.daemon.tick()
        #expect((await harness.daemon.status()).mode == .manual)
    }

    @Test("restart cannot lower the durable M4 sensor quorum")
    func restartPreservesSensorQuorum() async throws {
        let reducedKeys = Array(m4MaxGPUKeys.prefix(3)) + ["Tg0j", "Tg0k"]
        let harness = try makeHarness(
            inventoryGPUKeys: reducedKeys,
            backendGPUKeys: reducedKeys,
            baselineSensorKeys: m4MaxGPUKeys
        )
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let rejected = await harness.daemon.renewLease(
            sessionID: UUID(),
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.10"
        )

        #expect(!rejected.ok)
        let status = await harness.daemon.status()
        #expect(status.hardwareReady == false)
        #expect(status.recoveryPending == true)
    }

    @Test("first lease waits for a durable sensor baseline")
    func leaseWaitsForSensorBaseline() async throws {
        let harness = try makeHarness(baselineSensorKeys: [])
        defer { try? FileManager.default.removeItem(at: harness.root) }

        let beforePersistence = await harness.daemon.renewLease(
            sessionID: UUID(),
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.10"
        )
        #expect(!beforePersistence.ok)
        #expect(beforePersistence.message?.contains("not durable") == true)

        await harness.daemon.tick()
        #expect(FileManager.default.fileExists(
            atPath: harness.paths.sensorBaseline.path
        ))

        let afterPersistence = await harness.daemon.renewLease(
            sessionID: UUID(),
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.10"
        )
        #expect(afterPersistence.ok)
    }

    @Test("startup restores journal before rejecting a corrupt sensor baseline")
    func startupRecoveryPrecedesBaselineValidation() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        harness.backend.setByte("F0Md", to: FanMode.manual.rawValue)
        harness.backend.setByte("Ftst", to: 1)
        try FanDurableFile.writeJSON(
            FanSessionJournal(fanIndices: [0], ownsFtst: true),
            to: harness.paths.sessionJournal,
            permissions: 0o600,
            owner: nil
        )
        try FanDurableFile.writeData(
            Data("{}".utf8),
            to: harness.paths.sensorBaseline,
            permissions: 0o600,
            owner: nil
        )
        let reader = FanHardwareReader(backend: harness.backend)

        #expect(throws: (any Error).self) {
            _ = try FanStartupRecovery.prepare(
                backend: harness.backend,
                reader: reader,
                paths: harness.paths,
                brandString: "Apple M4 Max",
                requireRootOwnership: false,
                journalOwner: nil,
                timing: FanControlTiming(
                    ftstSettleSeconds: 0,
                    retryDelaySeconds: 0,
                    manualModeAttempts: 1,
                    automaticRestoreAttempts: 1,
                    verificationAttempts: 1,
                    sleep: { _ in }
                )
            )
        }

        #expect(harness.backend.byte("F0Md") == FanMode.automatic.rawValue)
        #expect(harness.backend.byte("Ftst") == 0)
        #expect(!FileManager.default.fileExists(
            atPath: harness.paths.sessionJournal.path
        ))
    }

    @Test("missing GPU key revokes the lease and enters rediscovery")
    func missingSensorRecovery() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        _ = await harness.daemon.renewLease(
            sessionID: UUID(),
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.10"
        )
        await harness.daemon.tick()
        #expect((await harness.daemon.status()).mode == .manual)

        harness.backend.removeNumber("Tg1k")
        await harness.daemon.tick()

        let failed = await harness.daemon.status()
        #expect(failed.mode == .error)
        #expect(!failed.providerActive)
        #expect(failed.recoveryPending == true)
        #expect(failed.quarantinedSensorKeys == ["Tg1k"])

        harness.clock.advance(by: 5)
        await harness.daemon.tick()
        let recovered = await harness.daemon.status()
        #expect(recovered.hardwareReady == true)
        #expect(recovered.gpuSensorKeys.count == 7)
    }

    @Test("lease expiry during a slow engage restores Auto")
    func leaseExpiresDuringEngage() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        harness.backend.blockNextManualWrite(entered: entered, release: release)
        _ = await harness.daemon.renewLease(
            sessionID: UUID(),
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.10"
        )

        let daemon = harness.daemon
        let tick = Task { await daemon.tick() }
        #expect(await waitForSemaphore(entered, timeout: .now() + 2) == .success)
        harness.clock.advance(by: FanIPC.leaseDurationSeconds + 1)
        release.signal()
        await tick.value

        let status = await harness.daemon.status()
        #expect(!status.providerActive)
        #expect(harness.backend.byte("F0Md") == FanMode.automatic.rawValue)
        #expect(!FileManager.default.fileExists(atPath: harness.paths.sessionJournal.path))
    }

    @Test("maintenance never journals or clears a foreign Ftst gate")
    func maintenancePreservesForeignFtst() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }

        _ = await harness.daemon.renewLease(
            sessionID: UUID(),
            protocolVersion: FanIPC.protocolVersion,
            providerVersion: "0.7.9"
        )
        await harness.daemon.tick()
        #expect(harness.backend.byte("F0Md") == 1)

        harness.clock.advance(by: 6)
        harness.backend.setByte("F0Md", to: FanMode.system.rawValue)
        harness.backend.rejectNextManualWrite(claimingFtst: true)
        await harness.daemon.tick()

        #expect(harness.backend.byte("F0Md") == 0)
        #expect(harness.backend.byte("Ftst") == 1)
        #expect(!FileManager.default.fileExists(atPath: harness.paths.sessionJournal.path))
    }
}

private struct FanDaemonHarness {
    let root: URL
    let daemon: FanDaemon
    let backend: DaemonBackend
    let paths: FanServicePaths
    let clock: TestUptime
}

private func makeHarness(
    inventoryGPUKeys: [SMCKey] = m4MaxGPUKeys,
    backendGPUKeys: [SMCKey] = m4MaxGPUKeys,
    baselineSensorKeys: [SMCKey] = m4MaxGPUKeys,
    initialLastError: String? = nil,
    initialDiscoveryError: String? = nil
) throws -> FanDaemonHarness {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("fan-daemon-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let paths = FanServicePaths(
        helper: root.appendingPathComponent("helper"),
        launchDaemonPlist: root.appendingPathComponent("fan.plist"),
        configuration: root.appendingPathComponent("policy.json"),
        sessionJournal: root.appendingPathComponent("session.json")
    )
    let backend = DaemonBackend(
        journalURL: paths.sessionJournal,
        gpuKeys: backendGPUKeys
    )
    let inventory = FanInventory(
        chipFamily: .m4,
        fans: [FanCapability(
            index: 0,
            actualKey: "F0Ac",
            minimumKey: "F0Mn",
            maximumKey: "F0Mx",
            targetKey: "F0Tg",
            modeKey: "F0Md"
        )],
        gpuTemperatureKeys: inventoryGPUKeys,
        ftstKey: "Ftst"
    )
    let reader = FanHardwareReader(backend: backend)
    let timing = FanControlTiming(
        ftstSettleSeconds: 0,
        retryDelaySeconds: 0,
        manualModeAttempts: 2,
        automaticRestoreAttempts: 1,
        verificationAttempts: 1,
        sleep: { _ in }
    )
    let controller = TransactionalFanController(
        backend: backend,
        inventory: inventory,
        timing: timing
    )
    let clock = TestUptime()
    let configuration = FanServiceConfiguration(
        enabled: true,
        configuredUID: 502,
        configuredUserUUID: "11111111-1111-1111-1111-111111111111",
        policy: try FanPolicyConfiguration(
            triggerCelsius: 45,
            releaseCelsius: 40,
            speedPercent: 80,
            engageSampleCount: 1,
            releaseSampleCount: 1
        )
    )
    let daemon = FanDaemon(
        configuration: configuration,
        paths: paths,
        backend: backend,
        inventory: inventory,
        reader: reader,
        controller: controller,
        uptime: { clock.value },
        journalOwner: nil,
        requireRootJournalOwnership: false,
        discoverInventory: {
            try reader.discover(brandString: "Apple M4 Max")
        },
        controllerFactory: { refreshedInventory in
            TransactionalFanController(
                backend: backend,
                inventory: refreshedInventory,
                timing: timing
            )
        },
        baselineSensorKeys: baselineSensorKeys,
        initialLastError: initialLastError,
        initialDiscoveryError: initialDiscoveryError
    )
    return FanDaemonHarness(
        root: root,
        daemon: daemon,
        backend: backend,
        paths: paths,
        clock: clock
    )
}

private final class TestUptime: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 100

    var value: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current += seconds
        lock.unlock()
    }
}

private final class DaemonBackend: SMCBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let journalURL: URL
    private var numbers: [SMCKey: Double]
    private var bytes: [SMCKey: UInt8] = ["FNum": 1, "F0Md": 0, "Ftst": 0]
    private(set) var journalExistedBeforeFirstManualWrite = false
    private(set) var journalClaimedFtstBeforeFirstFtstWrite = false
    private var failAutomaticRestore = false
    private var rejectManualWrite = false
    private var claimFtstOnManualRejection = false
    private var blockedManualWrite: (
        entered: DispatchSemaphore,
        release: DispatchSemaphore
    )?

    init(journalURL: URL, gpuKeys: [SMCKey]) {
        self.journalURL = journalURL
        self.numbers = [
            "F0Ac": 0,
            "F0Mn": 1_350,
            "F0Mx": 5_000,
            "F0Tg": 0,
        ]
        for key in gpuKeys {
            numbers[key] = 50
        }
    }

    func keyInfo(for key: SMCKey) throws -> SMCKeyInfo {
        if bytes[key] != nil {
            return SMCKeyInfo(dataSize: 1, dataType: try SMCDataType("ui8 "))
        }
        if numbers[key] != nil {
            return SMCKeyInfo(dataSize: 4, dataType: try SMCDataType("flt "))
        }
        throw SMCError.keyNotFound(key)
    }

    func read(_ key: SMCKey) throws -> SMCValue {
        lock.lock()
        defer { lock.unlock() }
        if let byte = bytes[key] {
            return try SMCValue(
                key: key,
                info: SMCKeyInfo(dataSize: 1, dataType: try SMCDataType("ui8 ")),
                bytes: [byte]
            )
        }
        guard let value = numbers[key] else {
            throw SMCError.keyNotFound(key)
        }
        return try SMCValue(
            key: key,
            info: SMCKeyInfo(dataSize: 4, dataType: try SMCDataType("flt ")),
            bytes: SMCValue.float32Bytes(value, key: key)
        )
    }

    func write(_ key: SMCKey, bytes raw: [UInt8]) throws {
        lock.lock()
        defer { lock.unlock() }
        if bytes[key] != nil {
            if key == "F0Md", raw[0] == 1, let blockedManualWrite {
                self.blockedManualWrite = nil
                blockedManualWrite.entered.signal()
                blockedManualWrite.release.wait()
            }
            if key == "F0Md", raw[0] == 1, rejectManualWrite {
                rejectManualWrite = false
                if claimFtstOnManualRejection {
                    bytes["Ftst"] = 1
                    claimFtstOnManualRejection = false
                }
                throw SMCError.firmwareRejected(
                    operation: .writeBytes,
                    key: key,
                    result: 0x82
                )
            }
            if key == "F0Md", raw[0] == 0, failAutomaticRestore {
                failAutomaticRestore = false
                throw SMCError.injectedFailure("transient automatic restore failure")
            }
            if key == "F0Md", raw[0] == 1, !journalExistedBeforeFirstManualWrite {
                journalExistedBeforeFirstManualWrite = FileManager.default.fileExists(
                    atPath: journalURL.path
                )
            }
            if key == "Ftst", raw[0] == 1,
               !journalClaimedFtstBeforeFirstFtstWrite
            {
                let journal = try? FanDurableFile.readJSON(
                    FanSessionJournal.self,
                    from: journalURL,
                    requireRootOwnership: false
                )
                journalClaimedFtstBeforeFirstFtstWrite = journal?.ownsFtst == true
            }
            bytes[key] = raw[0]
            return
        }
        let value = try SMCValue(
            key: key,
            info: SMCKeyInfo(dataSize: 4, dataType: try SMCDataType("flt ")),
            bytes: raw
        ).float32()
        numbers[key] = value
    }

    func byte(_ key: SMCKey) -> UInt8? {
        lock.lock()
        defer { lock.unlock() }
        return bytes[key]
    }

    func failNextAutomaticRestore() {
        lock.lock()
        failAutomaticRestore = true
        lock.unlock()
    }

    func setByte(_ key: SMCKey, to value: UInt8) {
        lock.lock()
        bytes[key] = value
        lock.unlock()
    }

    func setNumber(_ key: SMCKey, to value: Double) {
        lock.lock()
        numbers[key] = value
        lock.unlock()
    }

    func removeNumber(_ key: SMCKey) {
        lock.lock()
        numbers.removeValue(forKey: key)
        lock.unlock()
    }

    func rejectNextManualWrite(claimingFtst: Bool = false) {
        lock.lock()
        rejectManualWrite = true
        claimFtstOnManualRejection = claimingFtst
        lock.unlock()
    }

    func blockNextManualWrite(
        entered: DispatchSemaphore,
        release: DispatchSemaphore
    ) {
        lock.lock()
        blockedManualWrite = (entered, release)
        lock.unlock()
    }
}

private func waitForSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: DispatchTime
) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: timeout))
        }
    }
}
