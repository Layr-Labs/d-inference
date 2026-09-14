import Foundation
import SandboxRuntime
@testable import SandboxGuestRuntime
import XCTest

final class GuestTenantDomainTests: XCTestCase {
    func testAbsenceRequiresExactDomainIdentityAndErrorNotPermissionFailure() {
        let domain = "gui/2001"
        let absent = "Bad request.\nCould not find domain for user gui: 2001\n"
        XCTAssertTrue(GuestTenantDomains.absent(result(112, absent), domain: domain))
        XCTAssertFalse(GuestTenantDomains.absent(result(1, "Could not print domain: 1: Operation not permitted\n"), domain: domain))
        XCTAssertFalse(GuestTenantDomains.absent(result(112, absent), domain: "user/2001"))
        XCTAssertFalse(GuestTenantDomains.absent(result(112, absent, truncated: true), domain: domain))
        XCTAssertFalse(GuestTenantDomains.absent(result(0, absent), domain: domain))
    }

    private func result(_ status: Int32, _ error: String, truncated: Bool = false) -> SandboxProcessResult {
        SandboxProcessResult(exitCode: status, standardOutput: Data(), standardError: Data(error.utf8),
            standardOutputTruncated: false, standardErrorTruncated: truncated)
    }
}
