import Foundation
import SandboxRuntime
@testable import DarkbloomSandboxDaemon
import XCTest

final class AccountlessDiskToolsTests: XCTestCase {
    func testReadChainUsesOnlyValidatedDeviceIdentifiersAndPreservesVolumeIdentity() async throws {
        let fake = DiskToolSequence(steps: [
            (["list", "-plist", "/dev/disk6"], try output([
                "AllDisksAndPartitions": [["DeviceIdentifier": "disk6", "Content": "GUID_partition_scheme",
                    "Partitions": [["DeviceIdentifier": "disk6s2", "Content": "Apple_APFS"]]]]])),
            (["info", "-plist", "/dev/disk6s2"], try output([
                "DeviceIdentifier": "disk6s2", "APFSContainerReference": "disk9"])),
            (["apfs", "list", "-plist", "disk9"], try output([
                "Containers": [["ContainerReference": "disk9", "PhysicalStores": [["DeviceIdentifier": "disk6s2"]],
                    "Volumes": [["DeviceIdentifier": "disk9s2", "Roles": ["Data"],
                        "APFSVolumeUUID": "A64BCFD6-CFE3-4A99-996C-C9309A78F10F"]]]]]))])
        let tools = AccountlessDiskTools { try await fake.run($0) }
        let binding = try await tools.selectDataVolume(for: .init("disk6"))
        XCTAssertEqual(binding.physicalStore.rawValue, "disk6s2")
        XCTAssertEqual(binding.dataVolume.rawValue, "disk9s2")
        let remaining = await fake.remaining
        XCTAssertEqual(remaining, 0)
    }

    func testFailedOrTruncatedInventoryStopsBeforeFollowingAnyDevice() async throws {
        let original = try output(["AllDisksAndPartitions": [["DeviceIdentifier": "disk6",
            "Content": "GUID_partition_scheme", "Partitions": [["DeviceIdentifier": "disk6s2", "Content": "Apple_APFS"]]]]])
        for kind in ["exit", "stdout", "stderr"] {
            let result = SandboxProcessResult(exitCode: kind == "exit" ? 1 : 0, standardOutput: original.standardOutput,
                standardError: Data(), standardOutputTruncated: kind == "stdout", standardErrorTruncated: kind == "stderr")
            let fake = DiskToolSequence(steps: [(["list", "-plist", "/dev/disk6"], result)])
            do {
                _ = try await AccountlessDiskTools { try await fake.run($0) }.selectDataVolume(for: .init("disk6"))
                XCTFail("accepted failed system inventory: \(kind)")
            } catch { XCTAssertEqual(error as? AccountlessDiskError, .commandFailed) }
            let remaining = await fake.remaining; XCTAssertEqual(remaining, 0)
        }
    }

    func testForeignPartitionDoesNotBecomeAnInfoCommand() async throws {
        let fake = DiskToolSequence(steps: [(["list", "-plist", "/dev/disk6"], try output([
            "AllDisksAndPartitions": [["DeviceIdentifier": "disk6", "Content": "GUID_partition_scheme",
                "Partitions": [["DeviceIdentifier": "disk0s2", "Content": "Apple_APFS"]]]]]))])
        do {
            _ = try await AccountlessDiskTools { try await fake.run($0) }.selectDataVolume(for: .init("disk6"))
            XCTFail("foreign physical partition accepted")
        } catch { XCTAssertEqual(error as? AccountlessDiskError, .bindingChanged) }
        let remaining = await fake.remaining; XCTAssertEqual(remaining, 0)
    }

    private func output(_ value: [String: Any]) throws -> SandboxProcessResult {
        .init(exitCode: 0, standardOutput: try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0),
            standardError: Data(), standardOutputTruncated: false, standardErrorTruncated: false)
    }
}

private actor DiskToolSequence {
    let steps: [([String], SandboxProcessResult)]
    private var index = 0
    var remaining: Int { steps.count - index }
    init(steps: [([String], SandboxProcessResult)]) { self.steps = steps }
    func run(_ arguments: [String]) throws -> SandboxProcessResult {
        guard index < steps.count, steps[index].0 == arguments else {
            XCTFail("unexpected system command: \(arguments)")
            throw AccountlessDiskError.commandFailed
        }
        defer { index += 1 }
        return steps[index].1
    }
}
