import Darwin
import Foundation
import HostRuntimeCoordination
import SandboxCore
import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

/// Private synthetic evidence plus real authority/lease locks. No VM is run.
final class LumeQualificationFixture: @unchecked Sendable {
    let vm: FakeLumeFixture
    let release: LumeGuestTemplateTestFixture
    let clock = LumeTestWallClock(Date(timeIntervalSince1970: 2_000_000_000))
    let candidateID = UUID(), attemptID = UUID(), qualificationID = UUID()
    let authority: HostRuntimeLease
    let arbiter: SandboxHostCapacityArbiter
    let lease: SandboxCapacityLease
    let configuration: LumeRuntimeConfiguration
    let runtime: LumeLeaseFencedVirtualMachineRuntime
    let specification: SandboxVirtualMachineSpecification
    let source: SandboxGuestBaseSource

    init(ownedCPUCount: UInt16 = 4, cloneBehavior: String = "normal") async throws {
        vm = try FakeLumeFixture(behavior: cloneBehavior, scriptOverride: LumeCloneTestRuntime.script)
        release = try LumeGuestTemplateTestFixture(accountless: true, signManifest: false)
        let signed = try await SandboxProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--force", "--sign", "-", "--identifier", "io.darkbloom.sandbox.release-manifest", release.manifest.path],
            timeoutSeconds: 10, maximumOutputBytes: 16 * 1024)
        guard signed.exitCode == 0 else { throw POSIXError(.EIO) }
        var owner = try Self.object(Data(contentsOf: vm.ownershipMarker))
        owner["sourceKind"] = "apple_restore"; owner["sourceReference"] = vm.restoreImage.path
        owner["cpuCount"] = ownedCPUCount
        owner.removeValue(forKey: "unattendedPreset")
        owner.removeValue(forKey: "sourceInstallationID")
        try Self.write(owner, to: vm.ownershipMarker)
        let ownership = try LumeVirtualMachineOwnership.requireOwned(name: vm.virtualMachineName,
            owner: .baseTemplate, in: vm.storage)
        source = try LumeGuestTemplateSource.load(name: vm.virtualMachineName,
            installationID: ownership.installationID, storage: vm.storage)
        authority = try vm.makeTestHostRuntimeAuthority().acquireSandbox()
        arbiter = try vm.makeCapacityArbiter(clock: clock)
        specification = try .init(name: "qualification-clone", resources: .macOSSmall(),
            imageSource: .localTemplate(name: vm.virtualMachineName), diskBytes: 100 * SandboxResourcePolicy.gibibyte)
        lease = try arbiter.reserve(sandboxID: SandboxID(), generation: XCTUnwrap(SandboxGeneration(rawValue: 1)),
            virtualMachineName: specification.name, resources: specification.resources,
            bootDiskBytes: specification.diskBytes, expiresAt: clock.now().addingTimeInterval(120))
        configuration = try .init(executable: vm.executable, storageDirectory: vm.storage,
            commandTimeoutSeconds: 5, createTimeoutSeconds: 5, trustPolicy: .developmentAdHoc,
            guestCommandPolicy: .isolatedAgent, isolatedGuest: release.configuration, hostRuntimeLease: authority)
        runtime = try .init(configuration: configuration, capacityArbiter: arbiter)
        let disk = vm.virtualMachineDirectory.appendingPathComponent("disk.img")
        guard FileManager.default.createFile(atPath: disk.path, contents: nil,
            attributes: [.posixPermissions: 0o600]) else { throw POSIXError(.EIO) }
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: specification.diskBytes); try handle.close()
        let diskIdentity = try LumeInstalledCandidateStore(name: source.name, storage: vm.storage).diskIdentity()
        let template = try JSONDecoder().decode(SandboxGuestTemplateReceipt.self, from: Data(contentsOf: release.receipt))
        let payload = template.payload
        let reservation: [String: Any] = ["schemaVersion": 1, "phase": "awaitingRootInstallation",
            "candidateID": candidateID.uuidString, "bootstrapAttemptID": attemptID.uuidString,
            "source": try Self.object(JSONEncoder().encode(source)),
            "payload": try Self.object(JSONEncoder().encode(payload)),
            "resources": try Self.object(JSONEncoder().encode(specification.resources)),
            "disk": try Self.object(JSONEncoder().encode(diskIdentity)), "installed": false, "qualified": false]
        try Self.write(reservation, to: path(LumeInstalledCandidateCheckpoint.reservationFileName))
        let installation = SandboxAccountlessInstallationReceipt(source: source, rootJobID: attemptID,
            phase: .installationComplete, payload: payload, guestOperatingSystemVersion: "26.0",
            guestArchitecture: "arm64", virtualizedRootObserved: true, signedInstallerVerified: true,
            installerExitCode: 0, installedPayloadVerified: true, bootstrapAccountAbsent: true, tenantIdentityVerified: true)
        try write(installation, name: LumeInstalledCandidateCheckpoint.installationFileName)
        let installationHash = try digest(LumeInstalledCandidateCheckpoint.installationFileName)
        let cleanup = LumeCandidateInstallationCleanup(schemaVersion: 1, candidateID: candidateID,
            bootstrapAttemptID: attemptID, source: source, installationReceiptSHA256: installationHash,
            disk: diskIdentity, temporaryJobRemoved: true, temporaryPayloadRemoved: true,
            fullyDetached: true, sourceStoppedVerified: true)
        try write(cleanup, name: LumeInstalledCandidateCheckpoint.cleanupFileName)
        let checkpoint = LumeInstalledCandidateCheckpoint(schemaVersion: 1, phase: .installedAwaitingQualification,
            candidateID: candidateID, bootstrapAttemptID: attemptID,
            reservationSHA256: try digest(LumeInstalledCandidateCheckpoint.reservationFileName),
            installationReceiptSHA256: installationHash,
            cleanupReceiptSHA256: try digest(LumeInstalledCandidateCheckpoint.cleanupFileName),
            source: source, payload: payload, resources: specification.resources, disk: diskIdentity)
        try write(checkpoint, name: LumeInstalledCandidateCheckpoint.fileName)
    }

    func issue() async throws -> LumeQualificationCloneCapability {
        try await runtime.qualificationCloneCapability(candidateID: candidateID, qualificationID: qualificationID,
            scope: lease.scope, specification: specification)
    }
    func path(_ name: String) -> URL { vm.virtualMachineDirectory.appendingPathComponent(name) }
    func digest(_ name: String) throws -> String { LumeInstalledCandidateStore.digest(try Data(contentsOf: path(name))) }
    func write<T: Encodable>(_ value: T, name: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: path(name))
        guard chmod(path(name).path, 0o600) == 0 else { throw POSIXError(.EIO) }
    }
    func mutate(_ name: String, refreshHashes: Bool = false, _ change: (inout [String: Any]) -> Void) throws {
        var value = try Self.object(Data(contentsOf: path(name))); change(&value)
        try Self.write(value, to: path(name))
        guard refreshHashes else { return }
        var cleanup = try Self.object(Data(contentsOf: path(LumeInstalledCandidateCheckpoint.cleanupFileName)))
        cleanup["installationReceiptSHA256"] = try digest(LumeInstalledCandidateCheckpoint.installationFileName)
        try Self.write(cleanup, to: path(LumeInstalledCandidateCheckpoint.cleanupFileName))
        var checkpoint = try Self.object(Data(contentsOf: path(LumeInstalledCandidateCheckpoint.fileName)))
        checkpoint["reservationSHA256"] = try digest(LumeInstalledCandidateCheckpoint.reservationFileName)
        checkpoint["installationReceiptSHA256"] = try digest(LumeInstalledCandidateCheckpoint.installationFileName)
        checkpoint["cleanupReceiptSHA256"] = try digest(LumeInstalledCandidateCheckpoint.cleanupFileName)
        try Self.write(checkpoint, to: path(LumeInstalledCandidateCheckpoint.fileName))
    }
    func remove() { try? vm.remove(); release.remove() }
    private static func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private static func write(_ value: [String: Any], to path: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: path)
        guard chmod(path.path, 0o600) == 0 else { throw POSIXError(.EIO) }
    }
}
