import Darwin
import Foundation
import SandboxCore
@testable import SandboxRuntimeLume
import XCTest

final class LumeRootNativeInspectorTests: XCTestCase {
    func testOnlyExactStoppedMacSourceAndReservedResourcesAreAccepted() throws {
        let resources = try SandboxResourceSpecification.macOSSmall(), size = 100 * SandboxResourcePolicy.gibibyte
        let valid: [String: Any] = ["name": "base", "os": "macOS", "status": "stopped",
            "cpuCount": resources.cpuCount, "memorySize": resources.memoryBytes, "diskSize": ["total": size]]
        try LumeRootNativeInspector.requireStopped(JSONSerialization.data(withJSONObject: [valid]), name: "base", resources: resources, diskBytes: size)
        for (field, value) in [("name", "another"), ("os", "linux"), ("status", "unknown"), ("status", "running"), ("provisioningOperation", "ipsw_install")] {
            var changed = valid; changed[field] = value
            XCTAssertThrowsError(try LumeRootNativeInspector.requireStopped(JSONSerialization.data(withJSONObject: [changed]),
                name: "base", resources: resources, diskBytes: size))
        }
        for field in ["cpuCount", "memorySize", "diskSize"] {
            var changed = valid; changed[field] = field == "diskSize" ? ["total": 1] : 1
            XCTAssertThrowsError(try LumeRootNativeInspector.requireStopped(JSONSerialization.data(withJSONObject: [changed]),
                name: "base", resources: resources, diskBytes: size))
        }
        XCTAssertThrowsError(try LumeRootNativeInspector.requireStopped(JSONSerialization.data(withJSONObject: [valid, valid]),
            name: "base", resources: resources, diskBytes: size))
    }

    func testUnprivilegedConstructionFailsBeforeRuntimeAccess() throws {
        guard geteuid() != 0 else { throw XCTSkip("requires an unprivileged test process") }
        let config = try LumeRuntimeConfiguration(executable: URL(fileURLWithPath: "/missing/lume"),
            storageDirectory: URL(fileURLWithPath: "/missing/vms"))
        XCTAssertThrowsError(try LumeRootNativeInspector(configuration: config, ownerUID: geteuid(), ownerGID: getegid()))
    }
}
