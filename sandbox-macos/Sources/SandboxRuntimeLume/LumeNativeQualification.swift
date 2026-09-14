import Foundation
import SandboxCore
import SandboxRuntime

/// Issued only after actual fenced guest operations and a stop/start cycle.
/// Construction/decoding by callers is intentionally unavailable.
package final class LumeNativeQualificationResult: Sendable {
    package let initialBootID: UUID
    package let restartedBootID: UUID
    package let markerSHA256: String
    let observation: LumeQualificationCloneObservation

    fileprivate init(observation: LumeQualificationCloneObservation, observations: LumeNativeQualificationObservations) {
        self.observation = observation; initialBootID = observations.initialBootID
        restartedBootID = observations.restartedBootID; markerSHA256 = observations.markerSHA256
    }
}

extension LumeVirtualMachineRuntime {
    package func runNativeQualification(_ observation: LumeQualificationCloneObservation) async throws -> LumeNativeQualificationResult {
        let capability = observation.capability
        guard capability.issuingRuntime === self, !capability.nativeChecksAttempted else { throw nativeQualificationFailure() }
        _ = try await observeQualificationClone(capability)
        try requireManagedQualificationGuest(observation)
        guard !capability.nativeChecksAttempted else { throw nativeQualificationFailure() }
        // A partially executed native check sequence cannot be restarted in the
        // same capability. The durable owner must clean up and use a new attempt.
        capability.nativeChecksAttempted = true
        let name = capability.specification.name, scope = capability.lease.scope
        let io = LumeNativeQualificationIO(execute: { request in
            try await self.execute(name: name, scope: scope, request: request)
        }, file: { request in
            try await self.file(scope: scope, name: name, request: request)
        }, restart: {
            try await self.stop(name: name, scope: scope)
            try await self.start(name: name, scope: scope)
        })
        let checked = try await LumeNativeQualificationDriver(qualificationID: capability.qualificationID,
            cloneInstallationID: observation.cloneInstallationID, io: io).run()
        let final = try await observeQualificationClone(capability)
        try requireManagedQualificationGuest(final)
        guard final.cloneInstallationID == observation.cloneInstallationID,
              final.materialsInstanceID == observation.materialsInstanceID else { throw nativeQualificationFailure() }
        return .init(observation: observation, observations: checked)
    }

    private func requireManagedQualificationGuest(_ observation: LumeQualificationCloneObservation) throws {
        let capability = observation.capability, name = capability.specification.name
        guard capability.issuingRuntime === self, runningProcesses[name]?.isRunning == true,
              guestEndpoints[name] != nil, isolatedGuests[name]?.instanceID == observation.materialsInstanceID else {
            throw nativeQualificationFailure()
        }
    }

    private func nativeQualificationFailure() -> SandboxRuntimeError {
        .unsupported("native qualification requires its issuing runtime, managed guest and unused check sequence")
    }
}
