import Foundation
import SandboxCore
import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

final class LumeCloneResourceTests: XCTestCase {
    func testRequestedResourcesReplaceInheritedCPUAndMemoryBeforePublication() async throws {
        let f = try await LumeQualificationFixture(); defer { f.remove() }
        let runtime = try f.vm.makeRuntime(commandTimeoutSeconds: 5, hostRuntimeLease: f.authority)
        let resources = try SandboxResourceSpecification(cpuCount: 6,
            memoryBytes: 12 * SandboxResourcePolicy.gibibyte,
            workspaceBytes: 50 * SandboxResourcePolicy.gibibyte, commandTimeoutSeconds: 900)
        let specification = try SandboxVirtualMachineSpecification(name: f.specification.name,
            resources: resources, imageSource: f.specification.imageSource, diskBytes: f.specification.diskBytes)
        try await runtime.create(specification)
        let observed = try await runtime.inspect(name: specification.name)
        XCTAssertEqual(observed?.cpuCount, 6)
        XCTAssertEqual(observed?.memoryBytes, resources.memoryBytes)
        XCTAssertEqual(observed?.diskBytes, specification.diskBytes)
        XCTAssertEqual(observed?.state, .stopped)
        XCTAssertTrue(LumeVirtualMachineOwnership.matches(specification: specification,
            owner: .baseTemplate, in: f.vm.storage))
        let arguments = try String(contentsOf: f.vm.directory.appendingPathComponent("set-arguments"), encoding: .utf8)
        XCTAssertEqual(arguments.split(separator: "\n").map(String.init), ["set", specification.name,
            "--cpu", "6", "--memory", "12884901888B", "--storage", f.vm.storage.path])
        let source = try await runtime.inspect(name: f.source.name)
        XCTAssertEqual(source?.cpuCount, 4)
    }

    func testMatchingResourcesDoNotInvokeSettingsMutation() async throws {
        let f = try await LumeQualificationFixture(); defer { f.remove() }
        let capability = try await f.issue()
        try await f.runtime.createQualificationClone(capability)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.vm.directory.appendingPathComponent("set-arguments").path))
    }

    func testFailedOrIgnoredSettingsChangeCannotPublishWrongResourceOwnership() async throws {
        for behavior in ["clone-set-fails", "clone-set-ignores"] {
            let f = try await LumeQualificationFixture(cloneBehavior: behavior); defer { f.remove() }
            let runtime = try f.vm.makeRuntime(commandTimeoutSeconds: 5, hostRuntimeLease: f.authority)
            let resources = try SandboxResourceSpecification(cpuCount: 6,
                memoryBytes: 12 * SandboxResourcePolicy.gibibyte,
                workspaceBytes: 25 * SandboxResourcePolicy.gibibyte, commandTimeoutSeconds: 900)
            let specification = try SandboxVirtualMachineSpecification(name: f.specification.name,
                resources: resources, imageSource: f.specification.imageSource, diskBytes: f.specification.diskBytes)
            do { try await runtime.create(specification); XCTFail("settings failure must reject creation") }
            catch {}
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.vm.directory.appendingPathComponent("set-arguments").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.vm.storage.appendingPathComponent(specification.name).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.vm.virtualMachineDirectory.path))
        }
    }
}
