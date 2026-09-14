import Darwin
import Foundation
import SandboxCore
import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

final class LumeQualificationCapabilityTests: XCTestCase {
    func testExactInstalledSourceAndLeaseGrantDoNotCreateOrPublishReadiness() async throws {
        let f = try await LumeQualificationFixture(); defer { f.remove() }
        let before = try f.arbiter.snapshot().leases
        do {
            try await f.runtime.create(scope: f.lease.scope, specification: f.specification)
            XCTFail("normal clone requires full readiness, even with installed candidate evidence")
        } catch let error as SandboxRuntimeError {
            guard case .unsupported(let message) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(message.contains("stopped-state receipt"))
        }
        let capability = try await f.issue()
        XCTAssertEqual(capability.lease, f.lease)
        XCTAssertEqual(capability.checkpoint.source, f.source)
        try await f.runtime.revalidateQualificationCloneCapability(capability)
        XCTAssertEqual(try f.arbiter.snapshot().leases, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.vm.createStarted.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.vm.storage.appendingPathComponent(f.specification.name).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path(SandboxGuestTemplateReceipt.fileName).path))
        XCTAssertThrowsError(try LumeBaseCandidateOperationGuard(name: f.source.name, storage: f.vm.storage))
    }

    func testPartialLegacyWrongAttemptAndFailedCleanupRemainRejectedWithMatchingHashes() async throws {
        let mutations: [(String, String, Any)] = [
            (LumeInstalledCandidateCheckpoint.fileName, "schemaVersion", 99),
            (LumeInstalledCandidateCheckpoint.fileName, "phase", "qualified"),
            (LumeInstalledCandidateCheckpoint.reservationFileName, "phase", "installationComplete"),
            (LumeInstalledCandidateCheckpoint.reservationFileName, "candidateID", UUID().uuidString),
            (LumeInstalledCandidateCheckpoint.installationFileName, "rootJobID", UUID().uuidString),
            (LumeInstalledCandidateCheckpoint.installationFileName, "phase", "rootJobStarted"),
            (LumeInstalledCandidateCheckpoint.installationFileName, "bootstrapRetired", false),
            (LumeInstalledCandidateCheckpoint.installationFileName, "installerExitCode", 70),
            (LumeInstalledCandidateCheckpoint.cleanupFileName, "fullyDetached", false),
            (LumeInstalledCandidateCheckpoint.cleanupFileName, "temporaryPayloadRemoved", false),
            (LumeInstalledCandidateCheckpoint.cleanupFileName, "bootstrapAttemptID", UUID().uuidString),
        ]
        for (name, key, value) in mutations {
            let f = try await LumeQualificationFixture(); defer { f.remove() }
            try f.mutate(name, refreshHashes: true) { $0[key] = value }
            await rejects { _ = try await f.issue() }
        }
    }

    func testCheckpointAndActualDiskMustRemainBound() async throws {
        for mutation in ["missing", "hash", "bytes", "inode", "materials", "running", "ready"] {
            let f = try await LumeQualificationFixture(); defer { f.remove() }
            switch mutation {
            case "missing": try FileManager.default.removeItem(at: f.path(LumeInstalledCandidateCheckpoint.fileName))
            case "hash": try f.mutate(LumeInstalledCandidateCheckpoint.installationFileName) { $0["guestOperatingSystemVersion"] = "26.1" }
            case "bytes":
                let file = try FileHandle(forWritingTo: f.path("disk.img")); try file.write(contentsOf: Data([1])); try file.close()
            case "inode":
                let disk = f.path("disk.img"), other = f.path("replacement.img")
                XCTAssertTrue(FileManager.default.createFile(atPath: other.path, contents: nil,
                    attributes: [.posixPermissions: 0o600]))
                let file = try FileHandle(forWritingTo: other)
                try file.truncate(atOffset: f.specification.diskBytes); try file.close()
                try FileManager.default.removeItem(at: disk); try FileManager.default.moveItem(at: other, to: disk)
            case "materials": try FileManager.default.createDirectory(at: f.path(".darkbloom-guest"), withIntermediateDirectories: false)
            case "running": try Data("running\n".utf8).write(to: f.vm.state)
            default: try Data("{}".utf8).write(to: f.path(SandboxGuestTemplateReceipt.fileName))
            }
            await rejects { _ = try await f.issue() }
        }
    }

    func testPrivateEvidenceRejectsSharingSymlinksAndHardlinks() async throws {
        for mutation in ["mode", "symlink", "hardlink"] {
            let f = try await LumeQualificationFixture(); defer { f.remove() }
            let file = f.path(LumeInstalledCandidateCheckpoint.installationFileName), other = f.path("other-receipt")
            switch mutation {
            case "mode": XCTAssertEqual(chmod(file.path, 0o644), 0)
            case "symlink":
                try FileManager.default.moveItem(at: file, to: other)
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
            default: XCTAssertEqual(link(file.path, other.path), 0)
            }
            await rejects { _ = try await f.issue() }
        }
    }

    func testCapabilityRejectsAnotherRuntimeAndChangedFenceExpiryModeOrSource() async throws {
        for mutation in ["runtime", "expiry", "fence", "mode", "source"] {
            let f = try await LumeQualificationFixture(); defer { f.remove() }
            let capability = try await f.issue()
            switch mutation {
            case "runtime":
                let another = try LumeLeaseFencedVirtualMachineRuntime(configuration: f.configuration, capacityArbiter: f.arbiter)
                await rejects { try await another.revalidateQualificationCloneCapability(capability) }
                continue
            case "expiry": f.clock.set(f.lease.expiresAt)
            case "fence":
                _ = try f.arbiter.renew(scope: f.lease.scope, expiresAt: f.lease.expiresAt.addingTimeInterval(1))
            case "mode": _ = try f.arbiter.setMode(.draining)
            default:
                try f.mutate(LumeInstalledCandidateCheckpoint.fileName) { $0["candidateID"] = UUID().uuidString }
            }
            await rejects { try await f.runtime.revalidateQualificationCloneCapability(capability) }
        }
    }

    func testDifferentDestinationOrCandidateCannotBorrowLease() async throws {
        let f = try await LumeQualificationFixture(); defer { f.remove() }
        let other = try SandboxVirtualMachineSpecification(name: "other-clone", resources: f.specification.resources,
            imageSource: f.specification.imageSource, diskBytes: f.specification.diskBytes)
        await rejects { _ = try await f.runtime.qualificationCloneCapability(candidateID: f.candidateID,
            qualificationID: f.qualificationID, scope: f.lease.scope, specification: other) }
        await rejects { _ = try await f.runtime.qualificationCloneCapability(candidateID: UUID(),
            qualificationID: f.qualificationID, scope: f.lease.scope, specification: f.specification) }
        await rejects { _ = try await f.runtime.qualificationCloneCapability(candidateID: f.candidateID,
            qualificationID: f.attemptID, scope: f.lease.scope, specification: f.specification) }
    }

    func testObservedResourcesMustMatchActualSourceOwnership() async throws {
        let f = try await LumeQualificationFixture(ownedCPUCount: 8); defer { f.remove() }
        // All four proof files consistently bind this eight-CPU ownership
        // record, but the live source and requested lease both report four.
        await rejects { _ = try await f.issue() }
    }

    func testSameNamedDirectoryReplacementCannotReuseRetainedCapability() async throws {
        let f = try await LumeQualificationFixture(); defer { f.remove() }
        let capability = try await f.issue()
        let moved = f.vm.storage.appendingPathComponent("original-candidate")
        try FileManager.default.moveItem(at: f.vm.virtualMachineDirectory, to: moved)
        try FileManager.default.createDirectory(at: f.vm.virtualMachineDirectory,
            withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // Even the same exact ownership/proof bytes must not rebind the held
        // private directory descriptor to a replacement namespace.
        for name in [LumeVirtualMachineOwnership.fileName, LumeInstalledCandidateCheckpoint.fileName,
                     LumeInstalledCandidateCheckpoint.reservationFileName,
                     LumeInstalledCandidateCheckpoint.installationFileName, LumeInstalledCandidateCheckpoint.cleanupFileName] {
            try FileManager.default.copyItem(at: moved.appendingPathComponent(name), to: f.path(name))
        }
        await rejects { try await f.runtime.revalidateQualificationCloneCapability(capability) }
    }

    func testSourceChangeAndCancellationDuringObservationCannotIssueCapability() async throws {
        for cancel in [false, true] {
            let f = try await LumeQualificationFixture(); defer { f.remove() }
            try Data("block-first-list\n".utf8).write(to: f.vm.behavior)
            let task = Task { try await f.issue() }
            do {
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while !FileManager.default.fileExists(atPath: f.vm.listStarted.path), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard FileManager.default.fileExists(atPath: f.vm.listStarted.path) else { throw POSIXError(.ETIMEDOUT) }
                if cancel { task.cancel() }
                else {
                    let disk = try FileHandle(forWritingTo: f.path("disk.img"))
                    try disk.write(contentsOf: Data([1])); try disk.close()
                }
                try Data().write(to: f.vm.listContinue)
                await rejects { _ = try await task.value }
            } catch {
                task.cancel(); _ = await task.result
                throw error
            }
            XCTAssertNoThrow(try LumeBaseCandidateOperationGuard(name: f.source.name, storage: f.vm.storage))
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.vm.storage.appendingPathComponent(f.specification.name).path))
            XCTAssertEqual(try f.arbiter.snapshot().leases, [f.lease])
        }
    }

    private func rejects(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("invalid qualification authority was accepted", file: file, line: line) }
        catch {}
    }
}
