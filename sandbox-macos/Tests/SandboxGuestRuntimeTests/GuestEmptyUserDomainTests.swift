import Foundation
import SandboxRuntime
@testable import SandboxGuestRuntime
import XCTest

final class GuestEmptyUserDomainTests: XCTestCase {
    // Exact first print from the disposable 26.6.2 guest, immediately after a
    // successful bootout. A later print recreates this same empty structure.
    private let observed = GuestDomainTestFixture.observed

    func testObservedEmptySlainAndLazilyRecreatedUserDomainsAreQuiescent() {
        XCTAssertTrue(GuestEmptyUserDomain.matches(result(observed)))
        let recreated = observed.replacingOccurrences(of: "active count = 2", with: "active count = 3")
            .replacingOccurrences(of: "launchctl[516]", with: "launchctl[519]")
            .replacingOccurrences(of: "asid = 100028", with: "asid = 100029")
            .replacingOccurrences(of: "0x82503", with: "0xa800b")
            .replacingOccurrences(of: "properties = shutting down | slain", with: "properties = ")
        XCTAssertTrue(GuestEmptyUserDomain.matches(result(recreated)))
    }

    func testEmptyAcceptanceRequiresPriorSuccessfulBootoutAndNeverAppliesToGUI() {
        XCTAssertTrue(GuestTenantDomains.quiescent(result(observed), domain: "user/2001",
                                                  after: .init(userDomainBootedOut: true)))
        XCTAssertFalse(GuestTenantDomains.quiescent(result(observed), domain: "user/2001",
                                                   after: .init(userDomainBootedOut: false)))
        XCTAssertFalse(GuestTenantDomains.quiescent(result(observed), domain: "gui/2001",
                                                   after: .init(userDomainBootedOut: true)))
        XCTAssertEqual(GuestTenantDomains.verificationFailure(result(observed), domain: "user/2001",
                         after: .init(userDomainBootedOut: false)), .userDomainRemovalUnproven)
        XCTAssertEqual(GuestTenantDomains.verificationFailure(result(observed), domain: "gui/2001",
                         after: .init(userDomainBootedOut: true)), .loginDomainNotAbsent)
    }

    func testAnyServiceUnmanagedProcessOrEndpointPreventsCleanupProof() {
        for section in ["services", "unmanaged processes", "endpoints"] {
            let occupied = observed.replacingOccurrences(of: "\t\(section) = {\n\t}",
                with: "\t\(section) = {\n\t\tmalicious-scheduled-work = 100\n\t}")
            XCTAssertFalse(GuestEmptyUserDomain.matches(result(occupied)), section)
        }
    }

    func testWrongIdentityTruncationMalformedAndAmbiguousBlocksFailClosed() {
        let malformed = [
            observed.replacingOccurrences(of: "user/2001 = {", with: "user/501 = {"),
            observed.replacingOccurrences(of: "\t\tuid = 2001", with: "\t\tuid = 501"),
            observed.replacingOccurrences(of: "\thandle = 2001", with: "\thandle = 501"),
            observed.replacingOccurrences(of: "\tservices = {\n\t}", with: "\tservices = {\n\t}\n\tservices = {\n\t}"),
            observed.replacingOccurrences(of: "\tservices = {\n\t}", with: "\tservices = {\n\t\t}\n\t\tservices = {\n\t}"),
            observed.replacingOccurrences(of: "\tservices = {\n\t}", with: ""),
            observed.replacingOccurrences(of: "com.apple.xpc.launchd.domain.user.2001", with: "com.apple.xpc.launchd.domain.user.501"),
            observed + "user/2001 = {\n}\n",
        ]
        for value in malformed { XCTAssertFalse(GuestEmptyUserDomain.matches(result(value))) }
        XCTAssertFalse(GuestEmptyUserDomain.matches(result(observed, truncated: true)))
        XCTAssertFalse(GuestEmptyUserDomain.matches(result(observed, code: 1)))
    }

    private func result(_ text: String, truncated: Bool = false, code: Int32 = 0) -> SandboxProcessResult {
        SandboxProcessResult(exitCode: code, standardOutput: Data(text.utf8), standardError: Data(),
                             standardOutputTruncated: truncated, standardErrorTruncated: false)
    }
}
