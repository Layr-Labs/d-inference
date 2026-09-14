import Foundation
import SandboxRuntime
@testable import SandboxGuestRuntime
import XCTest

final class GuestTenantDomainStabilizationTests: XCTestCase {
    func testRemovalDoesNotRecreateUserDomainDuringFinalVerification() async throws {
        // Physical 26.6.2 probe: user print creates a domain; GUI print returns
        // 125 while it exists and exact 112 after user bootout. No user lookup
        // is allowed after the successful removal, even to inspect empty output.
        let sequence = Sequence([
            (["print", "user/2001"], Self.populatedUser),
            (["bootout", "user/2001"], Self.result("")),
            (["print", "gui/2001"], Self.absentGUI),
            (["print", "gui/2001"], Self.absentGUI),
        ])
        try await GuestTenantDomains.remove(run: { try sequence.next($0) }, pause: {})
        try await GuestTenantDomains.verifyLoginDomainAbsent(run: { try sequence.next($0) }, pause: {})
        XCTAssertEqual(sequence.remaining, 0)
    }

    func testRacingRemovalRequiresAnActualSuccessfulRetry() async throws {
        let sequence = Sequence([
            (["print", "user/2001"], Self.populatedUser),
            (["bootout", "user/2001"], Self.result("", code: 37, error: "operation in progress")),
            (["print", "user/2001"], Self.populatedUser),
            (["bootout", "user/2001"], Self.result("")),
            (["print", "gui/2001"], Self.absentGUI),
        ])
        try await GuestTenantDomains.remove(run: { try sequence.next($0) }, pause: {})
        XCTAssertEqual(sequence.remaining, 0)
    }

    func testAbsentUserDomainNeedsNoBootoutOrRecreation() async throws {
        let sequence = Sequence([
            (["print", "user/2001"], Self.result("", code: 112, error: "Could not find domain for uid: 2001\n")),
            (["print", "gui/2001"], Self.absentGUI),
        ])
        try await GuestTenantDomains.remove(run: { try sequence.next($0) }, pause: {})
        XCTAssertEqual(sequence.remaining, 0)
    }

    func testGUIRemovalIsFollowedByUserRemoval() async throws {
        let sequence = Sequence([
            (["print", "user/2001"], Self.populatedUser),
            (["bootout", "user/2001"], Self.result("")),
            (["print", "gui/2001"], Self.result("gui/2001 = {\n}\n")),
            (["bootout", "gui/2001"], Self.result("")),
            (["print", "user/2001"], Self.populatedUser),
            (["bootout", "user/2001"], Self.result("")),
        ])
        try await GuestTenantDomains.remove(run: { try sequence.next($0) }, pause: {})
        XCTAssertEqual(sequence.remaining, 0)
    }

    func testUnsupportedGUIInspectionNeverProvesAbsence() async {
        let unsupported = Self.result("", code: 125,
            error: "Could not print domain: 125: Domain does not support specified action\n")
        let sequence = Sequence(Array(repeating: (["print", "gui/2001"], unsupported), count: 8))
        do {
            try await GuestTenantDomains.verifyLoginDomainAbsent(run: { try sequence.next($0) }, pause: {})
            XCTFail("125 does not prove absence")
        } catch {
            XCTAssertEqual(error as? GuestTenantDomains.VerificationFailure, .inspectionUnproven)
        }
        XCTAssertEqual(sequence.remaining, 0)
    }

    func testUnremovedDomainCannotPassEvenWhenListingIsEmpty() async {
        let sequence = Sequence(Array(repeating: (["print", "gui/2001"], Self.result("gui/2001 = {\n}\n")), count: 8))
        do {
            try await GuestTenantDomains.verifyLoginDomainAbsent(run: { try sequence.next($0) }, pause: {})
            XCTFail("an empty existing domain is not absent")
        } catch {
            XCTAssertEqual(error as? GuestTenantDomains.VerificationFailure, .loginDomainNotAbsent)
        }
    }

    private static var populatedUser: SandboxProcessResult {
        result("user/2001 = {\n\tservices = {\n\t\t570 running arbitrary.tenant.job\n\t}\n}\n")
    }
    private static var absentGUI: SandboxProcessResult {
        result("", code: 112, error: "Bad request.\nCould not find domain for user gui: 2001\n")
    }
    private static func result(_ output: String, code: Int32 = 0, error: String = "") -> SandboxProcessResult {
        .init(exitCode: code, standardOutput: Data(output.utf8), standardError: Data(error.utf8),
              standardOutputTruncated: false, standardErrorTruncated: false)
    }
    private final class Sequence: @unchecked Sendable {
        private let lock = NSLock()
        private var steps: [([String], SandboxProcessResult)]
        init(_ steps: [([String], SandboxProcessResult)]) { self.steps = steps }
        var remaining: Int { lock.withLock { steps.count } }
        func next(_ arguments: [String]) throws -> SandboxProcessResult {
            try lock.withLock {
                guard let step = steps.first, step.0 == arguments else { throw UnexpectedCommand() }
                steps.removeFirst()
                return step.1
            }
        }
        private struct UnexpectedCommand: Error {}
    }
}
