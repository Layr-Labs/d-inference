import DarkbloomFanCore
import DarkbloomFanProtocol
import DarkbloomFanService
import Foundation

@testable import DarkbloomFanHelper

struct FanDaemonHarness {
    let root: URL
    let daemon: FanDaemon
    let backend: DaemonBackend
    let controller: TransactionalFanController
    let paths: FanServicePaths
    let clock: TestUptime
}

func makeFanDaemonHarness(
    startupTemperature: Double? = nil,
    startupFanCount: UInt8 = 1,
    enabled: Bool = true,
    thermalState: ProcessInfo.ThermalState = .nominal
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
    let backend = DaemonBackend(journalURL: paths.sessionJournal)
    backend.setByte("FNum", to: startupFanCount)
    if let startupTemperature {
        backend.setNumber("Tg1U", to: startupTemperature)
    }
    let reader = FanHardwareReader(backend: backend)
    let inventory: FanInventory
    if startupTemperature != nil || startupFanCount != 1 {
        inventory = try reader.discover(brandString: "Apple M4 Max")
    } else {
        inventory = FanInventory(
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
    }
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
        enabled: enabled,
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
        thermalState: { thermalState },
        journalOwner: nil,
        requireRootJournalOwnership: false
    )
    return FanDaemonHarness(
        root: root,
        daemon: daemon,
        backend: backend,
        controller: controller,
        paths: paths,
        clock: clock
    )
}

final class TestUptime: @unchecked Sendable {
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

final class DaemonBackend: SMCBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let journalURL: URL
    private var numbers: [SMCKey: Double] = [
        "F0Ac": 0,
        "F0Mn": 1_350,
        "F0Mx": 5_000,
        "F0Tg": 0,
        "Tg1U": 50,
    ]
    private var bytes: [SMCKey: UInt8] = ["FNum": 1, "F0Md": 0, "Ftst": 0]
    private var writes = 0
    private var reads: [SMCKey: Int] = [:]
    private var failedReads: Set<SMCKey> = []
    private var blockedRead: (key: SMCKey, gate: FanBackendReadGate)?
    private(set) var journalExistedBeforeFirstManualWrite = false
    private(set) var journalClaimedFtstBeforeFirstFtstWrite = false
    private var failAutomaticRestore = false
    private var rejectManualWrite = false
    private var claimFtstOnManualRejection = false

    init(journalURL: URL) {
        self.journalURL = journalURL
    }

    func keyInfo(for key: SMCKey) throws -> SMCKeyInfo {
        lock.lock()
        defer { lock.unlock() }
        if bytes[key] != nil {
            return SMCKeyInfo(dataSize: 1, dataType: try SMCDataType("ui8 "))
        }
        guard numbers[key] != nil else {
            throw SMCError.keyNotFound(key)
        }
        return SMCKeyInfo(dataSize: 4, dataType: try SMCDataType("flt "))
    }

    func read(_ key: SMCKey) throws -> SMCValue {
        let gate: FanBackendReadGate? = lock.withLock {
            guard blockedRead?.key == key else { return nil }
            defer { blockedRead = nil }
            return blockedRead?.gate
        }
        try gate?.block()
        lock.lock()
        defer { lock.unlock() }
        reads[key, default: 0] += 1
        if failedReads.contains(key) {
            throw SMCError.injectedFailure("injected read failure for \(key)")
        }
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
        writes += 1
        if bytes[key] != nil {
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

    var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    func setNumber(_ key: SMCKey, to value: Double) {
        lock.lock()
        numbers[key] = value
        lock.unlock()
    }

    func number(_ key: SMCKey) -> Double? {
        lock.withLock { numbers[key] }
    }

    func readCount(_ key: SMCKey) -> Int {
        lock.withLock { reads[key, default: 0] }
    }

    func failReads(_ key: SMCKey, enabled: Bool) {
        lock.withLock {
            if enabled { failedReads.insert(key) }
            else { failedReads.remove(key) }
        }
    }

    func blockNextRead(_ key: SMCKey, with gate: FanBackendReadGate) {
        lock.withLock { blockedRead = (key, gate) }
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

    func rejectNextManualWrite(claimingFtst: Bool = false) {
        lock.lock()
        rejectManualWrite = true
        claimFtstOnManualRejection = claimingFtst
        lock.unlock()
    }
}

/// Holds the real controller actor inside its synchronous backend read, so the
/// daemon can suspend on that actor while lifecycle messages are delivered.
final class FanBackendReadGate: @unchecked Sendable {
    private let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let releaseSignal = DispatchSemaphore(value: 0)

    func waitUntilEntered() async {
        for await _ in entered.stream { return }
    }

    func block() throws {
        entered.continuation.yield(())
        guard releaseSignal.wait(timeout: .now() + 5) == .success else {
            throw SMCError.injectedFailure("controller read gate timed out")
        }
    }

    func release() { releaseSignal.signal() }
}

func recordFanOwnership(at journal: URL) -> @Sendable (FanControlOwnership) throws -> Void {
    { ownership in
        try FanDurableFile.writeJSON(
            FanSessionJournal(fanIndices: ownership.fanIndices, ownsFtst: ownership.ownsFtst),
            to: journal,
            permissions: 0o600,
            owner: nil
        )
    }
}

func waitForFanCondition(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}
