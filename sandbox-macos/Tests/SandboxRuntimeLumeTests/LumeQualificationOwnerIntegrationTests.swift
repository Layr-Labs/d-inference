import Foundation
import SandboxCore
import SandboxGuestProtocol
import SandboxRuntime
@testable import SandboxRuntimeLume
@testable import DarkbloomSandboxDaemon
import XCTest

/// Runs the real owner recovery against real capacity/ownership files and the
/// bounded native subprocess fixture. No guest package or VM boot is simulated
/// as successful qualification.
final class LumeQualificationOwnerIntegrationTests: XCTestCase {
    func testCompletedPublicationReplaysReadOnlyButSavedEvidenceCannotPublishAMissingTemplate() async throws {
        let f = try await Fixture(missingRelease: false); defer { f.base.remove() }
        let allocated = try f.reserve()
        try await f.base.runtime.deleteAndRelease(scope: allocated.scope, name: f.intent.cloneName)
        let cloneID = UUID()
        let clone: [String: Any] = ["qualificationID": f.intent.qualificationID.uuidString,
            "cloneInstallationID": cloneID.uuidString, "materialsInstanceID": cloneID.uuidString]
        let checks: [String: Any] = ["clone": clone, "initialBootID": UUID().uuidString, "restartedBootID": UUID().uuidString,
            "markerSHA256": BaseGuestRelease.digest(GuestQualificationProtocol.marker(qualificationID: f.intent.qualificationID, cloneInstallationID: cloneID))]
        for (name, object) in [("clone.json", clone), ("checks.json", checks)] {
            let path = f.directory.appendingPathComponent(name)
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
        let cleanup = SandboxGuestQualificationCleanup(cloneInstallationID: cloneID, materialsInstanceID: cloneID,
            cloneRemoved: true, materialsRemoved: true, capacityReleased: true, sourceStoppedReverified: true, sourceUnchangedReverified: true)
        let evidence = SandboxGuestNativeChecks(authenticatedGuest: true, tenantIdentity: true, commandExecution: true,
            workspaceRoundTrip: true, protectedPathDenied: true, controlDiskDenied: true, restart: true)
        let record = SandboxGuestTemplateReceipt(accountless: .init(installation: f.intent.collection.installation,
            qualification: .init(qualificationID: f.intent.qualificationID, source: f.base.source,
                payload: f.intent.collection.installation.payload, cloneName: f.intent.cloneName,
                cloneInstallationID: cloneID, checks: evidence, cleanup: cleanup)))
        do {
            let journal = try f.journal(); try journal.recordLease(allocated); try journal.recordReady(record)
        }
        // Synthetic historical records do not authorize a new publication.
        let missing = try await f.owner().run()
        XCTAssertEqual(missing.phase, .qualificationAborted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.path(SandboxGuestTemplateReceipt.fileName).path))
        // Model a publication completed before process loss. Recovery may read
        // this exact file, but still performs no guest check or template write.
        try f.base.write(record, name: SandboxGuestTemplateReceipt.fileName)
        try LumeInstallerBootClaim.publish(f.intent.permit.request(), name: f.base.source.name, storage: f.base.vm.storage)
        let before = try Data(contentsOf: f.base.path(SandboxGuestTemplateReceipt.fileName))
        let replay = try await f.owner().run()
        XCTAssertEqual(replay.phase, .templateQualified); XCTAssertTrue(replay.qualified); XCTAssertTrue(replay.replayed)
        XCTAssertEqual(try Data(contentsOf: f.base.path(SandboxGuestTemplateReceipt.fileName)), before)
        XCTAssertTrue(try f.base.arbiter.snapshot().leases.isEmpty)
    }

    func testRecoversAllocationBeforeLeaseJournalAndDoesNotRequireGuestPackage() async throws {
        let f = try await Fixture(); defer { f.base.remove() }
        let allocated = try f.reserve()
        let first = try await f.owner().run()
        XCTAssertEqual(first.phase, .qualificationAborted); XCTAssertFalse(first.qualified)
        XCTAssertNil(first.installed)
        XCTAssertEqual(DaemonCLIError.qualificationIncomplete.exitCode, 75)
        XCTAssertTrue(try f.base.arbiter.deletionConfirmed(scope: allocated.scope, virtualMachineName: f.intent.cloneName))
        XCTAssertTrue(try f.base.arbiter.snapshot().leases.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.vm.createStarted.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.path(SandboxGuestTemplateReceipt.fileName).path))
        let second = try await f.owner().run()
        XCTAssertEqual(second.phase, .qualificationAborted); XCTAssertTrue(second.replayed)
        XCTAssertTrue(try f.base.arbiter.snapshot().leases.isEmpty)
    }

    func testUnknownSameNameDirectoryRetainsAllocationAndData() async throws {
        let f = try await Fixture(); defer { f.base.remove() }
        let allocated = try f.reserve(), clone = f.base.vm.storage.appendingPathComponent(f.intent.cloneName)
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let sentinel = clone.appendingPathComponent("foreign.txt")
        try Data("preserve".utf8).write(to: sentinel)
        do { _ = try await f.owner().run(); XCTFail("unknown VM directory adopted") } catch {}
        XCTAssertEqual(try f.base.arbiter.snapshot().leases, [allocated])
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("aborted.json").path))
    }

    func testJournalCannotShareVMOrCapacityNamespaces() async throws {
        let f = try await Fixture(); defer { f.base.remove() }
        for path in [f.base.vm.storage, f.base.vm.storage.appendingPathComponent("journal"), f.capacity,
                     f.capacity.appendingPathComponent("journal"), f.base.vm.directory] {
            XCTAssertThrowsError(try AccountlessQualificationRecovery.requireSeparateJournal(path, storage: f.base.vm.storage, capacity: f.capacity))
        }
        XCTAssertNoThrow(try AccountlessQualificationRecovery.requireSeparateJournal(f.directory, storage: f.base.vm.storage, capacity: f.capacity))
        XCTAssertThrowsError(try AccountlessQualificationRecovery.requireSeparateJournal(f.directory,
            storage: f.base.vm.storage, capacity: f.capacity, release: f.directory))
    }

    private struct Fixture {
        let base: LumeQualificationFixture
        let directory: URL
        let capacity: URL
        let release: URL
        let intent: AccountlessQualificationIntent

        init(missingRelease: Bool = true) async throws {
            base = try await LumeQualificationFixture()
            directory = base.vm.directory.appendingPathComponent("qualification")
            capacity = base.vm.directory.appendingPathComponent("capacity")
            release = missingRelease ? base.vm.directory.appendingPathComponent("missing-guest-package") : base.release.configuration.releaseDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            do {
                let authorization = try base.arbiter.authorizeMutation(scope: base.lease.scope, virtualMachineName: base.specification.name, operation: .delete)
                try base.arbiter.release(scope: base.lease.scope, holding: authorization)
            }
            let raw = try Data(contentsOf: base.path(LumeInstalledCandidateCheckpoint.reservationFileName))
            let candidate = try JSONDecoder().decode(AccountlessBaseCandidateRecord.self, from: raw)
            let disk = try LumeInstalledCandidateStore(name: base.source.name, storage: base.vm.storage).diskIdentity()
            let permit = AccountlessBootPermit(schemaVersion: 1, hostID: UUID(),
                hostUser: .init(recordName: "operator", uid: 501, primaryGID: 20, generatedUID: UUID().uuidString, homeDirectory: "/Users/operator"),
                hostIdentityFile: "/Library/Darkbloom/host.json", storage: base.vm.storage.path, runtime: base.vm.executable.path,
                runtimeSHA256: LumeInstalledCandidateStore.digest(try Data(contentsOf: base.vm.executable)), reservationData: raw,
                stagedDisk: disk, stagingSnapshotSHA256: String(repeating: "a", count: 64), maximumBootSeconds: 300)
            let installation = try JSONDecoder().decode(SandboxAccountlessInstallationReceipt.self,
                from: Data(contentsOf: base.path(LumeInstalledCandidateCheckpoint.installationFileName)))
            let originalCleanup = try JSONDecoder().decode(LumeCandidateInstallationCleanup.self,
                from: Data(contentsOf: base.path(LumeInstalledCandidateCheckpoint.cleanupFileName)))
            let cleanup = LumeCandidateInstallationCleanup(candidateID: candidate.candidateID, bootstrapAttemptID: candidate.bootstrapAttemptID,
                source: candidate.source, installationReceiptSHA256: BaseGuestRelease.digest(try AccountlessJournalJSON.encode(installation)),
                disk: originalCleanup.disk, temporaryJobRemoved: true, temporaryPayloadRemoved: true, fullyDetached: true, sourceStoppedVerified: true)
            let collection = try AccountlessCollectionRecord(schemaVersion: 1, permitSHA256: BaseGuestRelease.digest(permit.encoded()),
                collectionIntentSHA256: String(repeating: "b", count: 64), guestResultSHA256: String(repeating: "c", count: 64),
                installation: installation, cleanup: cleanup)
            XCTAssertEqual(candidate.candidateID, base.candidateID)
            let journal = try AccountlessQualificationJournal(directory: directory, permit: permit, collection: collection,
                capacityDirectory: capacity, guestReleaseDirectory: release, guestReleaseSHA256: String(repeating: "d", count: 64), now: base.clock.now())
            intent = journal.intent
        }
        func reserve() throws -> SandboxCapacityLease {
            try base.arbiter.reserve(sandboxID: intent.sandboxID, generation: intent.generation, virtualMachineName: intent.cloneName,
                resources: base.specification.resources, bootDiskBytes: base.specification.diskBytes, expiresAt: intent.expiresAt)
        }
        func journal() throws -> AccountlessQualificationJournal {
            try .init(directory: directory, permit: intent.permit, collection: intent.collection, capacityDirectory: capacity,
                guestReleaseDirectory: release, guestReleaseSHA256: intent.guestReleaseSHA256)
        }
        func owner() throws -> AccountlessQualificationOwner {
            let configuration = try LumeRuntimeConfiguration(executable: base.vm.executable, storageDirectory: base.vm.storage,
                commandTimeoutSeconds: 5, createTimeoutSeconds: 5, trustPolicy: .developmentAdHoc,
                isolatedGuest: .init(releaseDirectory: release, developmentAdHoc: true), hostRuntimeLease: base.authority)
            return try .init(directory: directory, permit: intent.permit, collection: intent.collection, capacityDirectory: capacity,
                guestReleaseDirectory: release, configuration: configuration, arbiter: base.arbiter)
        }
    }
}
