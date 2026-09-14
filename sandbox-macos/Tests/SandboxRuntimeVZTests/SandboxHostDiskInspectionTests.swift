import Foundation
import SandboxCore
@testable import SandboxRuntimeVZ
import XCTest

final class SandboxHostDiskInspectionTests: XCTestCase {
    func testDoctorKeepsProvisioningFloorWhileRecoveryReportsDiskWarning() {
        let doctor = SandboxHostInspectionPolicy()
        let recovery = SandboxHostInspectionPolicy(requireAvailableDiskCapacity: false)
        let floor = 300 * Int64(SandboxResourcePolicy.gibibyte)
        XCTAssertEqual(doctor.minimumAvailableDiskBytes, floor)
        XCTAssertEqual(recovery.minimumAvailableDiskBytes, floor)

        for bytes: Int64 in [-1, 0, floor - 1] {
            XCTAssertEqual(SandboxHostInspector.diskCapacityCheck(availableBytes: bytes, policy: doctor).status, .failure)
            XCTAssertEqual(SandboxHostInspector.diskCapacityCheck(availableBytes: bytes, policy: recovery).status, .warning)
        }
        for policy in [doctor, recovery] {
            XCTAssertEqual(SandboxHostInspector.diskCapacityCheck(availableBytes: floor, policy: policy).status, .pass)
        }
    }

    func testInspectionMeasuresConfiguredStorageVolume() {
        let storage = URL(fileURLWithPath: "/configured-sandbox-volume", isDirectory: true)
        let actualBytes = Int64(SandboxResourcePolicy.gibibyte)
        let inspector = SandboxHostInspector(availableCapacity: { path in
            path == storage ? actualBytes : 500 * Int64(SandboxResourcePolicy.gibibyte)
        })
        let report = inspector.inspect(policy: SandboxHostInspectionPolicy(
            requireVirtualizationEntitlement: false,
            requireAquaSession: false,
            requireSecureEnclave: false,
            requireAvailableDiskCapacity: false), storageDirectory: storage)

        XCTAssertEqual(report.availableDiskBytes, actualBytes)
        XCTAssertEqual(report.checks.first { $0.id == "disk_capacity" }?.status, .warning)
    }
}
