import Darwin
import CryptoKit
import Foundation
import SandboxCore
import SandboxRuntime

/// Holds existing broker locks followed by the audited native resize/config/
/// process-owner locks. This does not mount an image or prove no open image IO.
/// Root's caller additionally holds machine EX; tests use an owned namespace.
final class LumeBaseImageSourceLocks {
    enum SnapshotPolicy { case unchanged, rootMaintenanceRecovery, captureClaimedInstaller }
    private struct Held {
        let directory: LumePrivilegedSourceDirectory
        let name: String
        let descriptor: Int32
        let privateMode: Bool
    }
    private let storage: LumePrivilegedSourceDirectory
    private let directory: LumePrivilegedSourceDirectory
    private var held: [Held] = []
    private var imageDescriptor: Int32 = -1
    private let reservationData: Data
    private let reservation: LumeReservedCandidateRecord
    private let bootClaim: LumeInstallerBootRequest?
    private(set) var initialDisk: LumeCandidateDiskIdentity
    var imageURL: URL { directory.path.appendingPathComponent("disk.img") }
    var retainedImageDescriptor: Int32 { imageDescriptor }
    var directoryDescriptor: Int32 { directory.descriptor }
    var reservationSHA256: String { SHA256.hash(data: reservationData).map { String(format: "%02x", $0) }.joined() }
    var baseSource: SandboxGuestBaseSource { reservation.source }

    init(storage: URL, name: String, ownerUID: uid_t, ownerGID: gid_t,
         reservationData: Data, expectedDisk: LumeCandidateDiskIdentity,
         snapshotPolicy: SnapshotPolicy = .unchanged, bootClaim: LumeInstallerBootRequest? = nil) throws {
        guard SandboxVirtualMachineNamePolicy.isValid(name), reservationData.count <= 16 * 1024,
              expectedDisk.isValid else { throw failure() }
        try SandboxJSONIntegrity.requireNoDuplicateKeys(reservationData)
        let reservation = try JSONDecoder().decode(LumeReservedCandidateRecord.self, from: reservationData)
        guard reservation.schemaVersion == 1, reservation.phase == "awaitingRootInstallation",
              !reservation.installed, !reservation.qualified, reservation.source.kind == .appleRestore,
              reservation.source.isValid, reservation.source.name == name, reservation.payload.isValid,
              reservation.candidateID != reservation.bootstrapAttemptID,
              reservation.candidateID != reservation.source.installationID,
              reservation.bootstrapAttemptID != reservation.source.installationID,
              reservation.disk.isValid, reservation.disk.device == expectedDisk.device,
              reservation.disk.inode == expectedDisk.inode, reservation.disk.size == expectedDisk.size else { throw failure() }
        if let bootClaim {
            guard bootClaim.reservationData == reservationData, try bootClaim.validate() == reservation else { throw failure() }
        }
        self.bootClaim = bootClaim
        self.reservation = reservation; self.reservationData = reservationData; initialDisk = expectedDisk
        self.storage = try LumePrivilegedSourceDirectory(path: storage, ownerUID: ownerUID, ownerGID: ownerGID)
        directory = try self.storage.child(name)
        do {
            let broker = try self.storage.child(".darkbloom-runtime").child("locks")
            try acquire(directory, name: ".darkbloom-template.lock")
            try acquire(broker, name: name + ".lock")
            try acquire(self.storage, name: "." + name + ".resize.guard", privateMode: false, create: true)
            try acquire(directory, name: "config.json", privateMode: false)
            try acquire(directory, name: ".run-owner.lock", create: true, posix: true)
            imageDescriptor = try directory.openFile("disk.img", allowEmpty: false)
            switch snapshotPolicy {
            case .unchanged: try validateUnchanged()
            case .rootMaintenanceRecovery: try validateIdentity()
            case .captureClaimedInstaller:
                guard bootClaim != nil else { throw failure() }
                try validateIdentity()
                // Capture only while all native/source locks and the enclosing
                // root EX lease are held. Recovery reuses this journaled value.
                initialDisk = try diskIdentity()
                try validateUnchanged()
            }
        } catch {
            closeOwnedFiles()
            throw error
        }
    }

    deinit { closeOwnedFiles() }

    /// Used only when the enclosing root scope is ending, before machine EX
    /// ownership is released. Repeated closure is harmless.
    func closeForScopeEnd() { closeOwnedFiles() }

    func validateIdentity() throws {
        try storage.validate(); try directory.validate()
        for item in held {
            try item.directory.validate()
            let info = try item.directory.metadata(item.descriptor, name: item.name,
                privateMode: item.privateMode, maximumBytes: 64 * 1024)
            guard info.st_mode & 0o600 == 0o600 else { throw failure() }
        }
        for name in [".provisioning", "resize.lock.json", "disk.img.pre-resize", "config.json.pre-resize",
                     SandboxGuestTemplateReceipt.fileName, ".darkbloom-guest", LumeInstalledCandidateCheckpoint.fileName] {
            try directory.requireAbsent(name)
        }
        if let bootClaim {
            guard try directory.readRecord(LumeInstallerBootClaim.fileName, maximumBytes: 32 * 1024)
                == LumeInstallerBootClaim.encoded(bootClaim) else { throw failure() }
        } else { try directory.requireAbsent(LumeInstallerBootClaim.fileName) }
        guard try directory.readRecord(LumeInstalledCandidateCheckpoint.reservationFileName) == reservationData else { throw failure() }
        let (source, resources) = try LumeVirtualMachineOwnership.inspectRawBaseMarker(
            directory.readRecord(LumeVirtualMachineOwnership.fileName), name: reservation.source.name)
        guard source == reservation.source, resources.cpuCount == reservation.resources.cpuCount,
              resources.memoryBytes == reservation.resources.memoryBytes, resources.diskBytes == reservation.disk.size else { throw failure() }
        let disk = try diskIdentity()
        guard disk.device == initialDisk.device, disk.inode == initialDisk.inode, disk.size == initialDisk.size else { throw failure() }
        // A parent can be renamed while its descriptors remain valid. Bind the
        // source namespace again after reading its records and image metadata.
        try storage.validate(); try directory.validate()
    }

    func validateUnchanged() throws {
        try validateIdentity()
        guard try diskIdentity() == initialDisk else { throw failure() }
    }

    func currentDiskIdentityAfterOwnedIO() throws -> LumeCandidateDiskIdentity {
        try validateIdentity()
        return try diskIdentity()
    }

    func requireReservation(_ encodedCandidate: Data) throws {
        guard encodedCandidate.count <= 16 * 1024 else { throw failure() }
        try SandboxJSONIntegrity.requireNoDuplicateKeys(encodedCandidate)
        guard try JSONDecoder().decode(LumeReservedCandidateRecord.self, from: encodedCandidate) == reservation else {
            throw failure()
        }
        try validateIdentity()
    }

    private func diskIdentity() throws -> LumeCandidateDiskIdentity {
        let info = try directory.metadata(imageDescriptor, name: "disk.img", allowEmpty: false)
        guard info.st_mode & 0o600 == 0o600 else { throw failure() }
        return .init(info)
    }

    private func acquire(_ directory: LumePrivilegedSourceDirectory, name: String,
                         privateMode: Bool = true, create: Bool = false, posix: Bool = false) throws {
        let file = try directory.openPersistentLock(name, privateMode: privateMode, createIfMissing: create)
        do {
            if posix {
                var lock = Darwin.flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
                while fcntl(file, F_SETLK, &lock) != 0 {
                    guard errno == EINTR else { throw failure() }
                }
            } else {
                while flock(file, LOCK_EX | LOCK_NB) != 0 {
                    guard errno == EINTR else { throw failure() }
                }
            }
            _ = try directory.metadata(file, name: name, privateMode: privateMode, maximumBytes: 64 * 1024)
            held.append(.init(directory: directory, name: name, descriptor: file, privateMode: privateMode))
        } catch { close(file); throw error }
    }

    private func closeOwnedFiles() {
        if imageDescriptor >= 0 { close(imageDescriptor); imageDescriptor = -1 }
        // Do not reopen a run-owner file during validation: closing ANY other
        // fd for that inode would release this process's POSIX record lock.
        for item in held.reversed() { close(item.descriptor) }
        held.removeAll()
    }
}

private func failure() -> SandboxRuntimeError { .unsupported("raw base source or native image ownership is unavailable or changed") }
