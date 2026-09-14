import Foundation
import SandboxCore
import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

final class LumeQualificationCloneTests: XCTestCase {
    func testCloneUsesInstalledCandidateWithoutPublishingReadiness() async throws {
        let f = try await LumeQualificationFixture(); defer { f.remove() }
        let capability = try await f.issue()
        try await f.runtime.createQualificationClone(capability)
        let clone = try await f.runtime.inspect(scope: f.lease.scope, name: f.specification.name)
        XCTAssertEqual(clone?.state, .stopped)
        let ownership = try LumeVirtualMachineOwnership.requireOwned(name: f.specification.name,
            owner: .init(operationScope: f.lease.scope), in: f.vm.storage)
        XCTAssertNotEqual(ownership.installationID, f.source.installationID)
        XCTAssertTrue(LumeVirtualMachineOwnership.matches(specification: f.specification,
            owner: .init(operationScope: f.lease.scope), in: f.vm.storage))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path(SandboxGuestTemplateReceipt.fileName).path))
        XCTAssertEqual(try f.arbiter.snapshot().leases, [f.lease])
        XCTAssertThrowsError(try LumeBaseCandidateOperationGuard(name: f.source.name, storage: f.vm.storage))
    }

    func testConsumedCapabilityCannotRecreateADeletedDestination() async throws {
        let f = try await LumeQualificationFixture(); defer { f.remove() }
        let capability = try await f.issue()
        try await f.runtime.createQualificationClone(capability)
        try FileManager.default.removeItem(at: destination(f))
        try FileManager.default.removeItem(at: f.vm.createStarted)
        await rejects { try await f.runtime.createQualificationClone(capability) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.vm.createStarted.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination(f).path))
    }

    func testChangedAuthorityCannotTriggerNativeClone() async throws {
        for mutation in ["expiry", "renewal", "source", "destination", "runtime"] {
            let f = try await LumeQualificationFixture(); defer { f.remove() }
            let capability = try await f.issue()
            switch mutation {
            case "expiry": f.clock.set(f.lease.expiresAt)
            case "renewal": _ = try f.arbiter.renew(scope: f.lease.scope, expiresAt: f.lease.expiresAt.addingTimeInterval(1))
            case "source": try f.mutate(LumeInstalledCandidateCheckpoint.fileName) { $0["candidateID"] = UUID().uuidString }
            case "destination": try FileManager.default.createDirectory(at: destination(f), withIntermediateDirectories: false)
            default:
                let another = try LumeLeaseFencedVirtualMachineRuntime(configuration: f.configuration, capacityArbiter: f.arbiter)
                await rejects { try await another.createQualificationClone(capability) }
                XCTAssertFalse(FileManager.default.fileExists(atPath: f.vm.createStarted.path))
                continue
            }
            await rejects { try await f.runtime.createQualificationClone(capability) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.vm.createStarted.path), mutation)
            if mutation == "destination" { XCTAssertTrue(FileManager.default.fileExists(atPath: destination(f).path)) }
        }
    }

    func testNativeFailureResourceMismatchOrChangedSourceCleansOnlyDestination() async throws {
        for behavior in ["clone-fails-after-copy", "clone-resource-mismatch", "clone-changes-source"] {
            let f = try await LumeQualificationFixture(cloneBehavior: behavior); defer { f.remove() }
            let capability = try await f.issue()
            await rejects { try await f.runtime.createQualificationClone(capability) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.vm.createStarted.path), behavior)
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.vm.virtualMachineDirectory.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination(f).path))
            XCTAssertEqual(try f.arbiter.snapshot().leases, [f.lease])
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.path(SandboxGuestTemplateReceipt.fileName).path))
        }
    }

    func testExpiryDuringNativeCloneRejectsPublicationAndCleansDestination() async throws {
        let f = try await LumeQualificationFixture(cloneBehavior: "clone-block-after-copy"); defer { f.remove() }
        let capability = try await f.issue()
        let clone = Task { try await f.runtime.createQualificationClone(capability) }
        do {
            try await f.vm.waitForCreateToStart()
            f.clock.set(f.lease.expiresAt)
            try Data().write(to: f.vm.directory.appendingPathComponent("clone-continue"))
            await rejects { try await clone.value }
        } catch {
            clone.cancel(); _ = try? await clone.value; throw error
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination(f).path))
        XCTAssertEqual(try f.arbiter.snapshot().leases.count, 1)
    }

    func testCancellationAfterNativeCopyCleansDestinationAndConsumesCapability() async throws {
        let f = try await LumeQualificationFixture(cloneBehavior: "clone-block-after-copy"); defer { f.remove() }
        let capability = try await f.issue()
        let clone = Task { try await f.runtime.createQualificationClone(capability) }
        do {
            try await f.vm.waitForCreateToStart()
            clone.cancel()
            await rejects { try await clone.value }
        } catch {
            clone.cancel(); _ = try? await clone.value; throw error
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination(f).path))
        try FileManager.default.removeItem(at: f.vm.createStarted)
        await rejects { try await f.runtime.createQualificationClone(capability) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.vm.createStarted.path))
    }

    func testConcurrentConsumerCannotBorrowAnInProgressClone() async throws {
        let f = try await LumeQualificationFixture(cloneBehavior: "clone-block-after-copy"); defer { f.remove() }
        let capability = try await f.issue()
        let clone = Task { try await f.runtime.createQualificationClone(capability) }
        do {
            try await f.vm.waitForCreateToStart()
            await rejects { try await f.runtime.createQualificationClone(capability) }
            try Data().write(to: f.vm.directory.appendingPathComponent("clone-continue"))
            try await clone.value
        } catch {
            clone.cancel(); _ = try? await clone.value; throw error
        }
        XCTAssertTrue(LumeVirtualMachineOwnership.matches(specification: f.specification,
            owner: .init(operationScope: f.lease.scope), in: f.vm.storage))
    }

    private func destination(_ f: LumeQualificationFixture) -> URL {
        f.vm.storage.appendingPathComponent(f.specification.name)
    }
    private func rejects(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("invalid qualification clone accepted", file: file, line: line) }
        catch {}
    }
}
