import Darwin
import Foundation
import SandboxCore
import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

final class LumeBaseImageSourceLocksTests: XCTestCase {
    func testHoldsExistingBrokerAndNativeLocksAndPreservesThemOnReopen() throws {
        let f = try fixture()
        var identities: [String: ino_t] = [:]
        let paths = [f.vm.virtualMachineDirectory.appendingPathComponent(".darkbloom-template.lock"),
                     f.vm.storage.appendingPathComponent(".darkbloom-runtime/locks/" + f.vm.virtualMachineName + ".lock"),
                     f.vm.storage.appendingPathComponent("." + f.vm.virtualMachineName + ".resize.guard"),
                     f.vm.virtualMachineDirectory.appendingPathComponent("config.json")]
        do {
            let locks = try f.acquire()
            try locks.validateUnchanged()
            for path in paths {
                let probe = open(path.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
                XCTAssertGreaterThanOrEqual(probe, 0)
                if probe >= 0 {
                    XCTAssertNotEqual(flock(probe, LOCK_EX | LOCK_NB), 0)
                    var info = stat(); XCTAssertEqual(fstat(probe, &info), 0)
                    identities[path.path] = info.st_ino
                    close(probe)
                }
            }
            XCTAssertThrowsError(try f.acquire())
            try locks.validateUnchanged()
        }
        let reopened = try f.acquire()
        try reopened.validateUnchanged()
        for path in paths {
            var info = stat(); XCTAssertEqual(lstat(path.path, &info), 0)
            XCTAssertEqual(info.st_ino, identities[path.path])
        }
    }

    func testSnapshotChangesAreDistinctFromReplacedImageIdentity() throws {
        let f = try fixture(), locks = try f.acquire()
        let file = try FileHandle(forWritingTo: f.image)
        try file.write(contentsOf: Data("changed".utf8)); try file.close()
        XCTAssertThrowsError(try locks.validateUnchanged())
        let changed = try locks.currentDiskIdentityAfterOwnedIO()
        XCTAssertEqual(changed.inode, f.disk.inode)
        XCTAssertNotEqual(changed, f.disk)
        try FileManager.default.moveItem(at: f.image, to: f.image.appendingPathExtension("retained"))
        try Data("replacement".utf8).write(to: f.image)
        XCTAssertThrowsError(try locks.currentDiskIdentityAfterOwnedIO())
    }

    func testChangedSourceOrPreparedArtifactsInvalidateLiveScope() throws {
        for name in [LumeVirtualMachineOwnership.fileName, LumeInstalledCandidateCheckpoint.reservationFileName,
                     ".provisioning", "resize.lock.json", "disk.img.pre-resize", "config.json.pre-resize",
                     SandboxGuestTemplateReceipt.fileName, ".darkbloom-guest", LumeInstalledCandidateCheckpoint.fileName] {
            let f = try fixture(), locks = try f.acquire()
            let path = f.vm.virtualMachineDirectory.appendingPathComponent(name)
            try Data("unexpected".utf8).write(to: path)
            XCTAssertEqual(chmod(path.path, 0o600), 0)
            XCTAssertThrowsError(try locks.validateIdentity(), name)
        }
    }

    func testSymlinkSharedAndHardlinkedImagesAreRejectedWithoutChangingThem() throws {
        for mutation in ["symlink", "shared", "hardlink"] {
            let f = try fixture()
            let alias = f.image.appendingPathExtension("alias")
            if mutation == "symlink" {
                try FileManager.default.moveItem(at: f.image, to: alias)
                try FileManager.default.createSymbolicLink(at: f.image, withDestinationURL: alias)
            } else if mutation == "hardlink" { try FileManager.default.linkItem(at: f.image, to: alias) }
            else { XCTAssertEqual(chmod(f.image.path, 0o644), 0) }
            XCTAssertThrowsError(try f.acquire(), mutation)
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.image.path))
        }
    }

    func testReplacedNativeOwnerLockAndSourceDirectoryAreRejected() throws {
        for replaceDirectory in [false, true] {
            let f = try fixture(), locks = try f.acquire()
            let path = replaceDirectory ? f.vm.virtualMachineDirectory : f.ownerLock
            try FileManager.default.moveItem(at: path, to: path.appendingPathExtension("old"))
            if replaceDirectory {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            } else { try Data().write(to: path); XCTAssertEqual(chmod(path.path, 0o600), 0) }
            XCTAssertThrowsError(try locks.validateIdentity())
        }
    }

    func testRawMarkerDecoderRejectsLegacyAndMixedOwnershipRatherThanRelabelingIt() throws {
        let f = try fixture()
        let original = try Data(contentsOf: f.vm.ownershipMarker)
        XCTAssertEqual(try LumeVirtualMachineOwnership.inspectRawBaseMarker(original, name: f.vm.virtualMachineName).0.kind, .appleRestore)
        for (key, value) in [("sourceKind", "restore_image"), ("ownerKind", "sandbox"), ("unattendedPreset", "tahoe")] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            object[key] = value
            XCTAssertThrowsError(try LumeVirtualMachineOwnership.inspectRawBaseMarker(
                JSONSerialization.data(withJSONObject: object), name: f.vm.virtualMachineName))
        }
        let duplicate = Data("{\"name\":\"duplicate\",".utf8) + original.dropFirst()
        XCTAssertThrowsError(try LumeVirtualMachineOwnership.inspectRawBaseMarker(duplicate, name: f.vm.virtualMachineName))
    }

    func testRootEntryPointRejectsUnprivilegedCallerBeforeMachineAuthorityAccess() throws {
        guard geteuid() != 0 else { throw XCTSkip("nonroot entrypoint rejection requires an unprivileged test process") }
        let f = try fixture()
        XCTAssertThrowsError(try LumeRootBaseImageGuard(storage: f.vm.storage, name: f.vm.virtualMachineName,
            ownerUID: geteuid(), ownerGID: getegid(), reservationData: f.reservation, expectedDisk: f.disk)) { error in
            XCTAssertTrue(String(describing: error).contains("require the root operator"))
        }
    }

    private func fixture() throws -> LumeRootSourceTestFixture {
        let f = try LumeRootSourceTestFixture(); addTeardownBlock { f.remove() }; return f
    }
}
