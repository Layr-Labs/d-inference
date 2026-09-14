import Darwin
import Foundation
import SandboxCore
import SandboxRuntime
import SandboxRuntimeLume
import SandboxRuntimeVZ

/// Confines the private journal to one actor. Detached cancellation cleanup
/// returns through this actor and cannot concurrently mutate its descriptors.
actor AccountlessQualificationOwner {
    private let journal: AccountlessQualificationJournal
    private let directory: URL
    private let storage: URL
    private let arbiter: SandboxHostCapacityArbiter
    private let runtime: LumeLeaseFencedVirtualMachineRuntime
    private let baseRuntime: LumeVirtualMachineRuntime
    private var started = false

    init(directory: URL, permit: AccountlessBootPermit, collection: AccountlessCollectionRecord,
        capacityDirectory: URL, guestReleaseDirectory: URL, configuration: LumeRuntimeConfiguration,
        arbiter: SandboxHostCapacityArbiter) throws {
        guard configuration.storageDirectory.path == permit.storage, configuration.executable.path == permit.runtime,
              configuration.isolatedGuest?.releaseDirectory == guestReleaseDirectory else { throw AccountlessInstallationError.invalidBinding }
        self.directory = directory; storage = configuration.storageDirectory
        self.arbiter = arbiter
        runtime = try .init(configuration: configuration, capacityArbiter: arbiter)
        baseRuntime = .init(configuration: configuration)
        try AccountlessQualificationRecovery.requireSeparateJournal(directory, storage: storage, capacity: capacityDirectory, release: guestReleaseDirectory)
        let descriptor = try SandboxAuthorityFileSystem.openPrivateDirectory(at: directory, createIfMissing: true)
        defer { close(descriptor) }
        journal = try .init(directory: directory, permit: permit, collection: collection,
            capacityDirectory: capacityDirectory, guestReleaseDirectory: guestReleaseDirectory,
            guestReleaseSHA256: BaseGuestRelease(directory: guestReleaseDirectory).manifestSHA256,
            leaseDurationSeconds: arbiter.snapshot().effectivePolicy.maximumLeaseDurationSeconds)
    }

    func run() async throws -> AccountlessBasePhaseReport {
        guard !started else { throw AccountlessInstallationError.stagingInProgress }
        started = true
        try await baseRuntime.requireRuntimeIdentity(journal.intent.permit.runtimeSHA256)
        if !journal.isNew { return try await recover() }
        do { return try await fresh() }
        catch {
            let original = error
            do {
                try await Task.detached { try await self.cleanupResources() }.value
                try journal.recordAborted()
            } catch {
                throw SandboxRuntimeError.cleanupFailed(operation: "qualify \(journal.intent.cloneName)",
                    primary: String(describing: original), cleanup: String(describing: error))
            }
            throw original
        }
    }

    private func fresh() async throws -> AccountlessBasePhaseReport {
        let intent = journal.intent, candidate = try intent.permit.candidate()
        _ = try verifiedRelease()
        let report = SandboxHostInspector().inspect(storageDirectory: storage)
        try ServeCommand.requireEligibleHost(report, maximumCPUCount: candidate.resources.cpuCount,
            maximumMemoryBytes: candidate.resources.memoryBytes)
        _ = try await baseRuntime.publishInstalledCandidate(name: candidate.source.name, candidateID: candidate.candidateID,
            installationData: AccountlessJournalJSON.encode(intent.collection.installation),
            cleanupData: AccountlessJournalJSON.encode(intent.collection.cleanup), expectedRuntimeSHA256: intent.permit.runtimeSHA256,
            expectedBootRequest: intent.permit.request())
        let allocated = try arbiter.reserve(sandboxID: intent.sandboxID, generation: intent.generation,
            virtualMachineName: intent.cloneName, resources: candidate.resources, bootDiskBytes: candidate.disk.size, expiresAt: intent.expiresAt)
        try journal.recordLease(allocated)
        let specification = try SandboxVirtualMachineSpecification(name: intent.cloneName, resources: candidate.resources,
            imageSource: .localTemplate(name: candidate.source.name), diskBytes: candidate.disk.size)
        let capability = try await runtime.qualificationCloneCapability(candidateID: candidate.candidateID,
            qualificationID: intent.qualificationID, scope: allocated.scope, specification: specification)
        defer { withExtendedLifetime(capability) {} }
        try await runtime.createQualificationClone(capability)
        try await runtime.start(scope: allocated.scope, name: intent.cloneName)
        let observation = try await runtime.observeQualificationClone(capability)
        try journal.recordClone(observation)
        let native = try await runtime.runNativeQualification(observation)
        try journal.recordChecks(native)
        try await runtime.deleteAndRelease(scope: allocated.scope, name: intent.cloneName)
        try await runtime.withVerifiedQualificationReceipt(native) { receipt in try await self.publish(receipt) }
        try journal.recordPublished()
        return try result(qualified: true, replayed: false)
    }

    private func publish(_ record: SandboxGuestTemplateReceipt) throws {
        let release = try verifiedRelease()
        try journal.recordReady(record)
        let store = BaseGuestTemplateStore(directory: storage.appendingPathComponent(record.name))
        if let existing = try store.matching(name: record.name, release: release) {
            guard existing == record else { throw AccountlessInstallationError.invalidBinding }
        } else { try store.publishAccountless(record, release: release) }
    }

    private func verifiedRelease() throws -> BaseGuestRelease {
        let value = try BaseGuestRelease(directory: URL(fileURLWithPath: journal.intent.guestReleaseDirectory))
        guard value.manifestSHA256 == journal.intent.guestReleaseSHA256 else { throw AccountlessInstallationError.releaseChanged }
        return value
    }

    private func recover() async throws -> AccountlessBasePhaseReport {
        // Cleanup is allowed under low capacity and does not rerun the admission
        // inspector. No native checks or new allocation occur on this path.
        try await Task.detached { try await self.cleanupResources() }.value
        if let ready = try journal.ready(), try readyFilePresent() {
            let intent = journal.intent
            try await baseRuntime.verifyPublishedQualification(request: intent.permit.request(), expectedDisk: intent.collection.cleanup.disk,
                installation: intent.collection.installation, receipt: ready)
            try journal.recordPublished()
            return try result(qualified: true, replayed: true)
        }
        try journal.recordAborted()
        return try result(qualified: false, replayed: true)
    }

    private func cleanupResources() async throws {
        let intent = journal.intent, saved = try journal.lease()
        let current = try AccountlessQualificationRecovery.activeLease(intent: intent, saved: saved, leases: arbiter.snapshot().leases)
        if let current {
            if saved == nil { try journal.recordLease(current) }
            try await runtime.deleteAndRelease(scope: current.scope, name: intent.cloneName)
            guard try arbiter.deletionConfirmed(scope: current.scope, virtualMachineName: intent.cloneName) else {
                throw AccountlessInstallationError.invalidBinding
            }
        } else if let saved {
            if let released = try arbiter.releasedDeletionScope(matching: saved.scope, virtualMachineName: intent.cloneName) {
                try await runtime.deleteAndRelease(scope: released, name: intent.cloneName)
                guard try arbiter.deletionConfirmed(scope: released, virtualMachineName: intent.cloneName) else {
                    throw AccountlessInstallationError.invalidBinding
                }
            } else { throw AccountlessInstallationError.invalidBinding }
        } else {
            guard try await baseRuntime.inspect(name: intent.cloneName) == nil else { throw AccountlessInstallationError.invalidBinding }
        }
        try AccountlessQualificationRecovery.requireAbsent(name: intent.cloneName, storage: storage)
    }

    private func readyFilePresent() throws -> Bool {
        let candidate = try journal.intent.permit.candidate()
        let directory = try SandboxAuthorityFileSystem.openPrivateDirectory(at: storage.appendingPathComponent(candidate.source.name), createIfMissing: false)
        defer { close(directory) }
        var info = stat()
        if fstatat(directory, SandboxGuestTemplateReceipt.fileName, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw AccountlessInstallationError.invalidBinding }
        return false
    }

    private func result(qualified: Bool, replayed: Bool) throws -> AccountlessBasePhaseReport {
        .init(phase: qualified ? .templateQualified : .qualificationAborted, candidate: try journal.intent.permit.candidate(),
            journalPath: directory.path, replayed: replayed, sourceStopped: qualified ? true : nil,
            installed: qualified ? true : nil, qualified: qualified, qualificationID: journal.intent.qualificationID)
    }
}
