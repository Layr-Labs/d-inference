import Darwin
import Foundation
import HostRuntimeCoordination
@testable import SandboxRuntimeLume
import XCTest

final class LumeImageMaintenanceTests: XCTestCase {
    func testInterruptedIORecoversOnlyWithTheOriginalImageFence() throws {
        let f = try fixture(), intent = try intent()
        do {
            let source = try f.acquire()
            let state = try LumeImageMaintenanceState(source: source, intent: intent, recovering: false)
            try state.validateForOfflineIO()
            try writeImage(f)
            XCTAssertThrowsError(try source.validateUnchanged())
            try state.validateForOfflineIO()
        }
        XCTAssertTrue(exists(f))
        XCTAssertThrowsError(try f.acquire())
        let source = try recover(f)
        let state = try LumeImageMaintenanceState(source: source, intent: intent, recovering: true)
        try state.validateForOfflineIO()
        XCTAssertThrowsError(try LumeImageMaintenanceState(source: source, intent: self.intent(), recovering: true))
        XCTAssertTrue(exists(f))
    }

    func testRecoveryBeforeImagePublicationRequiresTheOriginalSnapshot() throws {
        for changed in [false, true] {
            let f = try fixture()
            if changed { try writeImage(f) }
            let source = try recover(f)
            if changed {
                XCTAssertThrowsError(try LumeImageMaintenanceState(source: source, intent: intent(), recovering: true))
                XCTAssertFalse(exists(f))
            } else {
                let state = try LumeImageMaintenanceState(source: source, intent: intent(), recovering: true)
                try state.validateForOfflineIO(); XCTAssertTrue(exists(f))
            }
        }
    }

    func testJournalFailureFreezesIOAndRetainsFenceUntilCompletionRetry() throws {
        let f = try fixture(), source = try f.acquire()
        let state = try LumeImageMaintenanceState(source: source, intent: intent(), recovering: false)
        try writeImage(f)
        var saved: LumeImageMaintenanceCleanup?
        XCTAssertThrowsError(try state.removeFenceAfterVerifiedCleanup { record in
            saved = record
            XCTAssertTrue(self.exists(f), "the image fence must outlive completion persistence")
            throw POSIXError(.EIO)
        })
        XCTAssertTrue(exists(f))
        XCTAssertThrowsError(try state.validateForOfflineIO())
        try state.removeFenceAfterVerifiedCleanup { record in
            XCTAssertEqual(record, saved)
            XCTAssertThrowsError(try state.validateForOfflineIO())
        }
        XCTAssertFalse(exists(f))
        XCTAssertThrowsError(try state.validateForOfflineIO())
    }

    func testRecordedCompletionRecoversWithEitherImageFenceStateAndNeverReopensIO() throws {
        for imageAlreadyRemoved in [false, true] {
            let f = try fixture(), intent = try intent()
            var saved: LumeImageMaintenanceCleanup?
            do {
                let source = try f.acquire()
                let state = try LumeImageMaintenanceState(source: source, intent: intent, recovering: false)
                try writeImage(f)
                do {
                    try state.removeFenceAfterVerifiedCleanup { record in
                        saved = record
                        if !imageAlreadyRemoved { throw POSIXError(.EIO) }
                    }
                } catch { XCTAssertFalse(imageAlreadyRemoved) }
            }
            XCTAssertEqual(exists(f), !imageAlreadyRemoved)
            let source = try recover(f), checkpoint = try XCTUnwrap(saved)
            let state = try LumeImageMaintenanceState(source: source, intent: intent, recovering: true, cleanup: checkpoint)
            XCTAssertThrowsError(try state.validateForOfflineIO())
            try state.removeFenceAfterVerifiedCleanup { XCTAssertEqual($0, checkpoint) }
            XCTAssertFalse(exists(f))
        }
    }

    func testCompletionRejectsDiskChangesDuringPersistenceAndAfterFenceRemoval() throws {
        let f = try fixture(), intent = try intent()
        var saved: LumeImageMaintenanceCleanup?
        do {
            let state = try LumeImageMaintenanceState(source: f.acquire(), intent: intent, recovering: false)
            XCTAssertThrowsError(try state.removeFenceAfterVerifiedCleanup { record in
                saved = record; try self.writeImage(f)
            })
            XCTAssertTrue(exists(f))
            XCTAssertThrowsError(try state.validateForOfflineIO())
        }
        let source = try recover(f)
        XCTAssertThrowsError(try LumeImageMaintenanceState(source: source, intent: intent,
            recovering: true, cleanup: XCTUnwrap(saved)))
        try FileManager.default.removeItem(at: fence(f))
        XCTAssertThrowsError(try LumeImageMaintenanceState(source: source, intent: intent,
            recovering: true, cleanup: XCTUnwrap(saved)))
        XCTAssertFalse(exists(f))
    }

    func testLiveStateRejectsIdenticalFenceReplacementAndDoesNotRemoveIt() throws {
        let f = try fixture()
        let state = try LumeImageMaintenanceState(source: f.acquire(), intent: intent(), recovering: false)
        let old = fence(f).appendingPathExtension("old")
        try FileManager.default.moveItem(at: fence(f), to: old)
        try Data(contentsOf: old).write(to: fence(f)); XCTAssertEqual(chmod(fence(f).path, 0o600), 0)
        XCTAssertThrowsError(try state.validateForOfflineIO())
        XCTAssertThrowsError(try state.removeFenceAfterVerifiedCleanup { _ in XCTFail("must validate before recording cleanup") })
        XCTAssertTrue(exists(f))
    }

    func testInvalidEntriesFailClosedWithoutReplacingThem() throws {
        for kind in ["fifo", "symlink", "directory", "empty", "shared", "hardlink", "malformed"] {
            let f = try fixture(), source = try f.acquire(), intent = try intent()
            let path = fence(f)
            switch kind {
            case "fifo": XCTAssertEqual(mkfifo(path.path, 0o600), 0)
            case "symlink": try FileManager.default.createSymbolicLink(at: path, withDestinationURL: f.image)
            case "directory": try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            case "empty", "malformed":
                try Data((kind == "empty" ? "" : "{").utf8).write(to: path)
                XCTAssertEqual(chmod(path.path, 0o600), 0)
            default:
                do { _ = try LumeImageMaintenanceState(source: source, intent: intent, recovering: false) }
                if kind == "shared" { XCTAssertEqual(chmod(path.path, 0o644), 0) }
                else { try FileManager.default.linkItem(at: path, to: path.appendingPathExtension("alias")) }
            }
            XCTAssertThrowsError(try LumeImageMaintenanceState(source: source, intent: intent, recovering: false), kind)
            XCTAssertThrowsError(try LumeImageMaintenanceState(source: source, intent: intent, recovering: true), kind)
            XCTAssertTrue(exists(f))
        }
    }

    func testRecoveryBindsOriginalDirectoryEvenWhenAllItsFilesAreMovedIntact() throws {
        let f = try fixture(), intent = try intent()
        do { _ = try LumeImageMaintenanceState(source: f.acquire(), intent: intent, recovering: false) }
        let path = f.vm.virtualMachineDirectory, old = path.appendingPathExtension("old")
        try FileManager.default.moveItem(at: path, to: old)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for child in try FileManager.default.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) {
            try FileManager.default.moveItem(at: child, to: path.appendingPathComponent(child.lastPathComponent))
        }
        let source = try recover(f)
        XCTAssertThrowsError(try LumeImageMaintenanceState(source: source, intent: intent, recovering: true))
        XCTAssertTrue(exists(f))
    }

    func testReservationBindingAllowsFormattingButRejectsDifferentCandidateAndDuplicateKeys() throws {
        let f = try fixture(), source = try f.acquire()
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: f.reservation) as? [String: Any])
        try source.requireReservation(JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]))
        value["candidateID"] = UUID().uuidString
        XCTAssertThrowsError(try source.requireReservation(JSONSerialization.data(withJSONObject: value)))
        XCTAssertThrowsError(try source.requireReservation(Data("{\"schemaVersion\":1,".utf8) + f.reservation.dropFirst()))
    }

    private func fixture() throws -> LumeRootSourceTestFixture {
        let f = try LumeRootSourceTestFixture(); addTeardownBlock { f.remove() }; return f
    }
    private func recover(_ f: LumeRootSourceTestFixture) throws -> LumeBaseImageSourceLocks {
        try .init(storage: f.vm.storage, name: f.vm.virtualMachineName, ownerUID: geteuid(), ownerGID: getegid(),
            reservationData: f.reservation, expectedDisk: f.disk, snapshotPolicy: .rootMaintenanceRecovery)
    }
    private func intent() throws -> HostRuntimeMaintenanceIntent {
        try .init(operationID: UUID(), journalSHA256: String(repeating: "a", count: 64))
    }
    private func fence(_ f: LumeRootSourceTestFixture) -> URL { f.vm.virtualMachineDirectory.appendingPathComponent(LumeOfflineOperationFence.fileName) }
    private func exists(_ f: LumeRootSourceTestFixture) -> Bool { var info = stat(); return lstat(fence(f).path, &info) == 0 }
    private func writeImage(_ f: LumeRootSourceTestFixture) throws {
        let file = try FileHandle(forWritingTo: f.image); defer { try? file.close() }
        try file.write(contentsOf: Data(UUID().uuidString.utf8)); try file.synchronize()
    }
}
