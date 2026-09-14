import Foundation
import SandboxRuntime
@testable import DarkbloomSandboxDaemon
import XCTest

final class AccountlessMountSystemToolsTests: XCTestCase {
    func testCleanupWholeDiskIsResolvedFromImageDevicesInsteadOfAssumingFirstWholeNode() async throws {
        let image = try attachedImage()
        var queried: [[String]] = []
        let tools = AccountlessMountSystemTools { tool, arguments, _ in
            XCTAssertEqual(tool, .diskutil); queried.append(arguments)
            let device = String(arguments.last!.dropFirst(5))
            let content = device == "disk6" ? "GUID_partition_scheme" : "Apple_APFS"
            return try self.plist(["AllDisksAndPartitions": [["DeviceIdentifier": device, "Content": content]]])
        }
        let whole = try await tools.wholeDisk(of: image, excluding: [])
        XCTAssertEqual(whole.rawValue, "disk6")
        XCTAssertEqual(Set(queried.map { $0.last! }), ["/dev/disk6", "/dev/disk9"])
    }

    func testPreexistingDeviceIsRejectedBeforeAnyCleanupQuery() async throws {
        let tools = AccountlessMountSystemTools { _, _, _ in XCTFail("must not query an excluded device"); throw AccountlessDiskError.commandFailed }
        do { _ = try await tools.wholeDisk(of: attachedImage(), excluding: [.init("disk6")]); XCTFail("expected rejection") }
        catch { XCTAssertEqual(error as? AccountlessDiskError, .bindingChanged) }
    }

    func testDeviceReuseDuringCleanupResolutionFailsClosed() async throws {
        let tools = AccountlessMountSystemTools { _, _, _ in
            try self.plist(["AllDisksAndPartitions": [["DeviceIdentifier": "disk0", "Content": "GUID_partition_scheme"]]])
        }
        do { _ = try await tools.wholeDisk(of: attachedImage(), excluding: []); XCTFail("expected rejection") }
        catch { XCTAssertEqual(error as? AccountlessDiskError, .bindingChanged) }
    }

    private func attachedImage() throws -> AccountlessAttachedImage {
        .init(imagePath: "/private/tmp/owned.img", ownerUID: 0, writable: true, entities: [
            .init(device: try .init("disk9"), contentHint: nil, mountpoint: nil),
            .init(device: try .init("disk6"), contentHint: nil, mountpoint: nil)])
    }
    private func plist(_ value: [String: Any]) throws -> SandboxProcessResult {
        .init(exitCode: 0, standardOutput: try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0),
            standardError: Data(), standardOutputTruncated: false, standardErrorTruncated: false)
    }
}
