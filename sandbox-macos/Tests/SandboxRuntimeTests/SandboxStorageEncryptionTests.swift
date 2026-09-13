import Foundation
@testable import SandboxRuntime
import XCTest

final class SandboxStorageEncryptionTests: XCTestCase {
    func testRequiresRealBooleanEncryptionAndExactFilesystemMount() throws {
        func encoded(_ additions: [String: Any]) throws -> Data {
            var value: [String: Any] = ["FilesystemType": "apfs", "MountPoint": "/Volumes/test", "FileVault": true]
            value.merge(additions) { _, new in new }
            return try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        }
        XCTAssertTrue(try SandboxStorageEncryption.isEncryptedAPFS(encoded([:]), expectedMount: "/Volumes/test"))
        for fields: [String: Any] in [["FileVault": false], ["FileVault": 1], ["FileVault": "true"],
                                      ["FilesystemType": "hfs"], ["MountPoint": "/Volumes/other"]] {
            XCTAssertFalse(try SandboxStorageEncryption.isEncryptedAPFS(encoded(fields), expectedMount: "/Volumes/test"))
        }
    }
}
