import Darwin
import Foundation
import SandboxCore
import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

final class LumeOfflineOperationFenceTests: XCTestCase {
    func testEveryFenceEntryBlocksOrdinaryCreateStartAndDeleteWithoutRemovingState() async throws {
        for kind in ["empty", "malformed", "fifo", "directory", "symlink"] {
            let f = try fixture(), runtime = try f.makeRuntime()
            let fence = f.virtualMachineDirectory.appendingPathComponent(LumeOfflineOperationFence.fileName)
            switch kind {
            case "fifo": XCTAssertEqual(mkfifo(fence.path, 0o600), 0)
            case "directory": try FileManager.default.createDirectory(at: fence, withIntermediateDirectories: false)
            case "symlink": try FileManager.default.createSymbolicLink(at: fence,
                withDestinationURL: f.directory.appendingPathComponent("missing"))
            default: try Data((kind == "empty" ? "" : "{").utf8).write(to: fence)
            }
            let specification = try SandboxVirtualMachineSpecification(name: f.virtualMachineName,
                resources: .macOSSmall(), imageSource: .restoreImage(url: f.restoreImage, unattendedPreset: "tahoe"),
                diskBytes: 100 * SandboxResourcePolicy.gibibyte)
            await rejected { try await runtime.create(specification) }
            await rejected { try await runtime.start(name: f.virtualMachineName) }
            await rejected { try await runtime.delete(name: f.virtualMachineName) }
            var info = stat(); XCTAssertEqual(lstat(fence.path, &info), 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.ownershipMarker.path))
            XCTAssertEqual(try String(contentsOf: f.state, encoding: .utf8), "stopped\n")
        }
    }

    func testCloneSourceFenceBlocksPublicationAndLeavesOtherVMStateAlone() async throws {
        let f = try fixture(), runtime = try f.makeRuntime()
        let fence = f.virtualMachineDirectory.appendingPathComponent(LumeOfflineOperationFence.fileName)
        try Data().write(to: fence)
        let specification = try SandboxVirtualMachineSpecification(name: "uncreated-clone", resources: .macOSSmall(),
            imageSource: .localTemplate(name: f.virtualMachineName), diskBytes: 100 * SandboxResourcePolicy.gibibyte)
        await rejected { try await runtime.create(specification) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.storage.appendingPathComponent(specification.name).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fence.path))
    }

    func testDeletionReplayCannotEraseAnOfflineFenceOrAnyRemainingFiles() throws {
        let f = try fixture(), workspace = LumeRuntimeWorkspace(storageDirectory: f.storage)
        let ownership = try LumeVirtualMachineOwnership.requireOwned(name: f.virtualMachineName, owner: .baseTemplate, in: f.storage)
        let intent = try LumeVirtualMachineDeletionIntent.persist(workspace: workspace, name: f.virtualMachineName,
            scope: nil, installationID: ownership.installationID)
        let disk = f.virtualMachineDirectory.appendingPathComponent("disk.img")
        try Data("preserve disk".utf8).write(to: disk)
        let fence = f.virtualMachineDirectory.appendingPathComponent(LumeOfflineOperationFence.fileName)
        try Data().write(to: fence)
        XCTAssertThrowsError(try intent.removeOwnedTree(workspace: workspace)) {
            XCTAssertTrue(String(describing: $0).contains("offline maintenance"))
        }
        XCTAssertEqual(try String(contentsOf: disk, encoding: .utf8), "preserve disk")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fence.path))
    }

    func testMissingFenceAndMissingDestinationAreAcceptedWithoutCreation() throws {
        let f = try fixture()
        XCTAssertNoThrow(try LumeOfflineOperationFence.requireAbsent(storage: f.storage, name: f.virtualMachineName))
        XCTAssertNoThrow(try LumeOfflineOperationFence.requireAbsent(storage: f.storage, name: "missing-vm"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.storage.appendingPathComponent("missing-vm").path))
    }

    private func fixture() throws -> FakeLumeFixture {
        let f = try FakeLumeFixture(); addTeardownBlock { try f.remove() }; return f
    }
    private func rejected(_ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("offline operation was allowed") }
        catch { XCTAssertTrue(String(describing: error).contains("offline maintenance"), "unexpected error: \(error)") }
    }
}
