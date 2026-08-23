import SandboxCore
import SandboxRuntime
import XCTest

final class VirtualMachineRuntimeTests: XCTestCase {
    func testSpecificationAcceptsBoundedNameAndDisk() throws {
        let resources = try SandboxResourceSpecification.macOSSmall()
        let specification = try SandboxVirtualMachineSpecification(
            name: " sandbox-123 ",
            resources: resources,
            imageSource: .localTemplate(name: " macos-26-5-base-v1 "),
            diskBytes: 100 * SandboxResourcePolicy.gibibyte
        )

        XCTAssertEqual(specification.name, "sandbox-123")
        XCTAssertEqual(
            specification.imageSource,
            .localTemplate(name: "macos-26-5-base-v1")
        )
        XCTAssertEqual(specification.diskBytes, 100 * SandboxResourcePolicy.gibibyte)
    }

    func testSpecificationRejectsUnsafeNames() throws {
        let resources = try SandboxResourceSpecification.macOSSmall()
        for name in [
            "",
            "-sandbox",
            "sandbox-",
            "../sandbox",
            "sandbox_name",
            "a b",
            "sándbox",
        ] {
            XCTAssertThrowsError(try SandboxVirtualMachineSpecification(
                name: name,
                resources: resources,
                imageSource: .localTemplate(name: "base"),
                diskBytes: 100 * SandboxResourcePolicy.gibibyte
            ), "expected '\(name)' to be rejected")
        }
    }

    func testSpecificationRejectsWorkspaceLargerThanDisk() throws {
        let resources = try SandboxResourceSpecification.macOSSmall()
        XCTAssertThrowsError(try SandboxVirtualMachineSpecification(
            name: "sandbox",
            resources: resources,
            imageSource: .localTemplate(name: "base"),
            diskBytes: 24 * SandboxResourcePolicy.gibibyte
        )) { error in
            XCTAssertEqual(error as? SandboxRuntimeError, .diskSmallerThanWorkspace)
        }
    }
}
