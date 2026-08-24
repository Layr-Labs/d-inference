import Foundation
import SandboxRuntime

extension LumeVirtualMachineRuntime {
    func requireUnlistedVirtualMachineIsUnowned(
        name: String,
        owner: LumeVirtualMachineOwnership.Owner
    ) throws {
        let ownershipPresence = try LumeVirtualMachineOwnership.presence(
            name: name,
            owner: owner,
            in: configuration.storageDirectory
        )
        switch ownershipPresence {
        case .absent:
            return
        case .owned(let ownership):
            try LumeVirtualMachineStartIntent.requireAbsent(
                name: name,
                ownership: ownership,
                owner: owner,
                in: configuration.storageDirectory
            )
            throw SandboxRuntimeError.unsupported(
                "VM \(name) runtime and ownership presence disagree"
            )
        }
    }

    func cleanupFailedStartIgnoringCancellation(
        name: String,
        owner: LumeVirtualMachineOwnership.Owner,
        ownership: LumeVirtualMachineOwnership.ResourceCommitment,
        process: SandboxManagedProcess,
        unresolvedIntent: LumeVirtualMachineStartIntent.Intent?,
        expectedLease: SandboxCapacityLease?
    ) async throws {
        runningProcesses.removeValue(forKey: name)
        let cleanup = Task.detached {
            try await self.cleanupFailedStart(
                name: name,
                owner: owner,
                ownership: ownership,
                process: process,
                unresolvedIntent: unresolvedIntent,
                expectedLease: expectedLease
            )
        }
        try await cleanup.value
    }

    private func cleanupFailedStart(
        name: String,
        owner: LumeVirtualMachineOwnership.Owner,
        ownership: LumeVirtualMachineOwnership.ResourceCommitment,
        process: SandboxManagedProcess,
        unresolvedIntent: LumeVirtualMachineStartIntent.Intent?,
        expectedLease: SandboxCapacityLease?
    ) async throws {
        _ = await process.stop()
        let observed = try await inspect(name: name)
        if let observed {
            try LumeVirtualMachineResourceCommitment.requireMatch(
                observed: observed,
                ownership: ownership,
                lease: expectedLease
            )
        }
        let state = observed?.state
        if state != nil && state != .stopped {
            try await stopWithoutOperationFence(
                name: name,
                owner: owner,
                locallyTerminatedIntent: unresolvedIntent,
                expectedLease: expectedLease
            )
        } else if let unresolvedIntent {
            try LumeVirtualMachineStartIntent.clearAfterFailedStart(
                unresolvedIntent,
                name: name,
                ownership: ownership.identity,
                owner: owner,
                terminalState: state,
                in: configuration.storageDirectory
            )
        }
        try await waitForStoppedOrAbsent(
            name: name,
            timeoutSeconds: configuration.commandTimeoutSeconds
        )
    }

    func stopWithoutOperationFence(
        name: String,
        owner: LumeVirtualMachineOwnership.Owner,
        locallyTerminatedIntent: LumeVirtualMachineStartIntent.Intent? = nil,
        expectedLease: SandboxCapacityLease? = nil
    ) async throws {
        guard let existing = try await inspect(name: name) else {
            try await stopMissingVirtualMachine(
                name: name,
                owner: owner,
                locallyTerminatedIntent: locallyTerminatedIntent
            )
            return
        }
        let ownershipCommitment =
            try LumeVirtualMachineOwnership.requireResourceCommitment(
                name: name,
                owner: owner,
                in: configuration.storageDirectory
            )
        try LumeVirtualMachineResourceCommitment.requireMatch(
            observed: existing,
            ownership: ownershipCommitment,
            lease: expectedLease
        )
        let ownership = ownershipCommitment.identity
        let startIntentPlan = try LumeVirtualMachineStartIntent.prepareForStop(
            name: name,
            ownership: ownership,
            owner: owner,
            observedState: existing.state,
            locallyTerminatedIntent: locallyTerminatedIntent,
            in: configuration.storageDirectory
        )
        if existing.state == .stopped {
            if let process = runningProcesses.removeValue(forKey: name) {
                _ = await process.stop()
            }
            try finishProvenStop(
                name: name,
                owner: owner,
                ownership: ownershipCommitment,
                startIntentPlan: startIntentPlan,
                observed: existing,
                expectedLease: expectedLease
            )
            return
        }

        if let process = runningProcesses.removeValue(forKey: name) {
            _ = await process.stop()
        } else {
            _ = try await run(
                arguments: storageArguments(["stop", name]),
                timeoutSeconds: configuration.commandTimeoutSeconds,
                operation: "stop"
            )
        }
        try await waitForState(
            name: name,
            expected: .stopped,
            timeoutSeconds: configuration.commandTimeoutSeconds
        )
        if let process = runningProcesses.removeValue(forKey: name) {
            _ = await process.stop()
        }
        guard let stopped = try await inspect(name: name),
              stopped.state == .stopped
        else {
            throw SandboxRuntimeError.malformedOutput(
                "Lume stop completed without a stopped VM record"
            )
        }
        try finishProvenStop(
            name: name,
            owner: owner,
            ownership: ownershipCommitment,
            startIntentPlan: startIntentPlan,
            observed: stopped,
            expectedLease: expectedLease
        )
    }

    private func stopMissingVirtualMachine(
        name: String,
        owner: LumeVirtualMachineOwnership.Owner,
        locallyTerminatedIntent: LumeVirtualMachineStartIntent.Intent?
    ) async throws {
        if let process = runningProcesses.removeValue(forKey: name) {
            _ = await process.stop()
        }
        let ownershipPresence = try LumeVirtualMachineOwnership.presence(
            name: name,
            owner: owner,
            in: configuration.storageDirectory
        )
        switch ownershipPresence {
        case .absent:
            if let locallyTerminatedIntent {
                try LumeVirtualMachineStartIntent.clearAfterFailedStart(
                    locallyTerminatedIntent,
                    name: name,
                    ownership: .init(
                        installationID: locallyTerminatedIntent.installationID
                    ),
                    owner: owner,
                    terminalState: nil,
                    in: configuration.storageDirectory
                )
                return
            }
            guard owner == .baseTemplate else {
                throw missingLeasedVirtualMachine(name)
            }
        case .owned(let ownership):
            if let locallyTerminatedIntent {
                try LumeVirtualMachineStartIntent.clearAfterFailedStart(
                    locallyTerminatedIntent,
                    name: name,
                    ownership: ownership,
                    owner: owner,
                    terminalState: nil,
                    in: configuration.storageDirectory
                )
                return
            }
            try LumeVirtualMachineStartIntent.requireAbsent(
                name: name,
                ownership: ownership,
                owner: owner,
                in: configuration.storageDirectory
            )
            if owner == .baseTemplate {
                throw SandboxRuntimeError.unsupported(
                    "VM \(name) runtime and ownership presence disagree"
                )
            }
            throw missingLeasedVirtualMachine(name)
        }
    }

    private func finishProvenStop(
        name: String,
        owner: LumeVirtualMachineOwnership.Owner,
        ownership: LumeVirtualMachineOwnership.ResourceCommitment,
        startIntentPlan: LumeVirtualMachineStartIntent.StopPlan,
        observed: SandboxVirtualMachineRecord,
        expectedLease: SandboxCapacityLease?
    ) throws {
        let finalOwnership =
            try LumeVirtualMachineOwnership.requireResourceCommitment(
                name: name,
                owner: owner,
                in: configuration.storageDirectory
            )
        guard finalOwnership == ownership else {
            throw SandboxRuntimeError.unsupported(
                "VM \(name) installation changed during stop"
            )
        }
        try LumeVirtualMachineResourceCommitment.requireMatch(
            observed: observed,
            ownership: finalOwnership,
            lease: expectedLease
        )
        try LumeVirtualMachineStartIntent.completeStop(
            startIntentPlan,
            name: name,
            ownership: ownership.identity,
            owner: owner,
            observedState: .stopped,
            in: configuration.storageDirectory
        )
    }

    private func missingLeasedVirtualMachine(
        _ name: String
    ) -> SandboxRuntimeError {
        .unsupported(
            "leased VM \(name) is missing; refusing to release capacity"
        )
    }
}
