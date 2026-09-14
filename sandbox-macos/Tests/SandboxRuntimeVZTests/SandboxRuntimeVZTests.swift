import Foundation
import SandboxRuntimeVZ
import XCTest

final class SandboxRuntimeVZTests: XCTestCase {
    func testRealHostInspectionUsesVirtualizationAndSecureEnclave() throws {
        let report = SandboxHostInspector().inspect(policy: SandboxHostInspectionPolicy(
            minimumCPUCount: 1,
            minimumMemoryBytes: 1,
            minimumAvailableDiskBytes: 1,
            requireVirtualizationEntitlement: false,
            requireAquaSession: false,
            requireSecureEnclave: false
        ))

        XCTAssertGreaterThan(report.cpuCount, 0)
        XCTAssertGreaterThan(report.memoryBytes, 0)
        XCTAssertGreaterThan(report.availableDiskBytes, 0)
        XCTAssertEqual(check("virtualization_framework", in: report)?.status, .pass)

        let encoded = try JSONEncoder().encode(report)
        XCTAssertNoThrow(try JSONDecoder().decode(SandboxHostReport.self, from: encoded))
    }

    func testLatestSupportedRestoreImageAgainstAppleCatalog() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["DARKBLOOM_SANDBOX_LIVE_RESTORE"] == "1",
            "set DARKBLOOM_SANDBOX_LIVE_RESTORE=1 for the Apple restore-catalog test"
        )

        let image = try EntitledRestoreImageProbe(
            testBundleURL: Bundle(for: type(of: self)).bundleURL
        ).latestSupported()
        XCTAssertEqual(image.url.scheme, "https")
        XCTAssertFalse(image.buildVersion.isEmpty)
        XCTAssertFalse(image.operatingSystemVersion.isEmpty)
        XCTAssertGreaterThan(image.minimumCPUCount, 0)
        XCTAssertGreaterThan(image.minimumMemoryBytes, 0)
        XCTAssertFalse(image.hardwareModelData.isEmpty)
    }

    private func check(
        _ id: String,
        in report: SandboxHostReport
    ) -> SandboxHostCheck? {
        report.checks.first { $0.id == id }
    }
}
