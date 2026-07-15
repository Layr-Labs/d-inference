import DarkbloomFanCore
import DarkbloomFanProtocol
import DarkbloomFanService
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#endif

@Suite("Fan service boundary")
struct FanServiceTests {
    @Test("configured provider and root are the only allowed UIDs")
    func uidAuthorization() {
        let uuid = "11111111-1111-1111-1111-111111111111"
        let policy = FanPeerAuthorizationPolicy(
            configuredUID: 502,
            configuredUserUUID: uuid
        )
        #expect(policy.allows(effectiveUID: 502, currentUserUUID: uuid))
        #expect(policy.allows(effectiveUID: 0, currentUserUUID: nil))
        #expect(!policy.allows(effectiveUID: 501, currentUserUUID: uuid))
        #expect(!policy.allows(
            effectiveUID: 502,
            currentUserUUID: "22222222-2222-2222-2222-222222222222"
        ))
        #expect(policy.allows(effectiveUID: 0, currentUserUUID: nil, rootOnly: true))
        #expect(!policy.allows(effectiveUID: 502, currentUserUUID: uuid, rootOnly: true))
    }

    @Test("local account GeneratedUID resolves to a stable UUID")
    func generatedUIDResolution() throws {
        let first = try FanUserIdentity.generatedUID(for: UInt32(getuid()))
        let second = try FanUserIdentity.generatedUID(for: UInt32(getuid()))
        #expect(UUID(uuidString: first) != nil)
        #expect(first == second)
    }

    @Test("production code requirements pin identifiers and Team ID")
    func exactRequirements() {
        #expect(
            FanCodeRequirements.requirement(
                identifier: FanIPC.helperIdentifier,
                teamID: FanIPC.teamID
            )
                == "anchor apple generic and identifier \"io.darkbloom.fan-helper\" "
                    + "and certificate leaf[subject.OU] = \"SLDQ2GJ6TL\""
        )
        #expect(
            FanCodeRequirements.requirement(
                identifier: FanIPC.providerIdentifier,
                teamID: nil
            ) == "identifier \"io.darkbloom.provider\""
        )
        #expect(FanCodeRequirements.providerRequirement().contains("SLDQ2GJ6TL"))
        #expect(FanCodeRequirements.helperRequirement().contains("SLDQ2GJ6TL"))
    }

    @Test("root configuration rejects a policy outside safety bounds")
    func configurationDecodeValidatesPolicy() {
        let data = Data(#"{"schema":1,"enabled":true,"configured_uid":502,"configured_user_uuid":"11111111-1111-1111-1111-111111111111","policy":{"triggerCelsius":45,"releaseCelsius":40,"speedPercent":20,"engageSampleCount":3,"releaseSampleCount":30}}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(FanServiceConfiguration.self, from: data)
        }
    }

    @Test("system LaunchDaemon points only at the root-owned helper")
    func launchDaemonShape() {
        let root = URL(fileURLWithPath: "/tmp/fan-test")
        let paths = FanServicePaths(
            helper: root.appendingPathComponent("helper"),
            launchDaemonPlist: root.appendingPathComponent("fan.plist"),
            configuration: root.appendingPathComponent("policy.json"),
            sessionJournal: root.appendingPathComponent("session.json")
        )
        let plist = FanLaunchDaemon.propertyList(paths: paths)
        #expect(plist["Label"] as? String == FanIPC.machServiceName)
        #expect(plist["ProgramArguments"] as? [String] == [paths.helper.path])
        #expect((plist["MachServices"] as? [String: Bool])?[FanIPC.machServiceName] == true)
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == true)
    }

    @Test("durable state reader rejects symlinks")
    func durableStateRejectsSymlink() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fan-service-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.json")
        let link = directory.appendingPathComponent("link.json")
        try FanDurableFile.writeJSON(
            FanSessionJournal(fanIndices: [0], ownsFtst: false),
            to: target,
            permissions: 0o600,
            owner: nil
        )
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: target.path
        )
        #expect(throws: FanDurableFileError.self) {
            _ = try FanDurableFile.readJSON(
                FanSessionJournal.self,
                from: link,
                requireRootOwnership: false
            )
        }
    }

    @Test("Ftst startup reconciliation verifies every fan")
    func journalRecovery() throws {
        let backend = RecoveryBackend()
        let inventory = recoveryInventory()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fan-recovery-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("session.json")
        try FanDurableFile.writeJSON(
            FanSessionJournal(fanIndices: [0], ownsFtst: true),
            to: journal,
            permissions: 0o600,
            owner: nil
        )

        try FanOwnershipRecovery.reconcile(
            backend: backend,
            inventory: inventory,
            journalURL: journal,
            requireRootOwnership: false,
            timing: recoveryTestTiming()
        )

        #expect(backend.byte(for: "F0Md") == 0)
        #expect(backend.byte(for: "F1Md") == 0)
        #expect(backend.byte(for: "Ftst") == 0)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
    }

    @Test("legacy Ftst-only journal restores every discovered fan")
    func legacyFtstOnlyJournalRecovery() throws {
        let backend = RecoveryBackend()
        let inventory = recoveryInventory()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fan-recovery-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("session.json")
        try FanDurableFile.writeJSON(
            FanSessionJournal(fanIndices: [], ownsFtst: true),
            to: journal,
            permissions: 0o600,
            owner: nil
        )

        try FanOwnershipRecovery.reconcile(
            backend: backend,
            inventory: inventory,
            journalURL: journal,
            requireRootOwnership: false,
            journalOwner: nil,
            timing: recoveryTestTiming()
        )

        #expect(backend.byte(for: "F0Md") == 0)
        #expect(backend.byte(for: "F1Md") == 0)
        #expect(backend.byte(for: "Ftst") == 0)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
    }

    @Test("Ftst-only journal waits for fan inventory before verification")
    func legacyJournalWaitsForFanDiscovery() throws {
        let backend = RecoveryBackend()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fan-recovery-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("session.json")
        try FanDurableFile.writeJSON(
            FanSessionJournal(fanIndices: [], ownsFtst: true),
            to: journal,
            permissions: 0o600,
            owner: nil
        )
        let emptyInventory = FanInventory(
            chipFamily: .m4,
            fans: [],
            gpuTemperatureKeys: [],
            ftstKey: "Ftst"
        )

        #expect(throws: FanOwnershipRecoveryError.self) {
            try FanOwnershipRecovery.reconcile(
                backend: backend,
                inventory: emptyInventory,
                journalURL: journal,
                requireRootOwnership: false,
                journalOwner: nil,
                timing: recoveryTestTiming()
            )
        }
        #expect(backend.byte(for: "Ftst") == 0)
        let pending = try FanDurableFile.readJSON(
            FanSessionJournal.self,
            from: journal,
            requireRootOwnership: false
        )
        #expect(pending.fanIndices.isEmpty)
        #expect(!pending.ownsFtst)
        #expect(pending.verifyAllFans)

        backend.setByte("Ftst", to: 1)
        #expect(throws: FanOwnershipRecoveryError.self) {
            try FanOwnershipRecovery.reconcile(
                backend: backend,
                inventory: recoveryInventory(),
                journalURL: journal,
                requireRootOwnership: false,
                journalOwner: nil,
                timing: recoveryTestTiming()
            )
        }
        #expect(backend.byte(for: "F0Md") == 1)
        #expect(backend.byte(for: "F1Md") == 1)
        #expect(backend.byte(for: "Ftst") == 1)

        backend.setByte("Ftst", to: 0)
        backend.setByte("F0Md", to: 0)
        backend.setByte("F1Md", to: 0)
        try FanOwnershipRecovery.reconcile(
            backend: backend,
            inventory: recoveryInventory(),
            journalURL: journal,
            requireRootOwnership: false,
            journalOwner: nil,
            timing: recoveryTestTiming()
        )
        #expect(backend.byte(for: "F0Md") == 0)
        #expect(backend.byte(for: "F1Md") == 0)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
    }

    @Test("verification marker retains a tracked fan missing from partial discovery")
    func verificationMarkerSurvivesPartialDiscovery() throws {
        let backend = RecoveryBackend()
        backend.setByte("F0Md", to: 0)
        let inventory = recoveryInventory()
        let partialInventory = FanInventory(
            chipFamily: inventory.chipFamily,
            fans: [inventory.fans[0]],
            gpuTemperatureKeys: [],
            ftstKey: inventory.ftstKey
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fan-recovery-partial-inventory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("session.json")
        try FanDurableFile.writeJSON(
            FanSessionJournal(
                fanIndices: [1],
                ownsFtst: false,
                verifyAllFans: true
            ),
            to: journal,
            permissions: 0o600,
            owner: nil
        )

        #expect(throws: FanOwnershipRecoveryError.self) {
            try FanOwnershipRecovery.reconcile(
                backend: backend,
                inventory: partialInventory,
                journalURL: journal,
                requireRootOwnership: false,
                journalOwner: nil,
                timing: recoveryTestTiming()
            )
        }
        let pending = try FanDurableFile.readJSON(
            FanSessionJournal.self,
            from: journal,
            requireRootOwnership: false
        )
        #expect(pending.fanIndices == [1])
        #expect(pending.verifyAllFans)

        try FanOwnershipRecovery.reconcile(
            backend: backend,
            inventory: inventory,
            journalURL: journal,
            requireRootOwnership: false,
            journalOwner: nil,
            timing: recoveryTestTiming()
        )
        #expect(backend.byte(for: "F1Md") == 0)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
    }

    @Test("verification marker retries writes for tracked fans")
    func verificationMarkerRetriesTrackedFan() throws {
        let backend = RecoveryBackend(staleAutomaticReadbacks: 1)
        let fullInventory = recoveryInventory()
        let inventory = FanInventory(
            chipFamily: fullInventory.chipFamily,
            fans: [fullInventory.fans[0]],
            gpuTemperatureKeys: [],
            ftstKey: fullInventory.ftstKey
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fan-recovery-tracked-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("session.json")
        try FanDurableFile.writeJSON(
            FanSessionJournal(
                fanIndices: [0],
                ownsFtst: false,
                verifyAllFans: true
            ),
            to: journal,
            permissions: 0o600,
            owner: nil
        )

        #expect(throws: FanOwnershipRecoveryError.self) {
            try FanOwnershipRecovery.reconcile(
                backend: backend,
                inventory: inventory,
                journalURL: journal,
                requireRootOwnership: false,
                journalOwner: nil,
                timing: recoveryTestTiming()
            )
        }
        #expect(backend.byte(for: "F0Md") == 1)

        try FanOwnershipRecovery.reconcile(
            backend: backend,
            inventory: inventory,
            journalURL: journal,
            requireRootOwnership: false,
            journalOwner: nil,
            timing: recoveryTestTiming()
        )
        #expect(backend.byte(for: "F0Md") == 0)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
    }

    @Test("durable writer rejects a symlink parent directory")
    func durableWriterRejectsSymlinkParent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fan-parent-test-\(UUID().uuidString)")
        let realDirectory = root.appendingPathComponent("real")
        let linkedDirectory = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(
            at: realDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            atPath: linkedDirectory.path,
            withDestinationPath: realDirectory.path
        )

        #expect(throws: FanDurableFileError.self) {
            try FanDurableFile.writeJSON(
                FanSessionJournal(fanIndices: [0], ownsFtst: false),
                to: linkedDirectory.appendingPathComponent("session.json"),
                permissions: 0o600,
                owner: nil
            )
        }
    }

    @Test("recovery continues after one fan fails and narrows the journal")
    func recoveryAggregatesFailures() throws {
        let backend = RecoveryBackend(failFanZeroRestore: true)
        let inventory = recoveryInventory()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fan-recovery-partial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("session.json")
        try FanDurableFile.writeJSON(
            FanSessionJournal(fanIndices: [0, 1], ownsFtst: true),
            to: journal,
            permissions: 0o600,
            owner: nil
        )

        #expect(throws: FanOwnershipRecoveryError.self) {
            try FanOwnershipRecovery.reconcile(
                backend: backend,
                inventory: inventory,
                journalURL: journal,
                requireRootOwnership: false,
                journalOwner: nil,
                timing: recoveryTestTiming()
            )
        }
        #expect(backend.byte(for: "F0Md") == 1)
        #expect(backend.byte(for: "F1Md") == 0)
        #expect(backend.byte(for: "Ftst") == 0)
        let unresolved = try FanDurableFile.readJSON(
            FanSessionJournal.self,
            from: journal,
            requireRootOwnership: false
        )
        #expect(unresolved.fanIndices == [0])
        #expect(!unresolved.ownsFtst)
    }

    @Test("startup recovery retries stale M4 mode and Ftst readback")
    func recoveryRetriesStaleReadback() throws {
        let backend = RecoveryBackend(
            staleAutomaticReadbacks: 2,
            staleFtstReadbacks: 2
        )
        let inventory = recoveryInventory()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fan-recovery-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("session.json")
        try FanDurableFile.writeJSON(
            FanSessionJournal(fanIndices: [0], ownsFtst: true),
            to: journal,
            permissions: 0o600,
            owner: nil
        )

        try FanOwnershipRecovery.reconcile(
            backend: backend,
            inventory: inventory,
            journalURL: journal,
            requireRootOwnership: false,
            journalOwner: nil,
            timing: recoveryTestTiming(attempts: 3)
        )

        #expect(backend.byte(for: "F0Md") == 0)
        #expect(backend.byte(for: "Ftst") == 0)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
        #expect(backend.writes(to: "F0Md", value: 0) == 3)
        #expect(backend.writes(to: "Ftst", value: 0) == 3)
    }

    @Test("new status decoder accepts protocol v1 payloads")
    func statusBackwardCompatibility() throws {
        let data = Data(#"{"helperVersion":"1","protocolVersion":1,"enabled":true,"configuredUID":502,"providerActive":false,"mode":"unsupported","chip":"M4","gpuSensorKeys":[],"gpuTemperatureC":null,"triggerTemperatureC":45,"releaseTemperatureC":40,"speedPercent":80,"fans":[],"lastError":null,"updatedAt":0}"#.utf8)

        let status = try FanIPCCoding.decode(FanServiceStatus.self, from: data)

        #expect(status.mode == .unsupported)
        #expect(status.hardwareReady == nil)
        #expect(status.recoveryPending == nil)
        #expect(status.discoveryError == nil)
        #expect(status.quarantinedSensorKeys == nil)
    }

    @Test("sensor baseline round-trips only catalog keys")
    func sensorBaselineValidation() throws {
        let baseline = FanSensorBaseline(
            chipFamily: .m4,
            sensorKeys: ["Tg1k", "Tg1U"]
        )
        let encoded = try JSONEncoder().encode(baseline)
        let decoded = try JSONDecoder().decode(
            FanSensorBaseline.self,
            from: encoded
        )
        #expect(decoded == baseline)

        let invalid = Data(#"{"schema":1,"chip_family":"M4","sensor_keys":[{"rawValue":"Nope"}]}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(FanSensorBaseline.self, from: invalid)
        }
    }

    @Test("legacy ownership journal defaults full verification off")
    func legacyJournalDecoding() throws {
        let data = Data(#"{"fanIndices":[],"ownsFtst":true}"#.utf8)
        let journal = try JSONDecoder().decode(
            FanSessionJournal.self,
            from: data
        )
        #expect(journal.fanIndices.isEmpty)
        #expect(journal.ownsFtst)
        #expect(!journal.verifyAllFans)
    }
}

private func recoveryInventory() -> FanInventory {
    FanInventory(
        chipFamily: .m4,
        fans: [0, 1].map { index in
            FanCapability(
                index: index,
                actualKey: try! SMCKey("F\(index)Ac"),
                minimumKey: try! SMCKey("F\(index)Mn"),
                maximumKey: try! SMCKey("F\(index)Mx"),
                targetKey: try! SMCKey("F\(index)Tg"),
                modeKey: try! SMCKey("F\(index)Md")
            )
        },
        gpuTemperatureKeys: ["Tg1U"],
        ftstKey: "Ftst"
    )
}

private final class RecoveryBackend: SMCBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SMCKey: UInt8] = ["F0Md": 1, "F1Md": 1, "Ftst": 1]
    private let failFanZeroRestore: Bool
    private var staleAutomaticReadbacks: Int
    private var staleFtstReadbacks: Int
    private var recordedWrites: [(SMCKey, UInt8)] = []

    init(
        failFanZeroRestore: Bool = false,
        staleAutomaticReadbacks: Int = 0,
        staleFtstReadbacks: Int = 0
    ) {
        self.failFanZeroRestore = failFanZeroRestore
        self.staleAutomaticReadbacks = staleAutomaticReadbacks
        self.staleFtstReadbacks = staleFtstReadbacks
    }

    func keyInfo(for _: SMCKey) throws -> SMCKeyInfo {
        SMCKeyInfo(dataSize: 1, dataType: try SMCDataType("ui8 "))
    }

    func read(_ key: SMCKey) throws -> SMCValue {
        lock.lock()
        defer { lock.unlock() }
        return try SMCValue(
            key: key,
            info: SMCKeyInfo(dataSize: 1, dataType: try SMCDataType("ui8 ")),
            bytes: [values[key] ?? 0]
        )
    }

    func write(_ key: SMCKey, bytes: [UInt8]) throws {
        lock.lock()
        recordedWrites.append((key, bytes[0]))
        if failFanZeroRestore, key == "F0Md", bytes[0] == 0 {
            lock.unlock()
            throw SMCError.injectedFailure("fan zero restore failed")
        }
        if key == "F0Md", bytes[0] == 0, staleAutomaticReadbacks > 0 {
            staleAutomaticReadbacks -= 1
            lock.unlock()
            return
        }
        if key == "Ftst", bytes[0] == 0, staleFtstReadbacks > 0 {
            staleFtstReadbacks -= 1
            lock.unlock()
            return
        }
        values[key] = bytes[0]
        lock.unlock()
    }

    func byte(for key: SMCKey) -> UInt8? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func setByte(_ key: SMCKey, to value: UInt8) {
        lock.lock()
        values[key] = value
        lock.unlock()
    }

    func writes(to key: SMCKey, value: UInt8) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedWrites.filter { $0.0 == key && $0.1 == value }.count
    }
}

private func recoveryTestTiming(attempts: Int = 1) -> FanControlTiming {
    FanControlTiming(
        ftstSettleSeconds: 0,
        retryDelaySeconds: 0,
        manualModeAttempts: 1,
        automaticRestoreAttempts: attempts,
        verificationAttempts: 1,
        sleep: { _ in }
    )
}
