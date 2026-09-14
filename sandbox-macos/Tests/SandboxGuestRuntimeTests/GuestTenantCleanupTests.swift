import Foundation
import SandboxGuestProtocol
@testable import SandboxGuestRuntime
import XCTest

final class GuestTenantCleanupTests: XCTestCase {
    func testWorkerCreatedDomainIsRetiredBeforeReadiness() async throws {
        let state = Fixture()
        try await GuestTenantCleanup.run(operations: state.operations)
        XCTAssertTrue(state.verified)
        XCTAssertFalse(state.domainExists)
        XCTAssertEqual(state.workerCalls, 1)
    }

    func testProcessAppearingDuringDomainRemovalRequiresAnotherCleanup() async throws {
        let state = Fixture(respawnOnce: true)
        try await GuestTenantCleanup.run(operations: state.operations)
        XCTAssertTrue(state.verified)
        XCTAssertEqual(state.workerCalls, 2)
    }

    func testPersistentProcessesNeverReachDomainVerification() async {
        let state = Fixture(persistentProcesses: true)
        do {
            try await GuestTenantCleanup.run(operations: state.operations)
            XCTFail("expected uncertain cleanup")
        } catch {
            XCTAssertEqual((error as? GuestBootstrapDiagnostic)?.code,
                           "guest_bootstrap.tenant_process_inventory.policy_mismatch")
        }
        XCTAssertFalse(state.verified)
        XCTAssertEqual(state.workerCalls, 5)
    }

    func testWorkerFailureIsReportedWithoutClaimingCleanup() async {
        let state = Fixture(workerFails: true)
        do {
            try await GuestTenantCleanup.run(operations: state.operations)
            XCTFail("expected failed worker")
        } catch {
            XCTAssertEqual((error as? GuestBootstrapDiagnostic)?.code,
                           "guest_bootstrap.tenant_cleanup_worker.unavailable")
        }
        XCTAssertFalse(state.verified)
        XCTAssertEqual(state.workerCalls, 1)
    }

    private final class Fixture: @unchecked Sendable {
        private let lock = NSLock()
        private var domain = false
        private var workers = 0
        private var removals = 0
        private var processes = 0
        private var didVerify = false
        private let respawnOnce: Bool
        private let persistentProcesses: Bool
        private let workerFails: Bool

        init(respawnOnce: Bool = false, persistentProcesses: Bool = false, workerFails: Bool = false) {
            self.respawnOnce = respawnOnce; self.persistentProcesses = persistentProcesses; self.workerFails = workerFails
        }
        var verified: Bool { lock.withLock { didVerify } }
        var domainExists: Bool { lock.withLock { domain } }
        var workerCalls: Int { lock.withLock { workers } }

        var operations: GuestTenantCleanup.Operations {
            .init(removeDomains: { self.remove() }, cleanProcesses: { try self.clean() },
                  activeProcesses: { self.lock.withLock { self.processes } },
                  verifyDomains: { try self.verify($0) }, pause: {})
        }

        private func remove() -> GuestTenantDomains.Removal {
            lock.withLock {
                removals += 1
                let existed = domain; domain = false
                if respawnOnce && removals == 2 { processes = 1 }
                return .init(userDomainBootedOut: existed)
            }
        }
        private func clean() throws {
            try lock.withLock {
                workers += 1
                if workerFails { throw NSError(domain: "private-input-not-for-logs", code: 1) }
                domain = true
                processes = persistentProcesses ? 1 : 0
            }
        }
        private func verify(_ removal: GuestTenantDomains.Removal) throws {
            try lock.withLock {
                guard removal.userDomainBootedOut, !domain, processes == 0 else { throw GuestProtocolError.cleanupUncertain }
                didVerify = true
            }
        }
    }
}
