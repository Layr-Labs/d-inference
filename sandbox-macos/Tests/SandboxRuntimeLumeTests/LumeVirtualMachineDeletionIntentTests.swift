import Darwin
import Foundation
import SandboxCore
import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

final class LumeVirtualMachineDeletionIntentTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> Fixture {
        let fixture = try Fixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.root) }
        return fixture
    }

    func testIsolatedJournalIsDeletedWithItsVMAndUnrelatedGlobalJournalIsUntouched() throws {
        let f = try fixture()
        let isolated = LumeGuestCommandJournal(workspace: f.workspace, ownedVirtualMachineDirectory: f.vm)
        let request = try f.request()
        try f.complete(journal: isolated, request: request, installationID: f.installationID, output: "tenant secret")
        let unrelatedID = UUID(), legacy = LumeGuestCommandJournal(workspace: f.workspace)
        try f.complete(journal: legacy, request: request, installationID: unrelatedID, output: "unrelated")
        let intent = try f.intent()
        try intent.removeOwnedTree(workspace: f.workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.vm.path))
        XCTAssertEqual(isolated.replay(installationID: f.installationID, request: request), .indeterminate)
        guard case .completed(let result) = legacy.replay(installationID: unrelatedID, request: request) else {
            return XCTFail("another installation journal must survive")
        }
        XCTAssertEqual(result.standardOutput, Data("unrelated".utf8))
        XCTAssertNotNil(try LumeVirtualMachineDeletionIntent.load(workspace: f.workspace, name: f.name))
    }

    func testCrashAfterCommandClaimRemovalCannotReexecuteAndResumesUsingExternalIdentity() throws {
        let f = try fixture(), request = try f.request()
        let journal = LumeGuestCommandJournal(workspace: f.workspace, ownedVirtualMachineDirectory: f.vm)
        try f.complete(journal: journal, request: request, installationID: f.installationID, output: "secret")
        let intent = try f.intent(), commandName = request.idempotencyKey.uuidString.lowercased()
        XCTAssertThrowsError(try intent.removeOwnedTree(workspace: f.workspace,
            hooks: .init(afterEntryRemoval: { if $0.hasSuffix(commandName) { throw Fault.crash } })))
        XCTAssertEqual(journal.replay(installationID: f.installationID, request: request), .unclaimed)
        XCTAssertThrowsError(try LumeVirtualMachineDeletionIntent.requireAbsent(workspace: f.workspace, name: f.name))
        let restarted = try XCTUnwrap(LumeVirtualMachineDeletionIntent.load(workspace: f.workspace, name: f.name))
        XCTAssertEqual(restarted.installationID, f.installationID)
        try restarted.removeOwnedTree(workspace: f.workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.vm.path))
        try restarted.clear(workspace: f.workspace)
        XCTAssertNil(try LumeVirtualMachineDeletionIntent.load(workspace: f.workspace, name: f.name))
    }

    func testCrashAfterWholeDirectoryRemovalRetainsIntentUntilDurableRetryCompletes() throws {
        let f = try fixture(), intent = try f.intent()
        XCTAssertThrowsError(try intent.removeOwnedTree(workspace: f.workspace,
            hooks: .init(afterDirectoryRemoval: { throw Fault.crash })))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.vm.path))
        let restarted = try XCTUnwrap(LumeVirtualMachineDeletionIntent.load(workspace: f.workspace, name: f.name))
        try restarted.removeOwnedTree(workspace: f.workspace)
        XCTAssertNotNil(try LumeVirtualMachineDeletionIntent.load(workspace: f.workspace, name: f.name))
        try restarted.clear(workspace: f.workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.vm.path))
    }

    func testFailedIntentDurabilityConfirmationPreservesCommandClaimsAndAllVMData() throws {
        let f = try fixture(), request = try f.request()
        let journal = LumeGuestCommandJournal(workspace: f.workspace, ownedVirtualMachineDirectory: f.vm)
        try f.complete(journal: journal, request: request, installationID: f.installationID, output: "secret")
        let intent = try f.intent()
        XCTAssertThrowsError(try intent.removeOwnedTree(workspace: f.workspace,
            hooks: .init(synchronizeIntentDirectory: { _ in throw Fault.crash })))
        XCTAssertEqual(try Data(contentsOf: f.vm.appendingPathComponent("disk.img")), Data("disk".utf8))
        guard case .completed(let result) = journal.replay(installationID: f.installationID, request: request) else {
            return XCTFail("failed intent synchronization must preserve the command replay")
        }
        XCTAssertEqual(result.standardOutput, Data("secret".utf8))
        try intent.removeOwnedTree(workspace: f.workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.vm.path))
    }

    func testDifferentDirectoryAtSameNameIsNeverErased() throws {
        let f = try fixture(), intent = try f.intent()
        let old = f.root.appendingPathComponent("original")
        try FileManager.default.moveItem(at: f.vm, to: old)
        try FileManager.default.createDirectory(at: f.vm, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let other = f.vm.appendingPathComponent("unrelated")
        try Data("preserve".utf8).write(to: other)
        XCTAssertThrowsError(try intent.removeOwnedTree(workspace: f.workspace))
        XCTAssertEqual(try Data(contentsOf: other), Data("preserve".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    }

    func testSymlinksAndHardLinksRetainIntentAndDoNotTouchTheirTargets() throws {
        for hardLink in [false, true] {
            let f = try fixture(), intent = try f.intent()
            let target = f.root.appendingPathComponent("unrelated")
            try Data("preserve".utf8).write(to: target)
            let entry = f.vm.appendingPathComponent("link")
            if hardLink { XCTAssertEqual(link(target.path, entry.path), 0) }
            else { try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: target) }
            XCTAssertThrowsError(try intent.removeOwnedTree(workspace: f.workspace))
            XCTAssertEqual(try Data(contentsOf: target), Data("preserve".utf8))
            XCTAssertNotNil(try LumeVirtualMachineDeletionIntent.load(workspace: f.workspace, name: f.name))
        }
    }

    func testCleanupAllowsCurrentFenceForSameGenerationAndRejectsOtherGeneration() throws {
        let f = try fixture(), intent = try f.intent()
        let newerFence = SandboxOperationScope(sandboxID: f.scope.sandboxID, generation: f.scope.generation,
            fencingToken: SandboxFencingToken(rawValue: 2)!)
        XCTAssertNoThrow(try intent.requireMatching(name: f.name, scope: newerFence))
        let other = SandboxOperationScope(sandboxID: f.scope.sandboxID, generation: SandboxGeneration(rawValue: 2)!,
            fencingToken: SandboxFencingToken(rawValue: 2)!)
        XCTAssertThrowsError(try intent.requireMatching(name: f.name, scope: other))
    }

    private enum Fault: Error { case crash }
    private struct Fixture {
        let root: URL
        let vm: URL
        let name = "owned-vm"
        let workspace: LumeRuntimeWorkspace
        let installationID = UUID()
        let scope = SandboxOperationScope(sandboxID: SandboxID(), generation: SandboxGeneration(rawValue: 1)!, fencingToken: SandboxFencingToken(rawValue: 1)!)
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("deletion-intent-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            workspace = LumeRuntimeWorkspace(storageDirectory: root)
            try workspace.prepare()
            vm = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data("disk".utf8).write(to: vm.appendingPathComponent("disk.img"))
            try Data("config".utf8).write(to: vm.appendingPathComponent("config.json"))
        }
        func intent() throws -> LumeVirtualMachineDeletionIntent {
            try LumeVirtualMachineDeletionIntent.persist(workspace: workspace, name: name, scope: scope, installationID: installationID)
        }
        func request() throws -> SandboxGuestCommandRequest {
            try SandboxGuestCommandRequest(idempotencyKey: UUID(), executable: "/usr/bin/printf", arguments: ["payload"])
        }
        func complete(journal: LumeGuestCommandJournal, request: SandboxGuestCommandRequest, installationID: UUID, output: String) throws {
            let claim = try journal.claim(installationID: installationID, request: request)
            try claim.complete(envelope: LumeGuestCommandResultDecoder.encode(SandboxGuestCommandResult(exitCode: 0,
                standardOutput: Data(output.utf8), standardError: Data())))
        }
    }
}
