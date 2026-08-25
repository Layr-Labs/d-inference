import Foundation
import Testing
@testable import DarkbloomApp

@Suite("User shortcut transaction")
struct AppUserShortcutTransactionTests {
    @Test("owned replacement recovers every durable interruption")
    func ownedReplacementRecoversEveryInterruption() throws {
        for point in ownedReplacementFaultPoints {
            let fixture = try ShortcutFixture()
            defer { fixture.remove() }
            try fixture.makeOwnedApp(
                at: fixture.shortcut,
                payload: "predecessor-\(point.rawValue)"
            )

            #expect(throws: InjectedShortcutFault.self) {
                _ = try fixture.transaction(
                    faultInjector: failShortcutOnce(at: point)
                ).converge(transactionID: fixture.firstID)
            }

            let restarted = fixture.transaction()
            _ = try restarted.recover()
            _ = try restarted.converge(transactionID: fixture.secondID)

            try fixture.expectCorrectShortcut()
            try fixture.expectNoOwnedShortcutArtifacts()
            #expect(!fixture.journalExists)
        }
    }

    @Test("fresh shortcut publication recovers every reachable interruption")
    func freshShortcutRecoversEveryInterruption() throws {
        for point in freshShortcutFaultPoints {
            let fixture = try ShortcutFixture()
            defer { fixture.remove() }

            #expect(throws: InjectedShortcutFault.self) {
                _ = try fixture.transaction(
                    faultInjector: failShortcutOnce(at: point)
                ).converge(transactionID: fixture.firstID)
            }

            let restarted = fixture.transaction()
            _ = try restarted.recover()
            _ = try restarted.converge(transactionID: fixture.secondID)

            try fixture.expectCorrectShortcut()
            try fixture.expectNoOwnedShortcutArtifacts()
            #expect(!fixture.journalExists)
        }
    }

    @Test("stale backup restoration is deterministic and restart safe")
    func staleBackupRestorationIsDeterministic() throws {
        for point in staleRestoreFaultPoints {
            let fixture = try ShortcutFixture()
            defer { fixture.remove() }
            let first = fixture.backup(id: fixture.firstID)
            let second = fixture.backup(id: fixture.secondID)
            try fixture.makeOwnedApp(at: second, payload: "second")
            try fixture.makeOwnedApp(at: first, payload: "first")

            #expect(throws: InjectedShortcutFault.self) {
                _ = try fixture.transaction(
                    faultInjector: failShortcutOnce(at: point)
                ).converge(transactionID: fixture.thirdID)
            }

            if point == .staleBackupRestored
                || point == .staleBackupRestoreRecorded
                || point == .journalRemoved
            {
                #expect(try fixture.payload(at: fixture.shortcut) == "first")
            }

            let restarted = fixture.transaction()
            _ = try restarted.recover()
            _ = try restarted.converge(transactionID: fixture.thirdID)

            try fixture.expectCorrectShortcut()
            try fixture.expectNoOwnedShortcutArtifacts()
            #expect(!fixture.journalExists)
        }
    }

    @Test("stale backup retirement recovers every cleanup interruption")
    func staleBackupRetirementRecoversEveryInterruption() throws {
        for point in staleRetirementFaultPoints {
            let fixture = try ShortcutFixture()
            defer { fixture.remove() }
            try fixture.makeShortcut()
            try fixture.makeOwnedApp(
                at: fixture.backup(id: fixture.firstID),
                payload: "stale-\(point.rawValue)"
            )

            #expect(throws: InjectedShortcutFault.self) {
                _ = try fixture.transaction(
                    faultInjector: failShortcutOnce(at: point)
                ).converge(transactionID: fixture.secondID)
            }

            let restarted = fixture.transaction()
            _ = try restarted.recover()
            _ = try restarted.converge(transactionID: fixture.secondID)

            try fixture.expectCorrectShortcut()
            try fixture.expectNoOwnedShortcutArtifacts()
            #expect(!fixture.journalExists)
        }
    }

    @Test("interruption matrix covers every transaction fault point")
    func interruptionMatrixIsExhaustive() {
        let covered = Set((
            ownedReplacementFaultPoints
                + freshShortcutFaultPoints
                + staleRestoreFaultPoints
                + staleRetirementFaultPoints
        ).map(\.rawValue))
        #expect(
            covered
                == Set(
                    AppUserShortcutTransaction.FaultPoint.allCases.map(\.rawValue)
                )
        )
    }

    @Test("foreign destination is byte-for-byte preserved while owned backups retire")
    func foreignDestinationIsPreserved() throws {
        let fixture = try ShortcutFixture()
        defer { fixture.remove() }
        let foreign = Data("foreign-user-destination".utf8)
        try foreign.write(to: fixture.shortcut)
        try fixture.makeOwnedApp(
            at: fixture.backup(id: fixture.firstID),
            payload: "stale-owned-backup"
        )

        let result = try fixture.transaction().converge(
            transactionID: fixture.secondID
        )

        #expect(result == .init(installedShortcut: false))
        #expect(try Data(contentsOf: fixture.shortcut) == foreign)
        #expect(!fixture.isSymlink(fixture.shortcut))
        try fixture.expectNoOwnedShortcutArtifacts()
        #expect(!fixture.journalExists)
    }

    @Test("foreign backup namespace entry is preserved exactly")
    func foreignBackupIsPreserved() throws {
        let fixture = try ShortcutFixture()
        defer { fixture.remove() }
        let foreignBackup = fixture.backup(id: fixture.firstID)
        let foreign = Data("foreign-backup-name".utf8)
        try foreign.write(to: foreignBackup)

        _ = try fixture.transaction().converge(
            transactionID: fixture.secondID
        )

        try fixture.expectCorrectShortcut()
        #expect(try Data(contentsOf: foreignBackup) == foreign)
        #expect(!fixture.journalExists)
    }

    @Test("unjournaled staged shortcut is cleaned on restart")
    func unjournaledCandidateIsCleaned() throws {
        let fixture = try ShortcutFixture()
        defer { fixture.remove() }

        #expect(throws: InjectedShortcutFault.self) {
            _ = try fixture.transaction(
                faultInjector: failShortcutOnce(at: .candidatePrepared)
            ).converge(transactionID: fixture.firstID)
        }

        _ = try fixture.transaction().converge(
            transactionID: fixture.secondID
        )

        try fixture.expectCorrectShortcut()
        try fixture.expectNoOwnedShortcutArtifacts()
    }

    @Test("missing candidate restores its owned backup before retry")
    func missingCandidateRestoresOwnedBackup() throws {
        let fixture = try ShortcutFixture()
        defer { fixture.remove() }
        try fixture.makeOwnedApp(at: fixture.shortcut, payload: "restore-me")

        #expect(throws: InjectedShortcutFault.self) {
            _ = try fixture.transaction(
                faultInjector: failShortcutOnce(at: .previousShortcutMoved)
            ).converge(transactionID: fixture.firstID)
        }

        let candidate = fixture.candidate(id: fixture.firstID)
        try FileManager.default.removeItem(at: candidate)
        let foreignCandidate = Data("foreign-candidate".utf8)
        try foreignCandidate.write(to: candidate)

        let recovery = try fixture.transaction().recover()
        #expect(recovery == .init(installedShortcut: false))
        #expect(try fixture.payload(at: fixture.shortcut) == "restore-me")
        #expect(try Data(contentsOf: candidate) == foreignCandidate)
        #expect(!fixture.journalExists)

        _ = try fixture.transaction().converge(
            transactionID: fixture.secondID
        )
        try fixture.expectCorrectShortcut()
        #expect(try Data(contentsOf: candidate) == foreignCandidate)
        try fixture.expectNoOwnedShortcutArtifacts()
    }

    @Test("root replacement fails closed without touching either directory")
    func rootReplacementFailsClosed() throws {
        let fixture = try ShortcutFixture()
        defer { fixture.remove() }
        try fixture.makeOwnedApp(at: fixture.shortcut, payload: "original")

        #expect(throws: InjectedShortcutFault.self) {
            _ = try fixture.transaction(
                faultInjector: failShortcutOnce(at: .journalPersisted)
            ).converge(transactionID: fixture.firstID)
        }

        let displacedRoot = fixture.home.appendingPathComponent(
            "Applications.displaced",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: fixture.shortcutRoot,
            to: displacedRoot
        )
        try FileManager.default.createDirectory(
            at: fixture.shortcutRoot,
            withIntermediateDirectories: false
        )
        let displacedShortcut = displacedRoot.appendingPathComponent(
            "Darkbloom.app",
            isDirectory: true
        )

        #expect(throws: AppUserShortcutTransaction.TransactionError.self) {
            _ = try fixture.transaction().recover()
        }

        #expect(try fixture.payload(at: displacedShortcut) == "original")
        #expect(!FileManager.default.fileExists(atPath: fixture.shortcut.path))
        #expect(fixture.journalExists)
    }

    @Test("authorized cleanup rejects a replaced backup inode")
    func authorizedCleanupRejectsReplacement() throws {
        let fixture = try ShortcutFixture()
        defer { fixture.remove() }
        try fixture.makeOwnedApp(at: fixture.shortcut, payload: "original")

        #expect(throws: InjectedShortcutFault.self) {
            _ = try fixture.transaction(
                faultInjector: failShortcutOnce(at: .backupRemovalAuthorized)
            ).converge(transactionID: fixture.firstID)
        }

        let backup = fixture.backup(id: fixture.firstID)
        let displaced = fixture.root.appendingPathComponent(
            "displaced-owned.app",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: backup, to: displaced)
        let replacement = Data("foreign-replacement".utf8)
        try replacement.write(to: backup)

        #expect(throws: AppUserShortcutTransaction.TransactionError.self) {
            _ = try fixture.transaction().recover()
        }

        #expect(try Data(contentsOf: backup) == replacement)
        #expect(try fixture.payload(at: displaced) == "original")
        try fixture.expectCorrectShortcut()
        #expect(fixture.journalExists)
    }

    @Test("stale restoration revalidates ownership before rename")
    func staleRestorationRevalidatesOwnership() throws {
        let fixture = try ShortcutFixture()
        defer { fixture.remove() }
        let backup = fixture.backup(id: fixture.firstID)
        try fixture.makeOwnedApp(at: backup, payload: "recorded-owned")

        #expect(throws: InjectedShortcutFault.self) {
            _ = try fixture.transaction(
                faultInjector: failShortcutOnce(at: .journalPersisted)
            ).converge(transactionID: fixture.secondID)
        }

        #expect(throws: AppUserShortcutTransaction.TransactionError.self) {
            _ = try fixture.transaction(isOwnedApp: { _ in false }).recover()
        }

        #expect(try fixture.payload(at: backup) == "recorded-owned")
        #expect(!FileManager.default.fileExists(atPath: fixture.shortcut.path))
        #expect(fixture.journalExists)
    }
}

private let ownedReplacementFaultPoints: [
    AppUserShortcutTransaction.FaultPoint
] = [
    .candidatePrepared,
    .journalPersisted,
    .previousShortcutMoved,
    .previousShortcutMoveRecorded,
    .candidateShortcutMoved,
    .candidateShortcutMoveRecorded,
    .backupRemovalAuthorized,
    .backupRemoved,
    .backupRemovalRecorded,
    .journalRemoved,
]

private let freshShortcutFaultPoints: [
    AppUserShortcutTransaction.FaultPoint
] = [
    .candidatePrepared,
    .journalPersisted,
    .previousShortcutMoveRecorded,
    .candidateShortcutMoved,
    .candidateShortcutMoveRecorded,
    .backupRemovalRecorded,
    .journalRemoved,
]

private let staleRestoreFaultPoints: [
    AppUserShortcutTransaction.FaultPoint
] = [
    .journalPersisted,
    .staleBackupRestored,
    .staleBackupRestoreRecorded,
    .journalRemoved,
]

private let staleRetirementFaultPoints: [
    AppUserShortcutTransaction.FaultPoint
] = [
    .journalPersisted,
    .backupRemovalAuthorized,
    .backupRemoved,
    .backupRemovalRecorded,
    .journalRemoved,
]

private struct InjectedShortcutFault: Error {}

private func failShortcutOnce(
    at target: AppUserShortcutTransaction.FaultPoint
) -> (AppUserShortcutTransaction.FaultPoint) throws -> Void {
    var hasFailed = false
    return { point in
        guard point == target, !hasFailed else { return }
        hasFailed = true
        throw InjectedShortcutFault()
    }
}

private struct ShortcutFixture {
    let root: URL
    let home: URL

    let firstID = "00000000-0000-0000-0000-000000000001"
    let secondID = "00000000-0000-0000-0000-000000000002"
    let thirdID = "00000000-0000-0000-0000-000000000003"

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "app-user-shortcut-\(UUID().uuidString)",
            isDirectory: true
        )
        home = root.appendingPathComponent("Home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: installRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: shortcutRoot,
            withIntermediateDirectories: true
        )
        try makeOwnedApp(at: managedApp, payload: "managed")
    }

    var installRoot: URL {
        home.appendingPathComponent(".darkbloom", isDirectory: true)
    }

    var managedApp: URL {
        installRoot.appendingPathComponent("Darkbloom.app", isDirectory: true)
    }

    var shortcutRoot: URL {
        home.appendingPathComponent("Applications", isDirectory: true)
    }

    var shortcut: URL {
        shortcutRoot.appendingPathComponent("Darkbloom.app", isDirectory: true)
    }

    var journal: URL {
        installRoot.appendingPathComponent(".app-relocation-transaction.json")
    }

    var journalExists: Bool {
        FileManager.default.fileExists(atPath: journal.path)
    }

    func backup(id: String) -> URL {
        shortcutRoot.appendingPathComponent(
            ".Darkbloom.app.shortcut-backup-\(id)",
            isDirectory: true
        )
    }

    func candidate(id: String) -> URL {
        shortcutRoot.appendingPathComponent(
            ".Darkbloom.app.shortcut-\(id)"
        )
    }

    func transaction(
        isOwnedApp: ((URL) -> Bool)? = nil,
        faultInjector:
            @escaping (AppUserShortcutTransaction.FaultPoint) throws -> Void = { _ in }
    ) -> AppUserShortcutTransaction {
        AppUserShortcutTransaction(
            installRoot: installRoot,
            homeDirectory: home,
            fileManager: .default,
            isOwnedApp: isOwnedApp ?? self.isOwnedApp,
            faultInjector: faultInjector
        )
    }

    func makeOwnedApp(at url: URL, payload: String) throws {
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data(payload.utf8).write(
            to: url.appendingPathComponent("Contents/owned-marker")
        )
    }

    func makeShortcut() throws {
        try FileManager.default.createSymbolicLink(
            atPath: shortcut.path,
            withDestinationPath: managedApp.path
        )
    }

    func isOwnedApp(_ url: URL) -> Bool {
        guard let type = try? FileManager.default.attributesOfItem(
            atPath: url.path
        )[.type] as? FileAttributeType,
              type == .typeDirectory
        else {
            return false
        }
        return FileManager.default.fileExists(
            atPath: url.appendingPathComponent("Contents/owned-marker").path
        )
    }

    func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type]
            as? FileAttributeType) == .typeSymbolicLink
    }

    func payload(at url: URL) throws -> String {
        try String(
            contentsOf: url.appendingPathComponent("Contents/owned-marker"),
            encoding: .utf8
        )
    }

    func expectCorrectShortcut() throws {
        #expect(isSymlink(shortcut))
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: shortcut.path
            ) == managedApp.path
        )
    }

    func expectNoOwnedShortcutArtifacts() throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: shortcutRoot,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(".Darkbloom.app.shortcut-")
        }
        #expect(!entries.contains(where: isOwnedApp))
        #expect(!entries.contains {
            (try? FileManager.default.destinationOfSymbolicLink(
                atPath: $0.path
            )) == managedApp.path
        })
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
