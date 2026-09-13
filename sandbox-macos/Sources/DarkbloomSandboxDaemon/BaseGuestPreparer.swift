import Foundation
import SandboxRuntime
import SandboxRuntimeLume
import SandboxCore

protocol BaseGuestVirtualMachine: Sendable {
    func capabilities() async throws -> SandboxRuntimeCapabilities
    func create(_ specification: SandboxVirtualMachineSpecification) async throws
    func start(name: String) async throws
    func stop(name: String) async throws
    func inspect(name: String) async throws -> SandboxVirtualMachineRecord?
    func execute(name: String, request: SandboxGuestCommandRequest) async throws -> SandboxGuestCommandResult
}

extension LumeVirtualMachineRuntime: BaseGuestVirtualMachine {}

struct BaseGuestPreparer: Sendable {
    let runtime: any BaseGuestVirtualMachine

    func prepare(specification: SandboxVirtualMachineSpecification, storage: URL,
                 release: BaseGuestRelease, staging: BaseGuestStaging) async throws -> MacOSBaseImagePreparationReport {
        let capabilities = try await runtime.capabilities()
        try await runtime.create(specification)
        let store = BaseGuestTemplateStore(directory: storage.appendingPathComponent(specification.name, isDirectory: true))
        let preparationLock = try BaseGuestPreparationLock(directory: store.directory)
        defer { withExtendedLifetime(preparationLock) {} }
        _ = try await requireStopped(name: specification.name)
        if let existing = try store.matching(name: specification.name, release: release) {
            let stopped = try await requireStopped(name: specification.name)
            try staging.removeAfterStopped()
            return report(record: stopped, runtimeVersion: capabilities.version,
                os: existing.guestOperatingSystemVersion, architecture: existing.guestArchitecture)
        }
        let installationID = try store.installationID(name: specification.name)
        do {
            try await runtime.start(name: specification.name)
            let result = try await runtime.execute(name: specification.name,
                request: BaseGuestInstallation.request(staging: staging, release: release))
            guard result.exitCode == 0, !result.timedOut,
                  !result.standardOutputTruncated, !result.standardErrorTruncated else {
                throw BaseGuestInstallationFailure(result: result)
            }
            let receipt = try JSONDecoder().decode(BaseGuestInstallationReceipt.self, from: result.standardOutput)
            try receipt.validate(release: release)
            try await runtime.stop(name: specification.name)
            let stopped = try await requireStopped(name: specification.name)
            guard try store.installationID(name: specification.name) == installationID else {
                throw BaseGuestPreparationError.staleTemplate
            }
            try staging.removeAfterStopped()
            try store.publish(SandboxGuestTemplateReceipt(name: specification.name,
                installationID: installationID, release: release, receipt: receipt))
            return report(record: stopped, runtimeVersion: capabilities.version,
                os: receipt.guestOperatingSystemVersion, architecture: receipt.guestArchitecture)
        } catch {
            let primary = error
            do {
                let runtime = runtime, name = specification.name
                try await Task.detached {
                    try await runtime.stop(name: name)
                    guard try await runtime.inspect(name: name)?.state == .stopped else {
                        throw BaseGuestPreparationError.unsafeTemplate
                    }
                }.value
            } catch {
                throw MacOSBaseImagePreparationError.cleanup(primary: String(describing: primary), cleanup: String(describing: error))
            }
            // Retain failed bootstrap staging for diagnosis. No readiness record
            // is published, so an interrupted installation cannot become a template.
            throw primary
        }
    }

    private func requireStopped(name: String) async throws -> SandboxVirtualMachineRecord {
        guard let record = try await runtime.inspect(name: name), record.state == .stopped,
              record.cpuCount != nil, record.memoryBytes != nil, record.diskBytes != nil else {
            throw BaseGuestPreparationError.unsafeTemplate
        }
        return record
    }

    private func report(record: SandboxVirtualMachineRecord, runtimeVersion: String,
                        os: String, architecture: String) -> MacOSBaseImagePreparationReport {
        MacOSBaseImagePreparationReport(name: record.name, runtimeVersion: runtimeVersion,
            guestOperatingSystemVersion: os, guestArchitecture: architecture,
            cpuCount: record.cpuCount!, memoryBytes: record.memoryBytes!, diskBytes: record.diskBytes!)
    }
}
