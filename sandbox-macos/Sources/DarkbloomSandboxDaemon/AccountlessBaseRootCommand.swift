import Darwin
import Foundation
import HostRuntimeCoordination
import SandboxRuntime
import SandboxRuntimeLume

enum AccountlessBaseRootCommand {
    static func run(_ options: AccountlessBaseOptions) async throws -> AccountlessBasePhaseReport {
        let input = try AccountlessBaseRootInput(options)
        switch options.phase {
        case .reserve, .authorizeBoot, .boot, .collect, .abortCollection, .publishInstalled:
            throw DaemonCLIError.invalidArguments("prepare-accountless-base")
        case .payload:
            let output = try options.path("--output")
            _ = try await AccountlessInstallationPayload().prepare(candidate: input.candidate,
                release: BaseGuestRelease(directory: options.path("--guest-release")), destination: output)
            return .init(phase: .payloadPrepared, candidate: input.candidate, payloadPath: output.path)
        case .stage:
            // Reject a mutable or incorrectly installed worker before publishing
            // maintenance intent; recovery should not be needed for bad setup.
            _ = try AccountlessSystemCommandExecutable.current()
            try await SandboxStorageEncryption.requireEncryptedAPFS(at: options.storage)
            let payload = try options.path("--payload"), directory = try options.path("--journal-dir")
            let plan = try AccountlessBaseRootInput.plan(at: payload, candidate: input.candidate)
            let parent = try SandboxAuthorityFileSystem.openPrivateDirectory(at: directory, createIfMissing: true)
            defer { close(parent) }
            let journal = try AccountlessInstallationStagingJournal(directory: directory, candidate: input.candidate, plan: plan)
            let inspector = try LumeRootNativeInspector(configuration: .init(executable: options.path("--lume"),
                storageDirectory: options.storage), ownerUID: input.owner.uid, ownerGID: input.owner.primaryGID)
            let replayed: Bool
            if try journal.detachedCleanup() != nil {
                replayed = true
                do { try await verify(journal, input: input, options: options, inspector: inspector) }
                catch HostRuntimeOwnershipError.maintenancePending {
                    try await finishInterruptedCompletion(journal, input: input, options: options, inspector: inspector)
                    try await verify(journal, input: input, options: options, inspector: inspector)
                }
            } else {
                replayed = try await stage(journal, payload: payload, input: input, options: options, inspector: inspector)
                // The operation scope has ended. Verify under fresh ordinary EX;
                // a later replay reaches only the completed branch above.
                try await verify(journal, input: input, options: options, inspector: inspector)
            }
            return .init(phase: .payloadStaged, candidate: input.candidate, payloadPath: payload.path,
                journalPath: directory.path, replayed: replayed)
        }
    }

    private static func stage(_ journal: AccountlessInstallationStagingJournal, payload: URL,
                              input: AccountlessBaseRootInput, options: AccountlessBaseOptions,
                              inspector: LumeRootNativeInspector) async throws -> Bool {
        let operation: AccountlessStagingMaintenance, replayed: Bool
        do {
            operation = try await .begin(journal: journal, storage: options.storage, ownerUID: input.owner.uid,
                ownerGID: input.owner.primaryGID, reservationData: input.reservation, nativeInspector: inspector)
            replayed = false
        } catch HostRuntimeOwnershipError.maintenancePending {
            operation = try await .recover(journal: journal, storage: options.storage, ownerUID: input.owner.uid,
                ownerGID: input.owner.primaryGID, reservationData: input.reservation, nativeInspector: inspector)
            replayed = true
        }
        try await operation.stagePayload(from: payload)
        return replayed
    }

    private static func finishInterruptedCompletion(_ journal: AccountlessInstallationStagingJournal,
            input: AccountlessBaseRootInput, options: AccountlessBaseOptions, inspector: LumeRootNativeInspector) async throws {
        let operation = try await AccountlessStagingMaintenance.recover(journal: journal, storage: options.storage,
            ownerUID: input.owner.uid, ownerGID: input.owner.primaryGID, reservationData: input.reservation,
            nativeInspector: inspector)
        try operation.finishAfterVerifiedCleanup()
    }

    private static func verify(_ journal: AccountlessInstallationStagingJournal,
            input: AccountlessBaseRootInput, options: AccountlessBaseOptions, inspector: LumeRootNativeInspector) async throws {
        try await AccountlessStagingMaintenance.verifyCompleted(journal: journal, storage: options.storage,
            ownerUID: input.owner.uid, ownerGID: input.owner.primaryGID, reservationData: input.reservation,
            nativeInspector: inspector)
    }
}
