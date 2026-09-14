import Darwin
import Foundation
import SandboxCore
import SandboxRuntime
@testable import SandboxRuntimeLume

struct LumeRootSourceTestFixture {
    let vm: FakeLumeFixture
    let reservation: Data
    let disk: LumeCandidateDiskIdentity
    var image: URL { vm.virtualMachineDirectory.appendingPathComponent("disk.img") }
    var ownerLock: URL { vm.virtualMachineDirectory.appendingPathComponent(".run-owner.lock") }

    init() throws {
        vm = try FakeLumeFixture()
        let specification = try SandboxVirtualMachineSpecification(name: vm.virtualMachineName,
            resources: .macOSSmall(), imageSource: .appleRestore(url: vm.restoreImage),
            diskBytes: 100 * SandboxResourcePolicy.gibibyte)
        try LumeVirtualMachineOwnership.write(specification: specification, owner: .baseTemplate, to: vm.virtualMachineDirectory)
        let source = try LumeVirtualMachineOwnership.inspectRawBaseMarker(
            Data(contentsOf: vm.ownershipMarker), name: vm.virtualMachineName).0
        let path = vm.virtualMachineDirectory.appendingPathComponent("disk.img")
        guard FileManager.default.createFile(atPath: path.path, contents: nil,
            attributes: [.posixPermissions: 0o600]) else { throw POSIXError(.EIO) }
        let file = try FileHandle(forWritingTo: path)
        try file.truncate(atOffset: specification.diskBytes); try file.close()
        var info = stat()
        guard lstat(path.path, &info) == 0 else { throw POSIXError(.EIO) }
        disk = .init(info)
        let payload = SandboxGuestPayloadIdentity(releaseManifestSHA256: String(repeating: "a", count: 64),
            guestSHA256: String(repeating: "b", count: 64), bootstrapSHA256: String(repeating: "c", count: 64),
            launchdSHA256: String(repeating: "d", count: 64), installerSHA256: String(repeating: "e", count: 64))
        func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
        reservation = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "phase": "awaitingRootInstallation", "candidateID": UUID().uuidString,
            "bootstrapAttemptID": UUID().uuidString, "source": object(source), "payload": object(payload),
            "resources": object(specification.resources), "disk": object(disk), "installed": false, "qualified": false,
        ], options: [.sortedKeys])
        let reservationPath = vm.virtualMachineDirectory.appendingPathComponent(LumeInstalledCandidateCheckpoint.reservationFileName)
        try reservation.write(to: reservationPath)
        guard chmod(reservationPath.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        let prepare = vm.virtualMachineDirectory.appendingPathComponent(".darkbloom-template.lock")
        try Data().write(to: prepare); guard chmod(prepare.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        let config = vm.virtualMachineDirectory.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: config); guard chmod(config.path, 0o644) == 0 else { throw POSIXError(.EIO) }
        let operation = try LumeVirtualMachineOperationLock(workspace: .init(storageDirectory: vm.storage),
            name: vm.virtualMachineName, operation: "fixture")
        withExtendedLifetime(operation) {}
    }

    func acquire() throws -> LumeBaseImageSourceLocks {
        try .init(storage: vm.storage, name: vm.virtualMachineName, ownerUID: geteuid(), ownerGID: getegid(),
            reservationData: reservation, expectedDisk: disk)
    }
    func remove() { try? vm.remove() }
}
