import Darwin
import Foundation
import SandboxCore
import SandboxRuntime

/// Selected-user source owner. Holds the template lock before the broker lock;
/// native config/run-owner locks belong to the spawned VM process, not this scope.
final class LumeInstallerBootSource {
    private let storage: LumePrivilegedSourceDirectory
    private let directory: LumePrivilegedSourceDirectory
    private let templateLock: Int32
    let request: LumeInstallerBootRequest
    let candidate: LumeReservedCandidateRecord

    init(storage: URL, request: LumeInstallerBootRequest) throws {
        candidate = try request.validate(); self.request = request
        self.storage = try .init(path: storage, ownerUID: geteuid(), ownerGID: getegid())
        directory = try self.storage.child(candidate.source.name)
        let lock = try directory.openPersistentLock(".darkbloom-template.lock", privateMode: true, createIfMissing: false)
        do {
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw SandboxRuntimeError.unsupported("base preparation is already active") }
            _ = try directory.metadata(lock, name: ".darkbloom-template.lock", maximumBytes: 0)
        } catch { close(lock); throw error }
        templateLock = lock
    }
    deinit { close(templateLock) }

    func validate(requireStagedSnapshot: Bool) throws {
        try storage.validate(); try directory.validate()
        _ = try directory.metadata(templateLock, name: ".darkbloom-template.lock", maximumBytes: 0)
        for name in [".provisioning", "resize.lock.json", "disk.img.pre-resize", "config.json.pre-resize",
                     SandboxGuestTemplateReceipt.fileName, ".darkbloom-guest", LumeInstalledCandidateCheckpoint.fileName] {
            try directory.requireAbsent(name)
        }
        try LumeOfflineOperationFence.requireAbsent(directory: directory.descriptor, name: candidate.source.name)
        guard try directory.readRecord(LumeInstalledCandidateCheckpoint.reservationFileName) == request.reservationData else {
            throw SandboxRuntimeError.unsupported("installer reservation changed")
        }
        let (source, resources) = try LumeVirtualMachineOwnership.inspectRawBaseMarker(
            directory.readRecord(LumeVirtualMachineOwnership.fileName), name: candidate.source.name)
        guard source == candidate.source, resources.cpuCount == candidate.resources.cpuCount,
              resources.memoryBytes == candidate.resources.memoryBytes, resources.diskBytes == request.stagedDisk.size else {
            throw SandboxRuntimeError.unsupported("installer source ownership or resources changed")
        }
        let file = try directory.openFile("disk.img", allowEmpty: false)
        defer { close(file) }
        let disk = try LumeCandidateDiskIdentity(directory.metadata(file, name: "disk.img", allowEmpty: false))
        guard disk.device == request.stagedDisk.device, disk.inode == request.stagedDisk.inode,
              disk.size == request.stagedDisk.size, !requireStagedSnapshot || disk == request.stagedDisk else {
            throw SandboxRuntimeError.unsupported("installer image differs from the staged snapshot")
        }
        try directory.validate(); try storage.validate()
    }

    func requireObserved(_ record: SandboxVirtualMachineRecord?, stopped: Bool) throws {
        guard let record, record.name == candidate.source.name, !stopped || record.state == .stopped,
              record.cpuCount == candidate.resources.cpuCount, record.memoryBytes == candidate.resources.memoryBytes,
              record.diskBytes == request.stagedDisk.size else { throw SandboxRuntimeError.unsupported("installer source state or resources are unproven") }
    }
}
