import Darwin
import Foundation
import HostRuntimeCoordination
@testable import SandboxRuntimeLume
import XCTest

final class LumeClaimedInstallerSourceTests: XCTestCase {
    func testCapturesPostBootSnapshotOnlyForExactConsumedClaim() throws {
        let f = try LumeRootSourceTestFixture(); defer { f.remove() }
        let request = request(f)
        try LumeInstallerBootClaim.publish(request, name: f.vm.virtualMachineName, storage: f.vm.storage)
        try write(f, "boot changed disk")
        XCTAssertThrowsError(try f.acquire())
        let source = try claimed(f, request: request, policy: .captureClaimedInstaller)
        XCTAssertNotEqual(source.initialDisk, f.disk)
        XCTAssertEqual(source.initialDisk.inode, f.disk.inode)
        try source.validateUnchanged()
    }

    func testWrongMissingOrChangedClaimCannotAuthorizeCollection() throws {
        let f = try LumeRootSourceTestFixture(); defer { f.remove() }
        let request = request(f)
        XCTAssertThrowsError(try claimed(f, request: request, policy: .captureClaimedInstaller))
        try LumeInstallerBootClaim.publish(request, name: f.vm.virtualMachineName, storage: f.vm.storage)
        let wrong = LumeInstallerBootRequest(reservationData: request.reservationData, stagedDisk: request.stagedDisk,
            runtimeSHA256: request.runtimeSHA256, maximumBootSeconds: 300, permitSHA256: String(repeating: "c", count: 64))
        XCTAssertThrowsError(try claimed(f, request: wrong, policy: .captureClaimedInstaller))
        let source = try claimed(f, request: request, policy: .captureClaimedInstaller)
        try Data("{}".utf8).write(to: f.vm.virtualMachineDirectory.appendingPathComponent(LumeInstallerBootClaim.fileName))
        XCTAssertThrowsError(try source.validateIdentity())
    }

    func testCollectionFenceRecoveryKeepsCapturedPostBootOrigin() throws {
        let f = try LumeRootSourceTestFixture(); defer { f.remove() }
        let request = request(f)
        try LumeInstallerBootClaim.publish(request, name: f.vm.virtualMachineName, storage: f.vm.storage)
        try write(f, "boot")
        let intent = try HostRuntimeMaintenanceIntent(operationID: UUID(), journalSHA256: String(repeating: "d", count: 64))
        let original: LumeCandidateDiskIdentity
        do {
            let source = try claimed(f, request: request, policy: .captureClaimedInstaller)
            original = source.initialDisk
            let state = try LumeImageMaintenanceState(source: source, intent: intent, recovering: false)
            try write(f, "collection")
            try state.validateForOfflineIO()
        }
        let source = try LumeBaseImageSourceLocks(storage: f.vm.storage, name: f.vm.virtualMachineName,
            ownerUID: geteuid(), ownerGID: getegid(), reservationData: f.reservation, expectedDisk: original,
            snapshotPolicy: .rootMaintenanceRecovery, bootClaim: request)
        let state = try LumeImageMaintenanceState(source: source, intent: intent, recovering: true)
        try state.validateForOfflineIO()
        try state.removeFenceAfterVerifiedCleanup { cleanup in XCTAssertEqual(cleanup.disk.inode, original.inode) }
        XCTAssertThrowsError(try state.validateForOfflineIO())
    }

    func testCaptureWithoutClaimAndUnprivilegedRootEntryAreRejected() throws {
        let f = try LumeRootSourceTestFixture(); defer { f.remove() }
        XCTAssertThrowsError(try LumeBaseImageSourceLocks(storage: f.vm.storage, name: f.vm.virtualMachineName,
            ownerUID: geteuid(), ownerGID: getegid(), reservationData: f.reservation, expectedDisk: f.disk,
            snapshotPolicy: .captureClaimedInstaller))
        if geteuid() != 0 {
            XCTAssertThrowsError(try LumeRootBaseImageGuard.claimedInstaller(storage: f.vm.storage,
                ownerUID: geteuid(), ownerGID: getegid(), request: request(f)))
        }
    }

    private func request(_ f: LumeRootSourceTestFixture) -> LumeInstallerBootRequest {
        .init(reservationData: f.reservation, stagedDisk: f.disk, runtimeSHA256: String(repeating: "a", count: 64),
            maximumBootSeconds: 300, permitSHA256: String(repeating: "b", count: 64))
    }
    private func claimed(_ f: LumeRootSourceTestFixture, request: LumeInstallerBootRequest,
                         policy: LumeBaseImageSourceLocks.SnapshotPolicy) throws -> LumeBaseImageSourceLocks {
        try .init(storage: f.vm.storage, name: f.vm.virtualMachineName, ownerUID: geteuid(), ownerGID: getegid(),
            reservationData: f.reservation, expectedDisk: f.disk, snapshotPolicy: policy, bootClaim: request)
    }
    private func write(_ f: LumeRootSourceTestFixture, _ value: String) throws {
        let file = try FileHandle(forWritingTo: f.image)
        try file.write(contentsOf: Data(value.utf8)); try file.close()
    }
}
