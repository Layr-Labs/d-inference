import DarkbloomFanCore
import DarkbloomFanProtocol
import DarkbloomFanService
import Foundation
import Testing

@testable import DarkbloomFanHelper

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

    @Test("protocol mismatch never grants a lease")
    func protocolMismatch() async throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let reply = await harness.daemon.renewLease(
            sessionID: UUID(),
            protocolVersion: FanIPC.protocolVersion + 1,
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
}

private struct FanDaemonHarness {
    let root: URL
    let daemon: FanDaemon
    let backend: DaemonBackend
    let paths: FanServicePaths
    let clock: TestUptime
}

private func makeHarness() throws -> FanDaemonHarness {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("fan-daemon-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let paths = FanServicePaths(
        helper: root.appendingPathComponent("helper"),
        launchDaemonPlist: root.appendingPathComponent("fan.plist"),
        configuration: root.appendingPathComponent("policy.json"),
        sessionJournal: root.appendingPathComponent("session.json")
    )
    let backend = DaemonBackend(journalURL: paths.sessionJournal)
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
        gpuTemperatureKeys: ["Tg1U"],
        ftstKey: "Ftst"
    )
    let reader = FanHardwareReader(backend: backend)
    let controller = TransactionalFanController(
        backend: backend,
        inventory: inventory,
        timing: FanControlTiming(
            ftstSettleSeconds: 0,
            retryDelaySeconds: 0,
            manualModeAttempts: 2,
            verificationAttempts: 1,
            sleep: { _ in }
        )
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
        requireRootJournalOwnership: false
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
    private var numbers: [SMCKey: Double] = [
        "F0Ac": 0,
        "F0Mn": 1_350,
        "F0Mx": 5_000,
        "F0Tg": 0,
        "Tg1U": 50,
    ]
    private var bytes: [SMCKey: UInt8] = ["F0Md": 0, "Ftst": 0]
    private(set) var journalExistedBeforeFirstManualWrite = false
    private var failAutomaticRestore = false

    init(journalURL: URL) {
        self.journalURL = journalURL
    }

    func keyInfo(for key: SMCKey) throws -> SMCKeyInfo {
        if bytes[key] != nil {
            return SMCKeyInfo(dataSize: 1, dataType: try SMCDataType("ui8 "))
        }
        return SMCKeyInfo(dataSize: 4, dataType: try SMCDataType("flt "))
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
        let value = numbers[key] ?? 0
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
            if key == "F0Md", raw[0] == 0, failAutomaticRestore {
                failAutomaticRestore = false
                throw SMCError.injectedFailure("transient automatic restore failure")
            }
            if key == "F0Md", raw[0] == 1, !journalExistedBeforeFirstManualWrite {
                journalExistedBeforeFirstManualWrite = FileManager.default.fileExists(
                    atPath: journalURL.path
                )
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
}
