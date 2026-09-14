import Foundation
import SandboxRuntime
@testable import SandboxGuestRuntime
import XCTest

final class GuestTenantDomainStabilizationTests: XCTestCase {
    private var empty: SandboxProcessResult { Self.result(GuestDomainTestFixture.observed) }
    private var pending: SandboxProcessResult {
        Self.result(GuestDomainTestFixture.observed.replacingOccurrences(of: "\tservices = {",
            with: "\tpending requests = {\n\t\tcaller = (dead-on-arrival).538, event = 1\n\t}\n\tservices = {"))
    }

    func testPendingRequestsMustDisappearBeforeVerificationSucceeds() async throws {
        XCTAssertFalse(GuestTenantDomains.quiescent(pending, domain: "user/2001", after: .init(userDomainBootedOut: true)))
        let sequence = Sequence([
            (["print", "gui/2001"], Self.absentGUI),
            (["print", "user/2001"], pending),
            (["print", "user/2001"], empty),
        ])
        try await GuestTenantDomains.verifyQuiescent(after: .init(userDomainBootedOut: true),
            run: { try sequence.next($0) }, pause: {})
        XCTAssertEqual(sequence.remaining, 0)
    }

    func testRacingRemovalRequiresAnActualSuccessfulRetry() async throws {
        let sequence = Sequence([
            (["print", "gui/2001"], Self.absentGUI),
            (["print", "user/2001"], empty),
            (["bootout", "user/2001"], Self.result("", code: 37, error: "operation in progress")),
            (["print", "user/2001"], pending),
            (["print", "user/2001"], empty),
            (["bootout", "user/2001"], Self.result("")),
        ])
        let removal = try await GuestTenantDomains.remove(run: { try sequence.next($0) }, pause: {})
        XCTAssertTrue(removal.userDomainBootedOut)
        XCTAssertEqual(sequence.remaining, 0)
    }

    func testPersistentPendingRequestsRemainUnprovenAfterBoundedRetries() async {
        let sequence = Sequence([(["print", "gui/2001"], Self.absentGUI)]
            + Array(repeating: (["print", "user/2001"], pending), count: 8))
        do {
            try await GuestTenantDomains.verifyQuiescent(after: .init(userDomainBootedOut: true),
                run: { try sequence.next($0) }, pause: {})
            XCTFail("pending requests must not count as empty")
        } catch {
            XCTAssertEqual(error as? GuestTenantDomains.VerificationFailure, .userDomainFormatUnproven)
        }
        XCTAssertEqual(sequence.remaining, 0)
    }

    func testEmptyOutputCannotSubstituteForPriorRemoval() async {
        let sequence = Sequence([(["print", "gui/2001"], Self.absentGUI)]
            + Array(repeating: (["print", "user/2001"], empty), count: 8))
        do {
            try await GuestTenantDomains.verifyQuiescent(after: .init(userDomainBootedOut: false),
                run: { try sequence.next($0) }, pause: {})
            XCTFail("removal proof is still required")
        } catch {
            XCTAssertEqual(error as? GuestTenantDomains.VerificationFailure, .userDomainRemovalUnproven)
        }
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
