import Foundation
@testable import DarkbloomSandboxDaemon
import XCTest

final class DiscardBaseOptionsTests: XCTestCase {
    private let host = UUID(), installation = UUID()
    private var arguments: [String] {
        ["--host-identity-file", "/protected/identity.json", "--host-id", host.uuidString,
         "--lume", "/protected/lume", "--storage", "/encrypted/vms", "--name", "failed-base",
         "--installation-id", installation.uuidString, "--json"]
    }
    func testExactTargetParsesAndDoesNotAcceptBypassOptions() throws {
        let value = try DiscardBaseOptions(arguments)
        XCTAssertEqual(value.installationID, installation)
        XCTAssertEqual(value.hostID, host)
        XCTAssertEqual(value.storage.path, "/encrypted/vms")
        XCTAssertTrue(value.json)
        for extra in [["--force"], ["--development-ad-hoc-lume"], ["--json"], ["--name", "another"]] {
            XCTAssertThrowsError(try DiscardBaseOptions(arguments + extra))
        }
    }
    func testMissingIdentityAndUnsafePathsRejectBeforeAnyOperation() {
        for option in ["--installation-id", "--host-id", "--host-identity-file", "--lume", "--storage", "--name"] {
            var missing = arguments
            let index = missing.firstIndex(of: option)!
            missing.removeSubrange(index...index + 1)
            XCTAssertThrowsError(try DiscardBaseOptions(missing))
        }
        for path in ["/", "relative", "/encrypted/../other", "/encrypted//vms", "/encrypted/\n"] {
            var invalid = arguments
            invalid[invalid.firstIndex(of: "--storage")! + 1] = path
            XCTAssertThrowsError(try DiscardBaseOptions(invalid))
        }
    }
}
