import Foundation
import SandboxCore
import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

final class LumeBaseCandidateGuardTests: XCTestCase {
    func testGuardSerializesCandidatePublicationWithNormalBrokerOperations() async throws {
        let fixture = try FakeLumeFixture(initialState: nil)
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()
        let specification = try SandboxVirtualMachineSpecification(name: fixture.virtualMachineName,
            resources: .macOSSmall(), imageSource: .appleRestore(url: fixture.restoreImage),
            diskBytes: 100 * SandboxResourcePolicy.gibibyte)
        try await runtime.create(specification)
        let guardObject = try LumeBaseCandidateOperationGuard(name: fixture.virtualMachineName, storage: fixture.storage)
        XCTAssertEqual(guardObject.source.kind, .appleRestore)
        let stopped = try await runtime.inspect(name: fixture.virtualMachineName)
        XCTAssertEqual(stopped?.state, .stopped)
        do {
            try await runtime.create(specification)
            XCTFail("candidate guard must block a competing broker operation")
        } catch let error as SandboxRuntimeError {
            guard case .operationInProgress = error else { return XCTFail("unexpected error: \(error)") }
        }
        withExtendedLifetime(guardObject) {}
    }

    func testGuardCannotTurnLegacyOwnedBaseIntoRawCandidate() async throws {
        let fixture = try FakeLumeFixture(initialState: nil)
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()
        let specification = try SandboxVirtualMachineSpecification(name: fixture.virtualMachineName,
            resources: .macOSSmall(), imageSource: .restoreImage(url: fixture.restoreImage, unattendedPreset: "tahoe"),
            diskBytes: 100 * SandboxResourcePolicy.gibibyte)
        try await runtime.create(specification)
        XCTAssertThrowsError(try LumeBaseCandidateOperationGuard(name: fixture.virtualMachineName, storage: fixture.storage))
    }

    func testRuntimeStoragePairingRejectsAnotherStorageRoot() async throws {
        let fixture = try FakeLumeFixture(initialState: nil)
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()
        try await runtime.requireBaseCandidateStorage(fixture.storage)
        do {
            try await runtime.requireBaseCandidateStorage(fixture.storage.appendingPathComponent("other"))
            XCTFail("runtime may not create in one storage while candidate is recorded in another")
        } catch {}
    }
}
