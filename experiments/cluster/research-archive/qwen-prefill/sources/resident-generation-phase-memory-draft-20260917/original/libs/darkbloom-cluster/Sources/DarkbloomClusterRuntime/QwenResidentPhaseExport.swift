import Foundation

/// CPU-only held export, constructed after the shared native core's successful
/// epilogue. Its publisher runs after local lifecycle exit, before completion
/// restores capacity. A failure leaves the owner failed and unavailable.
final class QwenResidentPhaseExport {
    private let resources: QwenResidentPhaseResources
    private let trace: QwenGenerationPhaseTrace
    private let execution: QwenLayerStageGenerationResult
    private var consumed = false

    init(resources: QwenResidentPhaseResources, trace: QwenGenerationPhaseTrace,
         execution: QwenLayerStageGenerationResult) throws {
        guard trace.identity == resources.identity, trace.clockSource == "dispatch_uptime_nanoseconds",
              trace.maximumEvents == resources.budget.maximumEvents,
              trace.requiredHostReservationBytes == resources.budget.requiredHostReservationBytes,
              execution.bothRequestStatesRetired, !execution.mtpEnabled,
              execution.agreementFingerprint == trace.identity.agreementFingerprint,
              execution.membershipEpoch == trace.identity.membershipEpoch,
              execution.identity.requestFingerprint == trace.identity.requestFingerprint,
              execution.identity.stageFingerprint == trace.identity.stageFingerprint,
              execution.identity.stageIndex == trace.identity.rank,
              execution.selectedTokenIDs.count == 128, execution.finishReason == .length, execution.completedFrames == 143,
              execution.committedTokens == 8319,
              trace.events.first?.observation.phase == .requestBegin,
              trace.events.last?.observation.phase == .requestRetired else {
            throw ProbeError("Phase export differs from the fully completed admitted request")
        }
        self.resources = resources; self.trace = trace; self.execution = execution
    }

    func publish(to publisher: (Data, () throws -> Void) throws -> Void) throws {
        guard !consumed else { throw ProbeError("Phase report publication was repeated") }
        consumed = true
        try resources.requireLive(force: true)
        try autoreleasepool {
            let writer = try QwenGenerationPhaseJSON(budget: resources.budget)
            try QwenGenerationPhaseEncoding.encode(trace: trace, budget: resources.budget,
                execution: execution, totalReserved: resources.totalReservedBytes,
                liveChecks: resources.liveResourceChecks, into: writer)
            try resources.requireLive(force: true)
            try writer.publish { bytes in
                try publisher(bytes, { try self.resources.requireLive(force: true) })
                try resources.requireLive(force: true)
            }
        }
        try resources.requireLive(force: true)
    }
}
