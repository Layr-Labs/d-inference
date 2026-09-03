import DarkbloomFanCore
import DarkbloomFanProtocol
import DarkbloomFanService
import Foundation
import Testing

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

    @Test("startup reconciliation restores only journaled fans and Ftst")
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
            requireRootOwnership: false
        )

        #expect(backend.byte(for: "F0Md") == 0)
        #expect(backend.byte(for: "F1Md") == 1)
        #expect(backend.byte(for: "Ftst") == 0)
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
                journalOwner: nil
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

    init(failFanZeroRestore: Bool = false) {
        self.failFanZeroRestore = failFanZeroRestore
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
        if failFanZeroRestore, key == "F0Md", bytes[0] == 0 {
            lock.unlock()
            throw SMCError.injectedFailure("fan zero restore failed")
        }
        values[key] = bytes[0]
        lock.unlock()
    }

    func byte(for key: SMCKey) -> UInt8? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }
}
