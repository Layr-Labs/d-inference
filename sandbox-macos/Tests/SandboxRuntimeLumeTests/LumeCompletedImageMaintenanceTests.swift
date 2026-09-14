import Darwin
import Foundation
import HostRuntimeCoordination
@testable import SandboxRuntimeLume
import XCTest

final class LumeCompletedImageMaintenanceTests: XCTestCase {
    func testCompletedProofRequiresFenceRemovalAndBindsTheExactIntent() throws {
        let fixture = try LumeRootSourceTestFixture(); defer { fixture.remove() }
        let intent = try HostRuntimeMaintenanceIntent(operationID: UUID(), journalSHA256: String(repeating: "a", count: 64))
        var saved: LumeImageMaintenanceCleanup?
        do {
            let source = try fixture.acquire()
            let state = try LumeImageMaintenanceState(source: source, intent: intent, recovering: false)
            try state.removeFenceAfterVerifiedCleanup { cleanup in
                saved = cleanup
                let proof = try LumeCompletedImageMaintenance(source: source, intent: intent, cleanup: cleanup)
                XCTAssertThrowsError(try proof.validate(), "persistence alone cannot prove fence removal")
            }
        }
        let source = try fixture.acquire(), cleanup = try XCTUnwrap(saved)
        let proof = try LumeCompletedImageMaintenance(source: source, intent: intent, cleanup: cleanup)
        try proof.validate()
        let otherIntent = try HostRuntimeMaintenanceIntent(operationID: UUID(), journalSHA256: intent.journalSHA256)
        XCTAssertThrowsError(try LumeCompletedImageMaintenance(source: source, intent: otherIntent, cleanup: cleanup).validate())
        try proof.validate()
    }

    func testCompletedProofRejectsLaterDiskChangesAndNeverRecreatesAFence() throws {
        let fixture = try LumeRootSourceTestFixture(); defer { fixture.remove() }
        let intent = try HostRuntimeMaintenanceIntent(operationID: UUID(), journalSHA256: String(repeating: "b", count: 64))
        let source = try fixture.acquire()
        let state = try LumeImageMaintenanceState(source: source, intent: intent, recovering: false)
        var saved: LumeImageMaintenanceCleanup?
        try state.removeFenceAfterVerifiedCleanup { saved = $0 }
        let proof = try LumeCompletedImageMaintenance(source: source, intent: intent, cleanup: XCTUnwrap(saved))
        try proof.validate()
        let file = try FileHandle(forWritingTo: fixture.image)
        try file.write(contentsOf: Data("unexpected post-staging modification".utf8)); try file.close()
        XCTAssertThrowsError(try proof.validate())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.vm.virtualMachineDirectory
            .appendingPathComponent(".darkbloom-offline.json").path))
    }

    func testRootEntryCannotReadAnotherUsersReservationFromAnOrdinaryProcess() throws {
        guard getuid() != 0 else { throw XCTSkip("requires an ordinary test process") }
        XCTAssertThrowsError(try LumeRootBaseImageGuard.readReservation(storage: URL(fileURLWithPath: "/not-read"),
            name: "base", ownerUID: getuid(), ownerGID: getgid()))
    }
}
