import Foundation
@testable import DarkbloomSandboxDaemon
import SandboxCore
@testable import SandboxRuntimeVZ
import XCTest

final class ServeRecoveryInspectionTests: XCTestCase {
    func testLowOrUnavailableDiskInspectionDoesNotPreventServiceRecovery() throws {
        let policy = ServeCommand.hostInspectionPolicy(developmentAdHocLume: false)
        XCTAssertTrue(policy.requireVirtualizationEntitlement)
        XCTAssertTrue(policy.requireSecureEnclave)
        XCTAssertTrue(policy.requireAquaSession)
        XCTAssertFalse(policy.requireAvailableDiskCapacity)
        for bytes: Int64 in [-1, 0, Int64(SandboxResourcePolicy.gibibyte)] {
            let disk = SandboxHostInspector.diskCapacityCheck(availableBytes: bytes, policy: policy)
            XCTAssertEqual(disk.status, .warning)
            XCTAssertNoThrow(try ServeCommand.requireEligibleHost(report(disk: bytes, checks: [disk]),
                maximumCPUCount: 12, maximumMemoryBytes: 32 * SandboxResourcePolicy.gibibyte))
        }
    }

    func testRecoveryPolicyStillRequiresOtherHostChecksAndConfiguredCapacity() {
        let disk = SandboxHostInspector.diskCapacityCheck(availableBytes: 0,
            policy: ServeCommand.hostInspectionPolicy(developmentAdHocLume: false))
        let missingEntitlement = SandboxHostCheck(id: "virtualization_entitlement", status: .failure, summary: "missing")
        XCTAssertThrowsError(try ServeCommand.requireEligibleHost(report(disk: 0, checks: [disk, missingEntitlement]),
            maximumCPUCount: 12, maximumMemoryBytes: 32 * SandboxResourcePolicy.gibibyte))
        XCTAssertThrowsError(try ServeCommand.requireEligibleHost(report(disk: 0, checks: [disk]),
            maximumCPUCount: 17, maximumMemoryBytes: 32 * SandboxResourcePolicy.gibibyte))
        XCTAssertThrowsError(try ServeCommand.requireEligibleHost(report(disk: 0, checks: [disk]),
            maximumCPUCount: 12, maximumMemoryBytes: 65 * SandboxResourcePolicy.gibibyte))
    }

    private func report(disk: Int64, checks: [SandboxHostCheck]) -> SandboxHostReport {
        SandboxHostReport(generatedAt: Date(timeIntervalSince1970: 2_000_000_000),
            operatingSystem: "test", architecture: "arm64", cpuCount: 16,
            memoryBytes: 64 * SandboxResourcePolicy.gibibyte, availableDiskBytes: disk,
            consoleUser: "operator", checks: checks)
    }
}
