import Darwin
import Foundation
@testable import HostRuntimeCoordination
import XCTest

final class HostRuntimeInheritedMaintenanceTests: XCTestCase {
    func testRetainedMaintenanceDescriptorOutlivesOriginalScopeAndKeepsEX() throws {
        let f = try HostRuntimeTestFixture(); defer { f.remove() }
        let intent = try HostRuntimeMaintenanceIntent(operationID: UUID(), journalSHA256: String(repeating: "a", count: 64))
        var retained: HostRuntimeLease?
        do {
            let original = try f.authority.acquireSandbox().beginRootMaintenance(intent)
            retained = try original.runtimeLease.withInheritedDescriptor {
                try f.authority.retainRootMaintenanceDescriptor($0, intent: intent)
            }
            try retained?.validateExclusive()
        }
        XCTAssertThrowsError(try f.authority.recoverRootMaintenance(intent)) {
            XCTAssertEqual($0 as? HostRuntimeOwnershipError, .occupied)
        }
        retained = nil
        let recovered = try f.authority.recoverRootMaintenance(intent)
        try recovered.finishAfterVerifiedCleanup()
    }

    func testWrongIntentAndUnrelatedDescriptorCannotBeAdoptedOrCloseOriginal() throws {
        let f = try HostRuntimeTestFixture(); defer { f.remove() }
        let intent = try HostRuntimeMaintenanceIntent(operationID: UUID(), journalSHA256: String(repeating: "b", count: 64))
        let scope = try f.authority.acquireSandbox().beginRootMaintenance(intent)
        try scope.runtimeLease.withInheritedDescriptor { descriptor in
            let wrong = try HostRuntimeMaintenanceIntent(operationID: UUID(), journalSHA256: intent.journalSHA256)
            XCTAssertThrowsError(try f.authority.retainRootMaintenanceDescriptor(descriptor, intent: wrong))
            XCTAssertGreaterThanOrEqual(fcntl(descriptor, F_GETFD), 0)
        }
        let unrelated = open(f.root.appendingPathComponent("unrelated").path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o660)
        XCTAssertGreaterThanOrEqual(unrelated, 0); defer { if unrelated >= 0 { close(unrelated) } }
        XCTAssertEqual(fchmod(unrelated, 0o660), 0)
        XCTAssertThrowsError(try f.authority.retainRootMaintenanceDescriptor(unrelated, intent: intent))
        XCTAssertGreaterThanOrEqual(fcntl(unrelated, F_GETFD), 0)
        try scope.validate()
    }
}
