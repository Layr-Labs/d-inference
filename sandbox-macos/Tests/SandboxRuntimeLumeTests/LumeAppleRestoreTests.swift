import Foundation
import SandboxCore
import SandboxRuntime
import HostRuntimeCoordination
@testable import SandboxRuntimeLume
import XCTest

final class LumeAppleRestoreTests: XCTestCase {
    func testRawRestoreRunsWithoutAccountProvisioningAndKeepsIdentityOnReplay() async throws {
        let fixture = try FakeLumeFixture(initialState: nil)
        defer { try? fixture.remove() }
        let runtime = try authorizedRuntime(fixture)
        let specification = try specification(fixture)
        try await runtime.create(specification)
        let identity = try LumeVirtualMachineOwnership.requireOwned(
            name: fixture.virtualMachineName, owner: .baseTemplate, in: fixture.storage)
        let arguments = try String(contentsOf: fixture.directory.appendingPathComponent("create-arguments"),
                                   encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(arguments.prefix(2), ["create", fixture.virtualMachineName])
        let capabilities = try String(contentsOf: fixture.directory.appendingPathComponent("create-capabilities"), encoding: .utf8)
        XCTAssertEqual(capabilities, "apple-v1\n4\n3\n")
        XCTAssertTrue(arguments.contains(fixture.restoreImage.path))
        for forbidden in ["--unattended", "tahoe", "--no-display", "--vnc-port", "--network"] {
            XCTAssertFalse(arguments.contains(forbidden), forbidden)
        }
        let marker = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.ownershipMarker)) as? [String: Any])
        XCTAssertEqual(marker["sourceKind"] as? String, "apple_restore")
        XCTAssertNil(marker["unattendedPreset"])
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            fixture.virtualMachineDirectory.appendingPathComponent(SandboxGuestTemplateReceipt.fileName).path))
        try await runtime.create(specification)
        XCTAssertEqual(try LumeVirtualMachineOwnership.requireOwned(
            name: fixture.virtualMachineName, owner: .baseTemplate, in: fixture.storage), identity)
    }

    func testExistingRawRestoreCannotBecomeAnUnattendedRestore() async throws {
        let fixture = try FakeLumeFixture(initialState: nil)
        defer { try? fixture.remove() }
        let runtime = try authorizedRuntime(fixture)
        try await runtime.create(specification(fixture))
        let legacy = try specification(fixture, source: .restoreImage(url: fixture.restoreImage, unattendedPreset: "tahoe"))
        do {
            try await runtime.create(legacy)
            XCTFail("existing raw restore must retain its provisioning provenance")
        } catch let error as SandboxRuntimeError {
            guard case .unsupported = error else { return XCTFail("unexpected error: \(error)") }
        }
    }

    func testRawRestoreRejectsPresetInStoredOwnership() async throws {
        let fixture = try FakeLumeFixture(initialState: nil)
        defer { try? fixture.remove() }
        try await authorizedRuntime(fixture).create(specification(fixture))
        var marker = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.ownershipMarker)) as? [String: Any])
        marker["unattendedPreset"] = "tahoe"
        try JSONSerialization.data(withJSONObject: marker).write(to: fixture.ownershipMarker)
        XCTAssertThrowsError(try LumeVirtualMachineOwnership.requireOwned(
            name: fixture.virtualMachineName, owner: .baseTemplate, in: fixture.storage))
    }

    func testLegacyRestoreKeepsPresetAndCannotBeRelabeledAccountless() async throws {
        let fixture = try FakeLumeFixture(initialState: nil)
        defer { try? fixture.remove() }
        let runtime = try authorizedRuntime(fixture)
        let legacy = try specification(fixture, source: .restoreImage(url: fixture.restoreImage, unattendedPreset: "tahoe"))
        try await runtime.create(legacy)
        try await runtime.create(legacy)
        let arguments = try String(contentsOf: fixture.directory.appendingPathComponent("create-arguments"),
                                   encoding: .utf8).split(separator: "\n").map(String.init)
        let presetIndex = try XCTUnwrap(arguments.firstIndex(of: "--unattended"))
        XCTAssertEqual(arguments[presetIndex + 1], "tahoe")
        do {
            try await runtime.create(specification(fixture))
            XCTFail("legacy account provisioning must not be relabeled accountless")
        } catch let error as SandboxRuntimeError {
            guard case .unsupported = error else { return XCTFail("unexpected error: \(error)") }
        }
    }

    func testRawRestoreCannotBeCreatedForTenantLease() async throws {
        let fixture = try FakeLumeFixture(initialState: nil)
        defer { try? fixture.remove() }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let arbiter = try fixture.makeCapacityArbiter(clock: LumeTestWallClock(now))
        let lease = try arbiter.reserve(sandboxID: SandboxID(),
            generation: XCTUnwrap(SandboxGeneration(rawValue: 1)),
            virtualMachineName: fixture.virtualMachineName,
            resources: SandboxResourceSpecification.macOSSmall(), expiresAt: now.addingTimeInterval(120))
        let runtime = try fixture.makeLeaseFencedRuntime(capacityArbiter: arbiter)
        do {
            try await runtime.create(scope: lease.scope, specification: specification(fixture))
            XCTFail("raw restore is a base preparation operation")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(error, .unsupported("raw Apple restore is restricted to base preparation"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.createStarted.path))
    }

    func testRawRestoreRequiresExclusiveAuthorityBeforeAnyProcessOrVMCreation() async throws {
        let fixture = try FakeLumeFixture(initialState: nil)
        defer { try? fixture.remove() }
        do {
            try await fixture.makeRuntime().create(specification(fixture))
            XCTFail("missing ownership must fail before restore")
        } catch let error as SandboxRuntimeError {
            XCTAssertEqual(error, .unsupported("raw Apple restore requires exclusive host ownership"))
        }
        let authority = try fixture.makeTestHostRuntimeAuthority()
        let shared = try XCTUnwrap(authority.acquireInferenceIfInstalled())
        do {
            try await fixture.makeRuntime(hostRuntimeLease: shared).create(specification(fixture))
            XCTFail("shared inference authority must not install a VM")
        } catch let error as HostRuntimeOwnershipError {
            XCTAssertEqual(error, .insecureAuthority)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.createStarted.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.virtualMachineDirectory.path))
    }

    private func authorizedRuntime(_ fixture: FakeLumeFixture) throws -> LumeVirtualMachineRuntime {
        try fixture.makeRuntime(hostRuntimeLease: fixture.makeTestHostRuntimeAuthority().acquireSandbox())
    }

    private func specification(_ fixture: FakeLumeFixture,
                               source: SandboxVirtualMachineImageSource? = nil) throws -> SandboxVirtualMachineSpecification {
        try SandboxVirtualMachineSpecification(name: fixture.virtualMachineName,
            resources: SandboxResourceSpecification.macOSSmall(),
            imageSource: source ?? .appleRestore(url: fixture.restoreImage),
            diskBytes: 100 * SandboxResourcePolicy.gibibyte)
    }
}
