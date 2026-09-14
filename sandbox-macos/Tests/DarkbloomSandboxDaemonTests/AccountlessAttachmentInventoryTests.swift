import Foundation
import SandboxRuntime
@testable import DarkbloomSandboxDaemon
import XCTest

final class AccountlessAttachmentInventoryTests: XCTestCase {
    func testAttachMappedHintAndInfoGUIDDescribeTheSameEntity() throws {
        let guid = "7C3457EF-0000-11AA-AA11-00306543ECAC"
        let attached = try AccountlessAttachmentInventory.entities([
            ["dev-entry": "/dev/disk6s1", "content-hint": "Apple_APFS", "unmapped-content-hint": guid]])
        let inspected = try AccountlessAttachmentInventory.entities([
            ["dev-entry": "/dev/disk6s1", "content-hint": guid]])
        XCTAssertEqual(attached, inspected)
        XCTAssertThrowsError(try AccountlessAttachmentInventory.entities([
            ["dev-entry": "/dev/disk6s1", "content-hint": "Apple_APFS", "unmapped-content-hint": 1]]))
    }

    func testExactTargetAndSystemAliasRemainDistinctFromOtherImages() throws {
        let value = try inventory([record(path: "/tmp/owned/disk.img", disk: "disk8"), record(path: "/private/tmp/other.img", disk: "disk9")])
        let found = try XCTUnwrap(value.target(URL(fileURLWithPath: "/private/tmp/owned/disk.img"), ownerUID: 0, writable: true))
        XCTAssertEqual(try found.wholeDisk().rawValue, "disk8")
        XCTAssertNil(try value.target(URL(fileURLWithPath: "/private/tmp/missing.img"), ownerUID: 0, writable: true))
        try found.requireNoUnexpectedMounts()
    }

    func testOwnerAndWritePolicyCannotBeSubstitutedButCleanupCanIdentifyReadonlyOwnedImage() throws {
        var image = record(path: "/private/tmp/a.img", disk: "disk8")
        image["writeable"] = false
        let value = try inventory([image]), url = URL(fileURLWithPath: "/private/tmp/a.img")
        XCTAssertThrowsError(try value.target(url, ownerUID: 0, writable: true))
        XCTAssertNotNil(try value.ownedTarget(url, ownerUID: 0))
        XCTAssertThrowsError(try value.ownedTarget(url, ownerUID: 501))
    }

    func testDuplicateAliasesDevicesAndMalformedInventoryAreRejected() throws {
        XCTAssertThrowsError(try inventory([record(path: "/private/tmp/a.img", disk: "disk8"), record(path: "/private/tmp/b.img", disk: "disk8")]))
        let aliases = try inventory([record(path: "/tmp/a.img", disk: "disk8"), record(path: "/private/tmp/a.img", disk: "disk9")])
        XCTAssertThrowsError(try aliases.ownedTarget(URL(fileURLWithPath: "/private/tmp/a.img"), ownerUID: 0))
        for key in ["image-path", "owner-uid", "writeable", "system-entities"] {
            var image = record(path: "/private/tmp/a.img", disk: "disk8")
            image[key] = key == "writeable" ? 1 : "invalid"
            XCTAssertThrowsError(try inventory([image]), key)
        }
        XCTAssertThrowsError(try inventory([record(path: "/private/tmp/../a.img", disk: "disk8")]))
        XCTAssertEqual(try inventory([]).images.count, 0)
    }

    func testMountedEntityMustUseOnlyTheDeclaredPrivateMountpoint() throws {
        var image = record(path: "/private/tmp/a.img", disk: "disk8")
        image["system-entities"] = [["dev-entry": "/dev/disk8", "content-hint": "GUID_partition_scheme"],
            ["dev-entry": "/dev/disk9s1", "mount-point": "/private/tmp/operator/Data"]]
        let found = try XCTUnwrap(inventory([image]).images.first)
        XCTAssertThrowsError(try found.requireNoUnexpectedMounts())
        try found.requireNoUnexpectedMounts(allowed: URL(fileURLWithPath: "/private/tmp/operator/Data"))
        XCTAssertThrowsError(try found.requireNoUnexpectedMounts(allowed: URL(fileURLWithPath: "/private/tmp/other/Data")))
    }

    func testOpenerExemptionIsOneExactDescriptorNotAllRootOrCurrentProcessDescriptors() throws {
        func result(_ value: String, code: Int32 = 0) -> SandboxProcessResult {
            .init(exitCode: code, standardOutput: Data(value.utf8), standardError: Data(), standardOutputTruncated: false, standardErrorTruncated: false)
        }
        try AccountlessImageOpeners.requireOnlyRetainedDescriptor(result("p123\nf8\n"), pid: 123, descriptor: 8)
        for output in ["", "p123\nf9\n", "p123\nf8\nf9\n", "p123\nf8\np124\nf8\n", "p123\nfmem\n", "f8\n", "p123\nf8\nnunknown\n"] {
            XCTAssertThrowsError(try AccountlessImageOpeners.requireOnlyRetainedDescriptor(result(output), pid: 123, descriptor: 8))
        }
        XCTAssertThrowsError(try AccountlessImageOpeners.requireOnlyRetainedDescriptor(result("", code: 1), pid: 123, descriptor: 8))
    }

    private func record(path: String, disk: String) -> [String: Any] {
        ["image-path": path, "owner-uid": 0, "writeable": true,
         "system-entities": [["dev-entry": "/dev/" + disk, "content-hint": "GUID_partition_scheme"]]]
    }
    private func inventory(_ images: [[String: Any]]) throws -> AccountlessAttachmentInventory {
        try .init(PropertyListSerialization.data(fromPropertyList: ["images": images], format: .xml, options: 0))
    }
}
