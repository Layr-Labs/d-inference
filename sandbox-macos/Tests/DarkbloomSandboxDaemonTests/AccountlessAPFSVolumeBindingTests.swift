import Foundation
@testable import DarkbloomSandboxDaemon
import XCTest

final class AccountlessAPFSVolumeBindingTests: XCTestCase {
    private let volumeUUID = UUID(uuidString: "A64BCFD6-CFE3-4A99-996C-C9309A78F10F")!

    func testSelectsDataRoleThroughExactWholePartitionAndContainerChain() throws {
        let whole = try AccountlessDiskIdentifier("disk6")
        let physical = try AccountlessAPFSVolumeBinding.physicalStore(in: plist(listing()), wholeDisk: whole)
        XCTAssertEqual(physical.rawValue, "disk6s2")
        let container = try AccountlessAPFSVolumeBinding.container(in: plist([
            "DeviceIdentifier": "disk6s2", "APFSContainerReference": "disk9"]), physicalStore: physical)
        let binding = try AccountlessAPFSVolumeBinding.select(in: plist(inventory()), wholeDisk: whole,
            physicalStore: physical, container: container)
        XCTAssertEqual(binding.dataVolume.nodePath, "/dev/disk9s2")
        XCTAssertEqual(binding.volumeUUID, volumeUUID)
        XCTAssertEqual(try JSONDecoder().decode(AccountlessAPFSVolumeBinding.self, from: JSONEncoder().encode(binding)), binding)
    }

    func testAmbiguousMainPartitionsAndForeignPartitionIdentifiersAreRejected() throws {
        for kind in ["duplicate", "foreign", "wrongWhole", "notGUID"] {
            var disks = listing()["AllDisksAndPartitions"] as! [[String: Any]]
            var partitions = disks[0]["Partitions"] as! [[String: Any]]
            if kind == "duplicate" { partitions.append(["DeviceIdentifier": "disk6s4", "Content": "Apple_APFS"]) }
            if kind == "foreign" { partitions[1]["DeviceIdentifier"] = "disk3s2" }
            disks[0]["Partitions"] = partitions
            if kind == "wrongWhole" { disks[0]["DeviceIdentifier"] = "disk3" }
            if kind == "notGUID" { disks[0]["Content"] = "Apple_APFS" }
            XCTAssertThrowsError(try AccountlessAPFSVolumeBinding.physicalStore(
                in: plist(["AllDisksAndPartitions": disks]), wholeDisk: .init("disk6")), kind)
        }
    }

    func testPhysicalInfoMustDescribeTheSelectedPartitionAndAWholeContainer() throws {
        for info in [["DeviceIdentifier": "disk3s2", "APFSContainerReference": "disk9"],
                     ["DeviceIdentifier": "disk6s2", "APFSContainerReference": "disk9s1"],
                     ["DeviceIdentifier": "disk6s2", "APFSContainerReference": "/dev/disk9"]] {
            XCTAssertThrowsError(try AccountlessAPFSVolumeBinding.container(in: plist(info), physicalStore: .init("disk6s2")))
        }
    }

    func testDataSelectionRejectsForeignStoresContainersAndAmbiguousVolumeRoles() throws {
        for kind in ["store", "extraStore", "container", "duplicateData", "duplicateID", "foreignVolume", "nameOnly", "mixedRole", "badUUID", "zeroUUID"] {
            var root = inventory(), containers = root["Containers"] as! [[String: Any]]
            var volumes = containers[0]["Volumes"] as! [[String: Any]]
            switch kind {
            case "store": containers[0]["PhysicalStores"] = [["DeviceIdentifier": "disk3s2"]]
            case "extraStore": containers[0]["PhysicalStores"] = [["DeviceIdentifier": "disk6s2"], ["DeviceIdentifier": "disk3s2"]]
            case "container": containers[0]["ContainerReference"] = "disk3"
            case "duplicateData":
                var extra = volumes[1]; extra["DeviceIdentifier"] = "disk9s3"; volumes.append(extra)
            case "duplicateID": volumes[0]["DeviceIdentifier"] = "disk9s2"
            case "foreignVolume": volumes[1]["DeviceIdentifier"] = "disk3s2"
            case "nameOnly": volumes[1]["Roles"] = []; volumes[1]["Name"] = "Data"
            case "mixedRole": volumes[1]["Roles"] = ["Data", "System"]
            case "badUUID": volumes[1]["APFSVolumeUUID"] = "not-a-uuid"
            case "zeroUUID": volumes[1]["APFSVolumeUUID"] = "00000000-0000-0000-0000-000000000000"
            default: XCTFail("unknown fixture")
            }
            containers[0]["Volumes"] = volumes; root["Containers"] = containers
            XCTAssertThrowsError(try select(root), kind)
        }
    }

    func testAnyPreviouslyMountedVolumeBlocksSelectionIncludingSystemVolume() throws {
        for index in [0, 1] {
            var root = inventory(), containers = root["Containers"] as! [[String: Any]]
            var volumes = containers[0]["Volumes"] as! [[String: Any]]
            volumes[index]["MountPoint"] = "/Volumes/AlreadyMounted"
            containers[0]["Volumes"] = volumes; root["Containers"] = containers
            XCTAssertThrowsError(try select(root)) { XCTAssertEqual($0 as? AccountlessDiskError, .unexpectedMount) }
        }
    }

    func testMountedReadbackMustMatchUUIDPathOwnersAndRequestedWritePolicy() throws {
        let binding = try select(inventory()), mount = URL(fileURLWithPath: "/private/tmp/root-mount/Data")
        let info: [String: Any] = ["DeviceNode": "/dev/disk9s2", "DeviceIdentifier": "disk9s2", "APFSContainerReference": "disk9",
            "VolumeUUID": volumeUUID.uuidString, "FilesystemType": "apfs", "MountPoint": mount.path,
            "GlobalPermissionsEnabled": true, "Writable": true]
        try binding.requireMounted(plist(info), at: mount, writable: true)
        for key in ["DeviceNode", "DeviceIdentifier", "APFSContainerReference", "VolumeUUID", "FilesystemType", "MountPoint",
                    "GlobalPermissionsEnabled", "Writable"] {
            var changed = info
            switch key {
            case "GlobalPermissionsEnabled", "Writable": changed[key] = false
            case "DeviceIdentifier": changed[key] = "disk3s1"
            case "APFSContainerReference": changed[key] = "disk3"
            case "VolumeUUID": changed[key] = UUID().uuidString
            default: changed[key] = "changed"
            }
            XCTAssertThrowsError(try binding.requireMounted(plist(changed), at: mount, writable: true), key)
        }
        var numeric = info; numeric["GlobalPermissionsEnabled"] = 1
        XCTAssertThrowsError(try binding.requireMounted(plist(numeric), at: mount, writable: true))
        var readonly = info; readonly["Writable"] = false
        try binding.requireMounted(plist(readonly), at: mount, writable: false)
    }

    func testIdentifiersRejectPathsOptionsUnicodeAndMalformedPartitions() throws {
        for value in ["/dev/disk6", "disk", "disk6s", "disk6s1x", "disk6ss1", "disk６", "-disk6", "disk6/../disk0", "disk6\0"] {
            XCTAssertThrowsError(try AccountlessDiskIdentifier(value), value)
            XCTAssertThrowsError(try JSONDecoder().decode(AccountlessDiskIdentifier.self, from: JSONEncoder().encode(value)))
        }
        XCTAssertTrue(try AccountlessDiskIdentifier("disk6").isWholeDisk)
        XCTAssertTrue(try AccountlessDiskIdentifier("disk6s2").isDirectPartition(of: .init("disk6")))
        XCTAssertFalse(try AccountlessDiskIdentifier("disk6s2s1").isDirectPartition(of: .init("disk6")))
    }

    private func select(_ value: [String: Any]) throws -> AccountlessAPFSVolumeBinding {
        try .select(in: plist(value), wholeDisk: .init("disk6"), physicalStore: .init("disk6s2"), container: .init("disk9"))
    }
    private func plist(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }
    private func listing() -> [String: Any] {
        ["AllDisksAndPartitions": [["DeviceIdentifier": "disk6", "Content": "GUID_partition_scheme", "Partitions": [
            ["DeviceIdentifier": "disk6s1", "Content": "Apple_APFS_ISC"],
            ["DeviceIdentifier": "disk6s2", "Content": "Apple_APFS"],
            ["DeviceIdentifier": "disk6s3", "Content": "Apple_APFS_Recovery"]]]]]
    }
    private func inventory() -> [String: Any] {
        ["Containers": [["ContainerReference": "disk9", "PhysicalStores": [["DeviceIdentifier": "disk6s2"]], "Volumes": [
            ["DeviceIdentifier": "disk9s1", "Roles": ["System"], "Name": "Data"],
            ["DeviceIdentifier": "disk9s2", "Roles": ["Data"], "Name": "Arbitrary label", "APFSVolumeUUID": volumeUUID.uuidString]]]]]
    }
}
